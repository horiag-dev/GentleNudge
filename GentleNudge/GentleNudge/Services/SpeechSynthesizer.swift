import Foundation
import Observation
import AVFoundation

/// Text-to-speech wrapper for reading the assistant's replies aloud. Prefers
/// OpenAI's neural TTS (`gpt-4o-mini-tts`, played via `AVAudioPlayer`) for a
/// natural voice, and falls back to Apple's on-device `AVSpeechSynthesizer`
/// whenever the neural path is unavailable — no OpenAI key, the neural voice is
/// turned off, or any network / API / decode failure — so the user always hears
/// something.
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
    /// The in-flight fetch-then-play task, cancelled by `stop()` / a newer reply.
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

    /// Fetches audio from OpenAI and plays it. On ANY failure — cancellation
    /// aside — falls back to the Apple synthesizer so the reply is still heard.
    private func speakNeural(_ text: String, voice: String) async {
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

    /// Cancels the in-flight neural request, stops the player and the Apple
    /// synthesizer, and releases the playback session. Does NOT touch the mute
    /// setting, so it's safe to use both as `stop()` and as the pre-`speak`
    /// interrupt.
    private func interrupt() {
        speakTask?.cancel()
        speakTask = nil

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
