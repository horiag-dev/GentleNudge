import Foundation
import Observation
import AVFoundation

/// Text-to-speech wrapper for reading the assistant's replies aloud. Prefers
/// OpenAI's neural TTS (`gpt-4o-mini-tts`), STREAMED as raw PCM into an
/// `AVAudioEngine` player so speech begins on the first audio chunk instead of
/// after the whole clip downloads. The fallback chain keeps the user hearing
/// something no matter what:
///
///   streaming PCM → full-fetch MP3 (`AVAudioPlayer`) → Apple `AVSpeechSynthesizer`
///
/// Any streaming failure BEFORE audio has started (no key, network error,
/// non-200, empty audio, engine failure) silently drops to the next rung; once
/// streamed audio is audibly playing, a mid-stream failure just lets the
/// already-buffered tail finish rather than restarting the reply.
///
/// Exposes a stable public surface — `speak(_:)` / `stop()`, an observable
/// `isSpeaking`, and a persisted `voiceRepliesEnabled` mute (default on) that
/// gates all speech — so `ChatView` and the coordinator's reply hook don't change.
@MainActor
@Observable
final class SpeechSynthesizer {

    /// True while a reply is being spoken (neural playback OR Apple synthesis, and
    /// while a neural request is in flight). Drives the chat's speaking state.
    private(set) var isSpeaking = false

    /// Persisted mute setting. When false, `speak(_:)` is a no-op and any
    /// in-flight speech is stopped. Observable so a toggle reflects it live.
    var voiceRepliesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceRepliesEnabled, forKey: Constants.DefaultsKeys.voiceRepliesEnabled)
            if !voiceRepliesEnabled { stop() }
        }
    }

    // MARK: Apple fallback engine

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var delegateProxy: Delegate?

    // MARK: Neural (OpenAI) engine

    @ObservationIgnored private let ttsClient = OpenAITTSClient()
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PlayerDelegate?
    /// The live incremental player for the streaming PCM path; one fresh
    /// instance per utterance, nil whenever nothing is streaming.
    @ObservationIgnored private var streamingPlayer: StreamingTTSPlayer?
    /// The in-flight stream/fetch-then-play task, cancelled by `stop()` / a newer reply.
    @ObservationIgnored private var speakTask: Task<Void, Never>?

    init() {
        // Default to ON when the key was never set.
        let stored = UserDefaults.standard.object(forKey: Constants.DefaultsKeys.voiceRepliesEnabled) as? Bool
        voiceRepliesEnabled = stored ?? true

        let proxy = Delegate()
        delegateProxy = proxy
        synthesizer.delegate = proxy
        proxy.owner = self
    }

    // MARK: Public API

    /// Speaks `text` if replies aren't muted. Interrupts any in-progress speech so
    /// the latest reply always wins. Reply text only — callers must not pass
    /// tool-status lines or card contents.
    func speak(_ text: String) {
        guard voiceRepliesEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Interrupt whatever is currently talking (neural or Apple) first.
        interrupt()

        if Constants.isOpenAIKeyConfigured && Self.neuralVoiceEnabled {
            let voice = Self.selectedVoice
            // Reflect "speaking" immediately while the audio is fetched, so a
            // subsequent dictation start (which calls `stop()`) still tears us down.
            isSpeaking = true
            speakTask = Task { [weak self] in
                await self?.speakNeural(trimmed, voice: voice)
            }
        } else {
            speakWithApple(trimmed)
        }
    }

    /// Stops speaking immediately (e.g. the user starts dictating, or mutes).
    /// Stops whichever engine is active and cancels any in-flight neural request.
    func stop() {
        interrupt()
    }

    // MARK: Neural path

    /// Speaks via the streaming PCM path first (lowest first-word latency).
    /// If the stream can't produce audio, falls back to the original
    /// fetch-the-whole-MP3 path, and from there to the Apple synthesizer —
    /// cancellation aside, the user always hears the reply.
    private func speakNeural(_ text: String, voice: String) async {
        do {
            try await streamNeuralSpeech(text, voice: voice)
            return
        } catch is CancellationError {
            return
        } catch {
            // Stream never started audibly (no key / offline / non-200 / empty /
            // engine failure) → try the buffered path.
            guard !Task.isCancelled else { return }
        }

        do {
            let data = try await ttsClient.synthesize(
                text: text,
                voice: voice,
                instructions: Constants.openAITTSInstructions
            )
            // Superseded/stopped while the request was in flight — don't play.
            if Task.isCancelled { return }
            try playAudio(data)
        } catch is CancellationError {
            return
        } catch {
            // No key / offline / non-200 / empty / decode → Apple fallback.
            guard !Task.isCancelled else { return }
            speakWithApple(text)
        }
    }

    /// Streams raw PCM from OpenAI into an incremental `AVAudioEngine` player,
    /// so the first words are audible as soon as the first ≈100 ms chunk
    /// arrives. Throws ONLY while nothing has played yet (the caller falls back
    /// and the user misses nothing). Once audio has started, a mid-stream
    /// failure lets the already-buffered tail play out — its final buffer's
    /// completion still flips `isSpeaking`, so the voice loop re-listens at the
    /// right moment either way.
    private func streamNeuralSpeech(_ text: String, voice: String) async throws {
        // No-op during a hands-free voice session — `VoiceAudioSession` owns the
        // one `.playAndRecord` configuration and it must not be touched.
        configurePlaybackSession()

        let player = try StreamingTTSPlayer()
        streamingPlayer = player
        // `weak player`: the closure is stored ON the player, so a strong
        // capture would be a retain cycle. If the closure fires, the player is
        // alive; the identity check drops completions from a superseded player.
        player.onPlaybackFinished = { [weak self, weak player] in
            guard let self, let player, self.streamingPlayer === player else { return }
            self.streamingPlayer = nil
            self.isSpeaking = false
            self.deactivatePlaybackSession()
        }

        do {
            let chunks = try await ttsClient.streamSynthesize(
                text: text,
                voice: voice,
                instructions: Constants.openAITTSInstructions
            )
            for try await chunk in chunks {
                // Superseded or stopped while a chunk was in flight.
                guard streamingPlayer === player else { throw CancellationError() }
                player.enqueue(chunk)
            }
            guard streamingPlayer === player else { throw CancellationError() }
            guard player.hasStartedPlaying else {
                // A 200 whose body produced no schedulable audio.
                streamingPlayer = nil
                player.stop()
                throw OpenAITTSError.emptyAudio
            }
            player.finishFeeding()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard streamingPlayer === player else { throw CancellationError() }
            if player.hasStartedPlaying {
                // Audio already reached the user's ears; let the buffered tail
                // finish (its completion flips `isSpeaking`) instead of
                // restarting the whole reply on a fallback engine.
                player.finishFeeding()
                return
            }
            streamingPlayer = nil
            player.stop()
            throw error
        }
    }

    /// Plays decoded audio through `AVAudioPlayer`, configuring the iOS audio
    /// session for spoken playback first. Throws if the data isn't playable (the
    /// caller then falls back to Apple).
    private func playAudio(_ data: Data) throws {
        configurePlaybackSession()

        let player = try AVAudioPlayer(data: data)
        let delegate = PlayerDelegate()
        delegate.owner = self
        playerDelegate = delegate
        player.delegate = delegate
        player.prepareToPlay()

        audioPlayer = player
        isSpeaking = true
        player.play()
    }

    /// Called by the player delegate when playback ends (or fails mid-stream).
    private func playbackFinished() {
        audioPlayer = nil
        playerDelegate = nil
        isSpeaking = false
        deactivatePlaybackSession()
    }

    // MARK: Apple fallback path

    private func speakWithApple(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        configurePlaybackSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = Self.preferredVoice()

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    // MARK: Shared teardown

    /// Cancels the in-flight neural request, stops the streaming engine, the
    /// buffered player, and the Apple synthesizer, and releases the playback
    /// session. Does NOT touch the mute setting, so it's safe to use both as
    /// `stop()` and as the pre-`speak` interrupt.
    private func interrupt() {
        // Cancelling the task tears down the consuming loop; the stream's
        // termination handler then cancels the underlying URLSession request.
        speakTask?.cancel()
        speakTask = nil

        // Hard-stops the streaming engine without firing its completion (we own
        // the state transitions here).
        streamingPlayer?.stop()
        streamingPlayer = nil

        if let player = audioPlayer {
            player.stop()
        }
        audioPlayer = nil
        playerDelegate = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        isSpeaking = false
        deactivatePlaybackSession()
    }

    // MARK: Audio session (iOS only)

    /// Takes the session for spoken playback — but ONLY outside a hands-free
    /// voice session. During voice mode, `VoiceAudioSession` holds one stable
    /// `.playAndRecord` configuration for the whole record → speak → record
    /// loop; reconfiguring it to `.playback` here (as this used to do) tore up
    /// the input path mid-session and made the next listen turn capture
    /// nothing. Standalone (typed chat) playback ducks other audio rather than
    /// interrupting it. No-op on macOS.
    private func configurePlaybackSession() {
        #if os(iOS)
        guard !VoiceAudioSession.shared.isVoiceSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    /// Un-ducks other apps once we're done talking — again ONLY outside a voice
    /// session: mid-session the shared session must stay active so the next
    /// listen turn's mic capture works. No-op on macOS.
    private func deactivatePlaybackSession() {
        #if os(iOS)
        guard !VoiceAudioSession.shared.isVoiceSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Settings reads

    /// The user's chosen neural voice (persisted via `@AppStorage`), defaulting to
    /// `coral`.
    private static var selectedVoice: String {
        UserDefaults.standard.string(forKey: Constants.DefaultsKeys.ttsVoice)
            ?? Constants.defaultTTSVoice.rawValue
    }

    /// Whether to use the OpenAI neural voice (defaults to on when unset).
    private static var neuralVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: Constants.DefaultsKeys.neuralVoiceEnabled) as? Bool ?? true
    }

    /// A sensible default Apple voice: prefer an installed enhanced/premium voice
    /// for the current language, else the system default for that language.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        if let enhanced = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == language && $0.quality != .default
        }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    // MARK: Delegates

    /// Bridges `AVSpeechSynthesizerDelegate` (an NSObject protocol) to the
    /// observable owner, flipping `isSpeaking` and releasing the iOS session when
    /// Apple speech ends.
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: SpeechSynthesizer?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            Task { @MainActor [weak owner] in owner?.isSpeaking = true }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            finished()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            finished()
        }

        private func finished() {
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                owner.isSpeaking = false
                owner.deactivatePlaybackSession()
            }
        }
    }

    /// Bridges `AVAudioPlayerDelegate` for the neural playback path back to the
    /// observable owner on the main actor.
    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        weak var owner: SpeechSynthesizer?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak owner] in owner?.playbackFinished() }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [weak owner] in owner?.playbackFinished() }
        }
    }
}

// MARK: - Streaming PCM player

/// Incremental playback engine for the streaming neural path: feeds OpenAI's
/// raw PCM chunks (24 kHz, mono, signed 16-bit little-endian) into an
/// `AVAudioPlayerNode` as they arrive, so speech starts on the first chunk.
///
/// Each Int16 chunk is converted to a Float32 `AVAudioPCMBuffer` at the SOURCE
/// rate; the engine's mixer resamples to the hardware output rate downstream,
/// which keeps the conversion trivial (a scale) and glitch-free. If the network
/// briefly falls behind playback, the node simply renders silence and resumes
/// when the next buffer is scheduled — the utterance only "finishes" when
/// feeding is complete AND every scheduled buffer reports `.dataPlayedBack`.
///
/// Deliberately NOT an audio-session owner: it renders through whatever
/// `AVAudioSession` configuration is already active (the voice session's shared
/// `.playAndRecord`, or the synthesizer's standalone `.playback`) and never
/// reconfigures or deactivates anything. One fresh instance per utterance,
/// fully stopped at the end, so no playback engine lingers into the next listen
/// turn — mirroring `SpeechService`'s fresh-record-engine-per-turn strategy.
///
/// File-private on purpose: keeping it in this file avoids a new source file
/// (and the Mac target's pbxproj allow-list), and nobody else should touch it.
@MainActor
private final class StreamingTTSPlayer {

    /// OpenAI's `response_format: "pcm"` wire format: 24 kHz, mono, s16le.
    private static let sourceSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// Float32 companion of the source format, used for the node → mixer
    /// connection and every scheduled buffer.
    private let format: AVAudioFormat

    /// Carries a trailing odd byte between chunks so an Int16 sample is never
    /// split across buffers (chunks are normally even-sized; this is defensive).
    private var pendingByte = Data()
    private var scheduledBuffers = 0
    private var playedBuffers = 0
    private var feedingFinished = false
    private var finished = false
    private var configChangeObserver: (any NSObjectProtocol)?

    /// True once `play()` has been called — i.e. audible output has begun.
    private(set) var hasStartedPlaying = false

    /// Fires exactly once, on the main actor, when the LAST scheduled buffer
    /// has actually been played out (`.dataPlayedBack`) — or when the engine's
    /// configuration changes underneath us (route change) and playback can't
    /// reliably continue. `stop()` clears it first, so a superseded player can
    /// never report a completion.
    var onPlaybackFinished: (() -> Void)?

    /// Builds and starts the playback engine (throws if the engine can't start,
    /// e.g. no output hardware — the caller falls back). Starting the engine
    /// does NOT touch the shared `AVAudioSession`; it renders into whatever
    /// configuration is already active.
    init() throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sourceSampleRate, channels: 1
        ) else {
            throw OpenAITTSError.encoding("Could not create the PCM playback format.")
        }
        self.format = format

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        // A route/hardware change stops the engine underneath us and pending
        // completion callbacks may never fire; end the utterance instead so the
        // voice loop's `isSpeaking` can never wedge at true (the same hazard
        // `SpeechService` guards its record engine against).
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishNow() }
        }
    }

    /// Converts one PCM chunk (s16le mono @ 24 kHz) to a float buffer and
    /// schedules it. Playback starts with the first scheduled buffer.
    func enqueue(_ chunk: Data) {
        guard !finished else { return }

        var data = pendingByte.isEmpty ? chunk : pendingByte + chunk
        pendingByte.removeAll()
        let frames = data.count / 2
        if data.count % 2 != 0 {
            pendingByte = data.suffix(1)
            data = data.prefix(frames * 2)
        }
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?.pointee
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        // s16le → Float32 in [-1, 1]. Byte-wise assembly sidesteps any
        // alignment concerns with Data slices; Int16 LE by construction.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<frames {
                let low = UInt16(raw[2 * i])
                let high = UInt16(raw[2 * i + 1])
                samples[i] = Float(Int16(bitPattern: (high << 8) | low)) / 32_768
            }
        }

        scheduledBuffers += 1
        // `.dataPlayedBack` fires when the buffer has actually been rendered to
        // the output — the accurate signal for "the user has heard this".
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.bufferPlayed() }
        }

        if !hasStartedPlaying {
            hasStartedPlaying = true
            node.play()
        }
    }

    /// All chunks have been handed over; the utterance ends (and
    /// `onPlaybackFinished` fires) once the last one finishes playing.
    func finishFeeding() {
        guard !finished else { return }
        feedingFinished = true
        finishIfFullyPlayed()
    }

    /// Hard stop (user interrupt / superseded reply / mute): silences and tears
    /// down immediately WITHOUT firing `onPlaybackFinished` — the caller owns
    /// the state transition. Idempotent.
    func stop() {
        guard !finished else { return }
        finished = true
        onPlaybackFinished = nil
        removeObserver()
        node.stop()
        engine.stop()
    }

    private func bufferPlayed() {
        guard !finished else { return }
        playedBuffers += 1
        finishIfFullyPlayed()
    }

    private func finishIfFullyPlayed() {
        guard feedingFinished, playedBuffers >= scheduledBuffers else { return }
        finishNow()
    }

    /// Natural end (or unrecoverable route change): tears down and reports
    /// completion exactly once. Late `.dataPlayedBack` hops triggered by
    /// `node.stop()` are ignored via the `finished` flag.
    private func finishNow() {
        guard !finished else { return }
        finished = true
        removeObserver()
        let callback = onPlaybackFinished
        onPlaybackFinished = nil
        node.stop()
        engine.stop()
        callback?()
    }

    private func removeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }
}
