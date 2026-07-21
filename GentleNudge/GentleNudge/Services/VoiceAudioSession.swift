import Foundation
import AVFoundation

/// The single owner of the app's `AVAudioSession` strategy for hands-free voice.
///
/// ## Why this exists
/// A hands-free turn is record (mic tap + speech recognition) → playback (the
/// spoken TTS reply) → record again, over and over. iOS has ONE process-wide
/// `AVAudioSession`. Previously the recorder and the player each imposed their
/// own configuration around their work — STT set `.playAndRecord` + active and
/// deactivated on teardown; TTS set `.playback` + active and deactivated when
/// done — so every listen ↔ speak handoff re-plumbed the audio hardware. In
/// practice that broke the loop: after TTS flipped the session to `.playback`
/// (an output-only category) and then deactivated it, the next listen turn's
/// input path came up stale and captured nothing.
///
/// ## The strategy
/// While a voice session is active, the session is configured ONCE as
/// `.playAndRecord` — a category that supports BOTH the mic tap and TTS
/// playback — activated once, and then left completely alone across every
/// listen ↔ speak transition:
/// - `.defaultToSpeaker`: play replies through the loud speaker, not the earpiece.
/// - `.allowBluetooth` / `.allowBluetoothA2DP`: keep car / headset routes working.
/// - `.duckOthers`: lower other apps' audio for the whole conversation.
/// - `.default` mode (NOT `.measurement`, which minimizes input processing and
///   starved recognition — see git history; and not `.voiceChat`, whose echo
///   cancellation is unnecessary here because the mic is never open while TTS
///   plays, and it can make playback quiet/tinny).
///
/// ## Who calls what
/// - `SpeechService` calls `beginVoiceSession()` (idempotent) before every
///   capture turn, so the first listen configures the session and later ones
///   are no-ops.
/// - `SpeechSynthesizer` checks `isVoiceSessionActive` and leaves the session
///   untouched during voice mode; its own `.playback` configuration is used
///   only for standalone typed-chat replies.
/// - `VoiceModeView` calls `endVoiceSession()` exactly once, on dismiss, which
///   releases the hardware and un-ducks other apps.
///
/// On macOS there is no `AVAudioSession`; the session calls compile away and
/// `AVAudioEngine` talks to the default devices directly.
@MainActor
final class VoiceAudioSession {

    static let shared = VoiceAudioSession()

    /// True from `beginVoiceSession()` until `endVoiceSession()`. While true,
    /// NOTHING may reconfigure or deactivate the shared `AVAudioSession`.
    private(set) var isVoiceSessionActive = false

    private init() {}

    /// Configures and activates the one voice-session configuration. Idempotent —
    /// every listen turn calls this, but only the first does any work. Throws if
    /// the session can't be configured/activated (e.g. during a phone call).
    func beginVoiceSession() throws {
        guard !isVoiceSessionActive else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        #endif
        isVoiceSessionActive = true
    }

    /// Ends the voice session and releases the audio hardware (un-ducking other
    /// apps). Idempotent. Only the voice-mode UI calls this, on dismiss.
    func endVoiceSession() {
        guard isVoiceSessionActive else { return }
        isVoiceSessionActive = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
