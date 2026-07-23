import SwiftUI

enum Constants {
    // MARK: - Claude API
    private static let apiKeyUserDefaultsKey = "claudeAPIKey"
    private static let apiKeyKeychainAccount = "com.horiag.GentleNudge.claudeAPIKey"
    private static let apiKeyPlaceholder = "YOUR_CLAUDE_API_KEY_HERE"

    static var claudeAPIKey: String {
        get {
            // Read from the Keychain (secure storage).
            if let key = KeychainHelper.get(apiKeyKeychainAccount), !key.isEmpty {
                return key
            }
            // One-time migration: an earlier build stored the key in UserDefaults.
            // Move it into the Keychain and scrub the plaintext copy.
            if let legacyKey = UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey),
               !legacyKey.isEmpty {
                KeychainHelper.set(legacyKey, for: apiKeyKeychainAccount)
                UserDefaults.standard.removeObject(forKey: apiKeyUserDefaultsKey)
                return legacyKey
            }
            return apiKeyPlaceholder
        }
        set {
            KeychainHelper.set(newValue, for: apiKeyKeychainAccount)
        }
    }

    static var isAPIKeyConfigured: Bool {
        claudeAPIKey != "YOUR_CLAUDE_API_KEY_HERE" && !claudeAPIKey.isEmpty
    }

    static let claudeAPIURL = "https://api.anthropic.com/v1/messages"

    // MARK: - OpenAI TTS
    // A separate OpenAI key, used ONLY for the assistant's spoken voice (neural
    // text-to-speech). Stored in the Keychain, mirroring the Claude key above.
    private static let openAIAPIKeyKeychainAccount = "com.horiag.GentleNudge.openAIAPIKey"

    /// The user's OpenAI API key. Reads/writes the Keychain; empty when unset.
    static var openAIAPIKey: String {
        get { KeychainHelper.get(openAIAPIKeyKeychainAccount) ?? "" }
        set { KeychainHelper.set(newValue, for: openAIAPIKeyKeychainAccount) }
    }

    /// True once an OpenAI key has been stored — gates neural TTS. Without it the
    /// assistant falls back to Apple's on-device `AVSpeechSynthesizer`.
    static var isOpenAIKeyConfigured: Bool { !openAIAPIKey.isEmpty }

    static let openAISpeechURL = "https://api.openai.com/v1/audio/speech"

    /// OpenAI's neural TTS model used for spoken replies.
    static let openAITTSModel = "gpt-4o-mini-tts"

    /// Default delivery instructions for the neural voice. `gpt-4o-mini-tts`
    /// follows rich stage directions, so this spells out affect, tone, pacing,
    /// and pausing to get a warm, natural, un-robotic read of the assistant's
    /// short reminder replies. Only the delivery changes — the user-selected
    /// voice is still sent separately.
    static let openAITTSInstructions = """
        Voice affect: warm, friendly, and quietly upbeat — a kind personal \
        assistant who genuinely enjoys helping.

        Tone: conversational and natural, like talking with a good friend. \
        Relaxed and encouraging, never formal, stiff, or robotic.

        Pacing: calm and unhurried, at an easy conversational speed — never \
        rushed, never dragging.

        Pauses: breathe naturally. Take brief pauses at commas and between \
        sentences, and a slightly longer beat between separate thoughts or \
        list items.

        Delivery: smooth and even, with light natural emphasis on the details \
        that matter (task names, dates, and times). Vary the intonation the \
        way a person would; avoid any monotone or sing-song patterns.

        Pronunciation: clear and articulate, with a subtle smile in the voice.
        """

    /// Default neural voice when the user hasn't picked one.
    static let defaultTTSVoice = TTSVoice.coral

    /// Model for the existing AI enhancement (reminder polish) feature.
    /// Was `claude-sonnet-4-20250514`, which was retired on 2026-06-15; replaced
    /// with its official successor, `claude-sonnet-5`.
    static let claudeModel = "claude-sonnet-5"

    // MARK: - Chat Assistant
    // User-configurable model + reasoning effort for the conversational chat
    // assistant (later increments). Stored in UserDefaults; the Settings UI binds
    // to these keys via @AppStorage, and app code reads the resolved values below.

    static let defaultChatModel = ChatModel.opus
    // Default to `medium`: reminder extraction is structured and latency-sensitive,
    // so max effort isn't needed. Still user-overridable in Settings.
    static let defaultReasoningEffort = ReasoningEffort.medium

    /// The user-selected chat model (defaults to Claude Opus 4.8).
    static var chatModel: ChatModel {
        UserDefaults.standard.string(forKey: DefaultsKeys.chatModel)
            .flatMap(ChatModel.init(rawValue:)) ?? defaultChatModel
    }

    /// The user-selected reasoning effort (defaults to `high`).
    static var reasoningEffort: ReasoningEffort {
        UserDefaults.standard.string(forKey: DefaultsKeys.reasoningEffort)
            .flatMap(ReasoningEffort.init(rawValue:)) ?? defaultReasoningEffort
    }

    // MARK: - Apple Reminders
    static let appleRemindersListName = "Gentle Nudge"

    // MARK: - UserDefaults Keys
    enum DefaultsKeys {
        /// Whether habit UI (daily checklist, Habits smart list) is shown.
        /// Defaults to true; habit data is kept either way.
        static let showHabits = "showHabits"

        /// Chat assistant model (raw value of `ChatModel`).
        static let chatModel = "chatModel"

        /// Chat assistant reasoning effort (raw value of `ReasoningEffort`).
        static let reasoningEffort = "reasoningEffort"

        /// Whether the assistant reads its replies aloud (voice output). Default
        /// on; toggled by the speaker/mute control in the chat header.
        static let voiceRepliesEnabled = "voiceRepliesEnabled"

        /// Selected neural TTS voice (raw value of `TTSVoice`). Default `coral`.
        static let ttsVoice = "ttsVoice"

        /// Whether to use OpenAI's neural voice (when a key is configured).
        /// Default on; turning it off forces the built-in Apple system voice.
        static let neuralVoiceEnabled = "neuralVoiceEnabled"
    }

    // MARK: - UI
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum CornerRadius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Animation {
        static let quick = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let standard = SwiftUI.Animation.easeInOut(duration: 0.3)
        static let spring = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.7)
    }
}

// MARK: - Chat Assistant Options

/// Selectable models for the conversational chat assistant. Raw value is the
/// Anthropic model ID sent to the API.
enum ChatModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-4-8"
    case sonnet = "claude-sonnet-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 4.8"
        case .sonnet: return "Claude Sonnet 5"
        }
    }
}

/// Selectable neural voices for `gpt-4o-mini-tts`. Raw value is the OpenAI
/// `voice` parameter sent to the speech endpoint.
enum TTSVoice: String, CaseIterable, Identifiable {
    case alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse

    var id: String { rawValue }

    /// Capitalized name for the picker (e.g. "Coral").
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Reasoning effort for the chat assistant. Raw value maps to the API's
/// `output_config.effort`.
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }
}

enum AppColors {
    #if os(iOS)
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let tertiaryBackground = Color(.tertiarySystemBackground)
    #else
    // Match iOS system colors for consistency
    static let background = Color(light: .white, dark: Color(red: 0.11, green: 0.11, blue: 0.12))
    static let secondaryBackground = Color(light: Color(red: 0.92, green: 0.92, blue: 0.94), dark: Color(red: 0.17, green: 0.17, blue: 0.18))
    static let tertiaryBackground = Color(light: .white, dark: Color(red: 0.23, green: 0.23, blue: 0.24))
    #endif
    static let accent = Color.blue
    static let destructive = Color.red
    static let success = Color.green
    static let warning = Color.orange
}

// Helper for light/dark mode colors on macOS
#if os(macOS)
extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}
#endif
