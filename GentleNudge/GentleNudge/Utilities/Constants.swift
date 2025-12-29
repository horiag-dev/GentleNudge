import SwiftUI

enum Constants {
    // MARK: - Claude API
    private static let apiKeyUserDefaultsKey = "claudeAPIKey"

    static var claudeAPIKey: String {
        get {
            // Check UserDefaults first, then fall back to hardcoded value
            if let storedKey = UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey),
               !storedKey.isEmpty {
                return storedKey
            }
            return "YOUR_CLAUDE_API_KEY_HERE"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: apiKeyUserDefaultsKey)
        }
    }

    static var isAPIKeyConfigured: Bool {
        claudeAPIKey != "YOUR_CLAUDE_API_KEY_HERE" && !claudeAPIKey.isEmpty
    }

    static let claudeAPIURL = "https://api.anthropic.com/v1/messages"
    static let claudeModel = "claude-sonnet-4-20250514"

    // MARK: - Apple Reminders
    static let appleRemindersListName = "Gentle Nudge"

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
