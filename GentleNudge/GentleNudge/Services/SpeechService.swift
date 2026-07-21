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
    /// Debounced trailing-silence auto-stop. Reset on every partial result.
    @ObservationIgnored private var silenceTask: Task<Void, Never>?

    /// Seconds of no new recognition output before we auto-finish the utterance.
    private let silenceTimeout: TimeInterval = 1.6

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
        // Drop any prior task before starting a fresh one.
        task?.cancel()
        task = nil

        #if os(iOS)
        // Record + duck others; route to the speaker. Deactivated in teardown so
        // the synthesizer can take the session for playback afterward.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        audioRequest.shouldReportPartialResults = true
        // Prefer fully on-device recognition when the model is installed (privacy
        // + offline); otherwise fall back to server recognition automatically.
        if recognizer.supportsOnDeviceRecognition {
            audioRequest.requiresOnDeviceRecognition = true
        }
        request = audioRequest

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // Capture `audioRequest` strongly so the off-main audio thread never
        // touches `self`; appending buffers here is the documented pattern.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audioRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        partialTranscript = ""

        task = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
            // Recognition callbacks arrive off the main actor; hop back.
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                    if result.isFinal {
                        self.finishListening(send: true)
                    }
                }
                if error != nil {
                    // Finish with whatever we have (recognition can error out at
                    // the natural end of an utterance).
                    self.finishListening(send: !self.partialTranscript.isEmpty)
                }
            }
        }

        resetSilenceTimer()
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
