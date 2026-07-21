import Foundation
import Observation
import Speech
import AVFoundation

/// Speech-to-text controller for the chat assistant's mic button. Owns an
/// `SFSpeechRecognizer` (on-device when supported) fed by an `AVAudioEngine` tap.
///
/// Lifecycle: `start()` requests authorization, configures audio, installs the
/// tap, and publishes a live `partialTranscript` (bound to the chat draft) plus
/// `isListening`. `stop()` finishes and yields the final transcript through
/// `onFinalTranscript` (the auto-send path); `cancel()` tears down without
/// sending. A short trailing-silence timer auto-stops so the user rarely has to
/// tap twice.
///
/// All published state is mutated on the main actor; audio/recognition callbacks
/// hop back here. Teardown is idempotent and always removes the tap and stops the
/// engine, so the engine is never left running.
@MainActor
@Observable
final class SpeechService {

    // MARK: Published UI state

    /// True while the engine is capturing and the recognizer is active.
    private(set) var isListening = false

    /// The recognizer's live best guess for the current utterance. Bound to the
    /// chat input field while listening.
    private(set) var partialTranscript = ""

    /// Whether speech recognition is usable at all on this device/locale. When
    /// false the mic button is disabled with an explanatory tooltip.
    private(set) var isAvailable: Bool

    /// Flips true when the user has denied microphone or speech-recognition
    /// permission, so the UI can point them at System Settings. `ChatView`
    /// observes this to raise a one-time alert.
    private(set) var authorizationDenied = false

    // MARK: Callbacks

    /// Fires once with the trimmed final transcript when listening finishes with
    /// non-empty text (manual stop, final recognition result, or auto-stop on
    /// silence). `ChatView` routes this straight into the existing send path.
    @ObservationIgnored var onFinalTranscript: ((String) -> Void)?

    // MARK: Engine internals (not observed)

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Finalized segments of the current utterance. The server "finalizes" a
    /// segment at every speech pause; we fold each one in here and keep listening,
    /// so a mid-sentence pause never drops the earlier words. `partialTranscript`
    /// is always `accumulated` + the live segment.
    @ObservationIgnored private var accumulated = ""
    /// Debounced trailing-silence auto-stop. Reset on every partial result.
    @ObservationIgnored private var silenceTask: Task<Void, Never>?

    /// Seconds of no new recognition output before we auto-finish the utterance.
    /// Generous enough to tolerate natural mid-sentence pauses.
    private let silenceTimeout: TimeInterval = 2.0

    init() {
        // Prefer the user's locale; fall back to the recognizer's default.
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        isAvailable = recognizer?.isAvailable ?? false
    }

    // MARK: Public control

    /// Begins listening: requests authorization, then starts audio capture and
    /// recognition. No-op if already listening. Degrades gracefully — sets
    /// `authorizationDenied` (never crashes) if permission is refused or the
    /// recognizer is unavailable.
    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            isAvailable = false
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let speechOK = await Self.requestSpeechAuthorization()
            let micOK = await Self.requestMicPermission()
            guard speechOK, micOK else {
                self.authorizationDenied = true
                return
            }
            self.authorizationDenied = false
            do {
                try self.beginListening(recognizer: recognizer)
            } catch {
                // Any audio/session failure: tear down cleanly, stay silent.
                self.teardown()
            }
        }
    }

    /// Finishes the current utterance and sends whatever was transcribed.
    func stop() {
        finishListening(send: true)
    }

    /// Aborts listening without sending. Clears the partial so a stale phrase
    /// can't leak into the draft.
    func cancel() {
        teardown()
        partialTranscript = ""
    }

    // MARK: Listening

    private func beginListening(recognizer: SFSpeechRecognizer) throws {
        #if os(iOS)
        // Record + duck others; route to speaker + Bluetooth (CarPlay / car audio).
        // Deactivated in teardown so the synthesizer can take the session for
        // playback afterward. `.default` mode (not `.measurement`, which minimizes
        // input signal processing and can starve recognition).
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        accumulated = ""
        partialTranscript = ""
        isListening = true

        // Install the tap + first recognition segment, then run the engine. The
        // engine stays running across segment restarts (only the request/task and
        // tap are swapped), so we keep capturing straight through pauses.
        startRecognitionSegment(recognizer: recognizer)
        audioEngine.prepare()
        try audioEngine.start()

        resetSilenceTimer()
    }

    /// Starts (or restarts) a single recognition segment against a fresh request,
    /// re-pointing the mic tap at it. Called at the start of listening and again
    /// each time the server finalizes a segment at a pause — the reinstall happens
    /// during that pause, so no spoken words are lost.
    private func startRecognitionSegment(recognizer: SFSpeechRecognizer) {
        task?.cancel()
        task = nil
        request?.endAudio()

        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        audioRequest.shouldReportPartialResults = true
        // Server recognition (the default). Forcing `requiresOnDeviceRecognition`
        // silently produced nothing when the per-locale model wasn't installed.
        request = audioRequest

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // Capture `audioRequest` strongly so the off-main audio thread never
        // touches `self`; appending buffers here is the documented pattern.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audioRequest.append(buffer)
        }

        task = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
            // Recognition callbacks arrive off the main actor; hop back.
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error, recognizer: recognizer)
            }
        }
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        recognizer: SFSpeechRecognizer
    ) {
        guard isListening else { return }
        if let result {
            let segment = result.bestTranscription.formattedString
            partialTranscript = Self.join(accumulated, segment)
            resetSilenceTimer()
            if result.isFinal {
                // The server endpointed a segment (a pause). Keep it and continue
                // listening for the rest of the utterance — OUR trailing-silence
                // timer, not the server's per-segment endpointing, ends the turn.
                accumulated = Self.join(accumulated, segment)
                partialTranscript = accumulated
                startRecognitionSegment(recognizer: recognizer)
            }
        }
        // Recognition errors are routine at a segment boundary; ignore them and let
        // the trailing-silence timer decide when the whole utterance is finished.
    }

    /// Joins two transcript fragments with a single space, ignoring empties.
    private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// (Re)arms the trailing-silence auto-stop. Because the class is
    /// main-actor-isolated, the `Task` body runs on the main actor.
    private func resetSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            let timeout = self?.silenceTimeout ?? 1.6
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishListening(send: true)
        }
    }

    /// Idempotent finish: snapshots the transcript, tears down, then (optionally)
    /// hands the final text to the auto-send callback.
    private func finishListening(send: Bool) {
        guard isListening else { return }
        let finalText = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        if send, !finalText.isEmpty {
            onFinalTranscript?(finalText)
        }
    }

    /// Full, idempotent teardown: cancels the silence timer, stops the engine,
    /// removes the tap, ends the request, cancels the task, and (iOS) deactivates
    /// the audio session. Safe to call multiple times.
    private func teardown() {
        silenceTask?.cancel()
        silenceTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil

        isListening = false

        #if os(iOS)
        // Release the record session so the synthesizer (and other apps) get it back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Authorization

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
