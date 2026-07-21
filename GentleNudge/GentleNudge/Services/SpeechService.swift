import Foundation
import Observation
import Speech
import AVFoundation

/// Speech-to-text controller for the hands-free voice mode. Owns an
/// `SFSpeechRecognizer` fed by an `AVAudioEngine` mic tap.
///
/// ## Design — why it looks the way it does
///
/// **One stable tap per turn.** `start()` builds a FRESH `AVAudioEngine`,
/// installs the mic tap once, and leaves that tap untouched until the turn
/// ends. The tap appends into a lock-guarded `RecognitionRequestSink` rather
/// than directly into a specific request, so when the server finalizes its
/// stream mid-utterance we swap in a fresh request with a pointer swap — the
/// tap is never removed/reinstalled while the user is talking. (The previous
/// design re-pointed the tap on every server `isFinal`; that remove/reinstall
/// raced the audio thread and dropped words mid-sentence.)
///
/// **We decide end-of-turn, not the server.** Apple's server "finalizes" its
/// recognition stream whenever it hears a pause (and at its ~1-minute cap).
/// That is NOT the end of the user's turn: on `isFinal` we fold the finalized
/// text into `accumulated` and immediately open a fresh recognition stream
/// against the still-running tap. The turn ends only when OUR trailing-silence
/// timer fires (no new words for `trailingSilence` seconds), the user taps
/// stop, or recognition genuinely fails.
///
/// **The audio session is never touched mid-session.** `VoiceAudioSession`
/// owns one `.playAndRecord` configuration for the entire voice session, and
/// `teardown()` deliberately does NOT deactivate or reconfigure it — doing so
/// between the listen and speak phases is what previously left the input path
/// stale so the second turn captured nothing. `VoiceModeView` releases the
/// session once, on dismiss.
///
/// **A fresh engine per turn.** After TTS plays (possibly changing the audio
/// route), a reused engine's input node can hold a stale hardware format and
/// deliver silence. Rebuilding the engine each turn re-reads the CURRENT input
/// format, so the turn after a spoken reply always captures.
///
/// All published state is mutated on the main actor. Teardown is idempotent,
/// and a `generation` counter makes every recognition callback self-identifying
/// so a stale stream can never corrupt the current turn.
@MainActor
@Observable
final class SpeechService {

    // MARK: Published UI state

    /// True while the engine is capturing and recognition is active.
    private(set) var isListening = false

    /// The live best guess for the current utterance: everything the server has
    /// already finalized this turn plus the in-flight stream's partial text.
    private(set) var partialTranscript = ""

    /// Whether speech recognition is usable right now. Starts optimistic (the
    /// recognizer exists), then tracks `SFSpeechRecognizerDelegate` availability
    /// (server recognition needs network) and flips false if audio capture
    /// persistently fails to start. `VoiceModeView` observes this.
    private(set) var isAvailable: Bool

    /// Flips true when the user has denied microphone or speech-recognition
    /// permission, so the UI can point them at System Settings.
    private(set) var authorizationDenied = false

    // MARK: Callbacks

    /// Fires once with the trimmed final transcript when a turn finishes with
    /// non-empty text (manual stop, trailing-silence auto-stop, or a mid-turn
    /// failure after words were already captured). The voice loop routes this
    /// straight into the send path.
    @ObservationIgnored var onFinalTranscript: ((String) -> Void)?

    // MARK: Internals (not observed)

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var availabilityProxy: AvailabilityProxy?
    /// Rebuilt fresh for every turn — see the class docs.
    @ObservationIgnored private var engine: AVAudioEngine?
    /// Thread-safe indirection between the mic tap and the current request, so
    /// swapping requests never touches the tap.
    @ObservationIgnored private let sink = RecognitionRequestSink()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Text the server has already finalized this turn (it endpoints at pauses;
    /// we keep listening straight through them).
    @ObservationIgnored private var accumulated = ""
    /// Partial text of the current in-flight recognition stream.
    @ObservationIgnored private var liveText = ""
    /// Identifies the current recognition stream. Bumped on every stream swap
    /// AND on teardown, so late callbacks from a dead stream are ignored wholesale.
    @ObservationIgnored private var generation = 0
    /// The trailing-silence auto-stop, re-armed whenever NEW words arrive.
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var configChangeObserver: (any NSObjectProtocol)?

    /// Seconds of no NEW transcription text before the turn auto-finishes.
    /// Generous enough for natural mid-sentence/multi-sentence pauses; the user
    /// can always tap the orb to send immediately.
    private let trailingSilence: TimeInterval = 2.5

    /// How long to wait for the FIRST words before quietly recycling the turn
    /// (nothing is sent; the voice loop re-arms listening). This also keeps the
    /// server stream fresh while the user is silent, so a long wait can never
    /// run into the server's per-stream time cap.
    private let initialSpeechWindow: TimeInterval = 10.0

    init() {
        // Prefer the user's locale; fall back to the recognizer's default.
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        self.recognizer = recognizer
        // Optimistic: server availability often reports false for a beat right
        // after init. `start()` re-checks, and the delegate keeps this honest.
        isAvailable = recognizer != nil
        if let recognizer {
            let proxy = AvailabilityProxy()
            proxy.owner = self
            availabilityProxy = proxy
            recognizer.delegate = proxy
        }
    }

    // MARK: Public control

    /// Begins a listen turn: requests authorization, activates the shared voice
    /// audio session (idempotent), and starts capture + recognition. No-op if
    /// already listening. Degrades gracefully — sets `authorizationDenied` or
    /// clears `isAvailable` (never crashes) so the UI can react.
    func start() {
        guard !isListening else { return }
        guard let recognizer else {
            isAvailable = false
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let speechOK = await Self.requestSpeechAuthorization()
            let micOK = await Self.requestMicPermission()
            guard !self.isListening else { return }
            guard speechOK, micOK else {
                self.authorizationDenied = true
                return
            }
            self.authorizationDenied = false
            guard recognizer.isAvailable else {
                // Server recognition needs network/Siri services. Surface this
                // so the UI never sits in a fake "Listening…" state.
                self.isAvailable = false
                return
            }
            self.isAvailable = true
            do {
                try self.beginListening(recognizer: recognizer)
            } catch {
                self.teardown()
                // Session activation / engine start can fail transiently right
                // after a route change; retry once after a beat before surfacing.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !self.isListening else { return }
                do {
                    try self.beginListening(recognizer: recognizer)
                } catch {
                    self.teardown()
                    self.isAvailable = false
                }
            }
        }
    }

    /// Finishes the current turn immediately and sends whatever was transcribed.
    func stop() {
        finishListening(send: true)
    }

    /// Aborts listening without sending. Clears the partial so a stale phrase
    /// can't leak into the next turn. Does NOT release the shared audio session
    /// (see `VoiceAudioSession`) — the voice-mode UI does that on dismiss.
    func cancel() {
        teardown()
        partialTranscript = ""
    }

    // MARK: Turn setup

    private func beginListening(recognizer: SFSpeechRecognizer) throws {
        // ONE session configuration for the whole voice session (record + TTS
        // playback). Idempotent; only the first turn does any work.
        try VoiceAudioSession.shared.beginVoiceSession()

        accumulated = ""
        liveText = ""
        partialTranscript = ""

        // Fresh engine per turn — see the class docs.
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A dead/misconfigured input reports 0 Hz / 0 channels; tapping it would
        // either throw or capture silence. Fail fast so the caller can retry.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw StartError.noUsableInput
        }

        // The tap runs on a realtime audio thread: it must never touch `self`.
        // It appends through the sink, so mid-turn request swaps are pointer
        // swaps and the tap itself is installed exactly once per turn.
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }

        startRecognitionStream(recognizer: recognizer)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        isListening = true
        observeConfigurationChanges(of: engine)
        armSilenceTimer(after: initialSpeechWindow)
    }

    /// Opens a recognition stream against the already-running tap. Called once
    /// at turn start and again whenever the server finalizes its stream mid-turn.
    private func startRecognitionStream(recognizer: SFSpeechRecognizer) {
        generation += 1
        let gen = generation

        task?.cancel() // no-op when the previous stream already finished
        task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Server recognition. Forcing on-device silently produced nothing when
        // the per-locale model wasn't installed (see git history).
        request.requiresOnDeviceRecognition = false

        // From this instant the (untouched) tap feeds the new stream.
        sink.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Callbacks arrive off the main actor; hop back, tagged with the
            // stream generation so a stale stream can't touch current state.
            Task { @MainActor [weak self] in
                self?.handleRecognition(gen: gen, result: result, error: error, recognizer: recognizer)
            }
        }
    }

    // MARK: Recognition results

    private func handleRecognition(
        gen: Int,
        result: SFSpeechRecognitionResult?,
        error: Error?,
        recognizer: SFSpeechRecognizer
    ) {
        guard isListening, gen == generation else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if text != liveText {
                liveText = text
                partialTranscript = Self.join(accumulated, text)
                // New words arrived → the user is talking; push the deadline out.
                armSilenceTimer(after: trailingSilence)
            }
            if result.isFinal {
                // The SERVER ended its stream (it endpoints at pauses and at its
                // ~1-minute cap). That is not the end of the user's turn: bank
                // the finalized text and immediately open a fresh stream against
                // the still-running tap. Only OUR silence timer ends the turn.
                accumulated = Self.join(accumulated, text)
                liveText = ""
                partialTranscript = accumulated
                startRecognitionStream(recognizer: recognizer)
            }
            return
        }

        if error != nil {
            // A genuine in-stream failure (network drop, service error). Our own
            // teardown/swaps can't reach here — they bump `generation` first.
            // If the user already said something, deliver it rather than dropping
            // their words; otherwise tear down quietly and let the voice loop
            // re-arm listening.
            if partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                teardown()
            } else {
                finishListening(send: true)
            }
        }
    }

    /// Joins two transcript fragments with a single space, ignoring empties.
    private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    // MARK: End-of-turn

    /// (Re)arms the auto-finish timer. Because the class is main-actor-isolated,
    /// the `Task` body runs on the main actor.
    private func armSilenceTimer(after timeout: TimeInterval) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishListening(send: true)
        }
    }

    /// Idempotent finish: snapshots the transcript, tears down, then (optionally)
    /// hands the final text to the auto-send callback. An empty transcript is
    /// never sent — the voice loop just re-arms listening.
    private func finishListening(send: Bool) {
        guard isListening else { return }
        let finalText = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        if send, !finalText.isEmpty {
            onFinalTranscript?(finalText)
        }
    }

    /// Full, idempotent teardown of the TURN: cancels the timer and recognition,
    /// detaches the sink, removes the tap, and discards the engine. Deliberately
    /// does NOT deactivate or reconfigure the audio session — `VoiceAudioSession`
    /// keeps the one `.playAndRecord` configuration alive across listen → speak →
    /// listen; flipping the session between turns is exactly what previously
    /// broke the second turn's capture.
    private func teardown() {
        generation += 1 // orphan any in-flight recognition callbacks

        silenceTask?.cancel()
        silenceTask = nil

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Stop feeding audio first (the sink drops buffers once detached), then
        // dismantle the recognition task and the engine.
        sink.endAudio()
        task?.cancel()
        task = nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        engine = nil

        isListening = false
    }

    // MARK: Route/hardware changes

    /// The engine posts this when the audio hardware or route changes underneath
    /// it mid-turn (e.g. Bluetooth connects); its rendering stops and the tap
    /// format may no longer match the hardware. Finish the turn with whatever
    /// was heard — the voice loop re-arms, and the next turn's fresh engine
    /// picks up the new route's format.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishListening(send: true)
            }
        }
    }

    // MARK: Errors

    private enum StartError: Error {
        /// The input node reported an unusable hardware format (0 Hz / 0 ch).
        case noUsableInput
    }

    // MARK: Availability delegate

    /// Bridges `SFSpeechRecognizerDelegate` (an NSObject protocol) back to the
    /// observable owner so `isAvailable` tracks server availability live.
    private final class AvailabilityProxy: NSObject, SFSpeechRecognizerDelegate {
        weak var owner: SpeechService?

        func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
            Task { @MainActor [weak owner] in
                owner?.isAvailable = available
            }
        }
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

/// Lock-guarded indirection between the realtime mic tap and whichever
/// `SFSpeechAudioBufferRecognitionRequest` is currently live. The tap appends
/// through this so replacing the request (when the server finalizes a stream
/// mid-utterance) is a pointer swap — the tap itself is never removed and
/// reinstalled while audio is flowing, which is what used to drop words.
///
/// Deliberately a top-level (file-private) class: nesting it inside the
/// main-actor `SpeechService` would infer main-actor isolation, and `append`
/// must be callable from the audio thread.
private final class RecognitionRequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Makes `new` the request that subsequent tap buffers feed.
    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = new
        lock.unlock()
    }

    /// Called from the realtime audio thread. Appends outside the lock so the
    /// audio thread never blocks on recognition-internal work.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    /// Detaches and ends the current request; buffers tapped after this are
    /// dropped harmlessly (covers the window before the tap is removed).
    func endAudio() {
        lock.lock()
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
    }
}
