import Foundation
import Observation
import AVFoundation

/// Text-to-speech wrapper over `AVSpeechSynthesizer` for reading the assistant's
/// replies aloud. Exposes `speak(_:)` / `stop()`, an observable `isSpeaking`, and
/// a persisted `voiceRepliesEnabled` mute setting (default on) that gates all
/// speech. The setting is backed by the shared `voiceRepliesEnabled` UserDefaults
/// key so a Settings/ChatView toggle stays in sync with it.
@MainActor
@Observable
final class SpeechSynthesizer {

    /// True while an utterance is being spoken. Driven by the synthesizer's
    /// delegate callbacks.
    private(set) var isSpeaking = false

    /// Persisted mute setting. When false, `speak(_:)` is a no-op and any
    /// in-flight speech is stopped. Observable so a toggle reflects it live.
    var voiceRepliesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceRepliesEnabled, forKey: Constants.DefaultsKeys.voiceRepliesEnabled)
            if !voiceRepliesEnabled { stop() }
        }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var delegateProxy: Delegate?

    init() {
        // Default to ON when the key was never set.
        let stored = UserDefaults.standard.object(forKey: Constants.DefaultsKeys.voiceRepliesEnabled) as? Bool
        voiceRepliesEnabled = stored ?? true

        let proxy = Delegate()
        delegateProxy = proxy
        synthesizer.delegate = proxy
        proxy.owner = self
    }

    /// Speaks `text` if replies aren't muted. Interrupts any in-progress
    /// utterance so the latest reply always wins. Reply text only — callers must
    /// not pass tool-status lines or card contents.
    func speak(_ text: String) {
        guard voiceRepliesEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        // Take the session for playback (the recorder deactivated it). Duck others
        // rather than interrupt them.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = Self.preferredVoice()

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stops speaking immediately (e.g. the user starts dictating, or mutes).
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// A sensible default voice: prefer an installed enhanced/premium voice for
    /// the current language, else the system default for that language.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        if let enhanced = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == language && $0.quality != .default
        }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    /// Bridges `AVSpeechSynthesizerDelegate` (an NSObject protocol) to the
    /// observable owner, flipping `isSpeaking` and releasing the iOS session when
    /// speech ends.
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
                owner?.isSpeaking = false
                #if os(iOS)
                // Un-duck other apps once we're done talking.
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
            }
        }
    }
}
