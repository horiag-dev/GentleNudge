import SwiftUI
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Theme definitions

/// A user-selectable color theme. Per-device preference (UserDefaults), not
/// synced — see `ThemeManager`.
///
/// `.system` is the original look and must stay pixel-identical to the app
/// before themes existed: iOS system background colors, the macOS equivalents
/// that `AppColors` always used, and a `.blue` accent.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case calm
    case dusk
    case paper
    case ocean
    case highContrast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .calm: return "Calm"
        case .dusk: return "Dusk"
        case .paper: return "Paper"
        case .ocean: return "Ocean"
        case .highContrast: return "High Contrast"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "The classic look"
        case .calm: return "Sage and sand"
        case .dusk: return "Soft indigo and lavender"
        case .paper: return "Warm paper, ink accents"
        case .ocean: return "Teal and mist"
        case .highContrast: return "Maximum legibility"
        }
    }

    /// The hex palette for a custom theme, or `nil` for `.system` (which uses
    /// the platform's own dynamic system colors).
    var hexPalette: ThemeHexPalette? {
        switch self {
        case .system:
            return nil
        case .calm:
            return ThemeHexPalette(
                accent: .init(light: 0x4A7C59, dark: 0x5E9670),
                background: .init(light: 0xF7F3EA, dark: 0x151815),
                secondaryBackground: .init(light: 0xEDE6D6, dark: 0x212621),
                tertiaryBackground: .init(light: 0xFCFAF5, dark: 0x2B312B)
            )
        case .dusk:
            return ThemeHexPalette(
                accent: .init(light: 0x5A55C9, dark: 0x7C6FE6),
                background: .init(light: 0xF5F3FB, dark: 0x13121D),
                secondaryBackground: .init(light: 0xE9E5F5, dark: 0x1E1C2C),
                tertiaryBackground: .init(light: 0xFBFAFE, dark: 0x29273B)
            )
        case .paper:
            return ThemeHexPalette(
                accent: .init(light: 0x2E3F5C, dark: 0x6F86AE),
                background: .init(light: 0xFAF7F0, dark: 0x1A1815),
                secondaryBackground: .init(light: 0xF0EADC, dark: 0x25221D),
                tertiaryBackground: .init(light: 0xFFFDF8, dark: 0x302C26)
            )
        case .ocean:
            return ThemeHexPalette(
                accent: .init(light: 0x0E7477, dark: 0x2A8F92),
                background: .init(light: 0xF1F6F7, dark: 0x0D181A),
                secondaryBackground: .init(light: 0xE1EBED, dark: 0x162426),
                tertiaryBackground: .init(light: 0xF8FBFB, dark: 0x1F3134)
            )
        case .highContrast:
            return ThemeHexPalette(
                accent: .init(light: 0x0033CC, dark: 0x2F6FEB),
                background: .init(light: 0xFFFFFF, dark: 0x000000),
                secondaryBackground: .init(light: 0xE5E5EA, dark: 0x1C1C1E),
                tertiaryBackground: .init(light: 0xFFFFFF, dark: 0x2C2C2E)
            )
        }
    }

    /// Resolved SwiftUI colors (dynamic: adapt to light/dark automatically).
    var palette: ThemePalette {
        guard let hex = hexPalette else { return .system }
        return ThemePalette(
            accent: hex.accent.color,
            background: hex.background.color,
            secondaryBackground: hex.secondaryBackground.color,
            tertiaryBackground: hex.tertiaryBackground.color
        )
    }

    // MARK: Time of day

    /// Daytime window used by "Follow time of day": [06:00, 18:00).
    static let dayStartHour = 6
    static let dayEndHour = 18

    static let daytimeTheme: AppTheme = .calm
    static let nighttimeTheme: AppTheme = .dusk

    static func isDaytime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= dayStartHour && hour < dayEndHour
    }

    /// The theme actually shown, given the user's choice and the clock.
    static func resolve(selected: AppTheme, followsTimeOfDay: Bool, isDaytime: Bool) -> AppTheme {
        guard followsTimeOfDay else { return selected }
        return isDaytime ? daytimeTheme : nighttimeTheme
    }
}

/// One color with explicit light- and dark-mode sRGB values (0xRRGGBB).
struct ThemeHexColor: Equatable {
    let light: UInt32
    let dark: UInt32

    var color: Color { Color(light: Color(hex: light), dark: Color(hex: dark)) }
}

struct ThemeHexPalette: Equatable {
    let accent: ThemeHexColor
    let background: ThemeHexColor
    let secondaryBackground: ThemeHexColor
    let tertiaryBackground: ThemeHexColor
}

struct ThemePalette {
    let accent: Color
    let background: Color
    let secondaryBackground: Color
    let tertiaryBackground: Color

    /// The pre-theme look, unchanged.
    static let system: ThemePalette = {
        #if os(iOS)
        return ThemePalette(
            accent: .blue,
            background: Color(.systemBackground),
            secondaryBackground: Color(.secondarySystemBackground),
            tertiaryBackground: Color(.tertiarySystemBackground)
        )
        #else
        // Match iOS system colors for consistency
        return ThemePalette(
            accent: .blue,
            background: Color(light: .white, dark: Color(red: 0.11, green: 0.11, blue: 0.12)),
            secondaryBackground: Color(light: Color(red: 0.92, green: 0.92, blue: 0.94), dark: Color(red: 0.17, green: 0.17, blue: 0.18)),
            tertiaryBackground: Color(light: .white, dark: Color(red: 0.23, green: 0.23, blue: 0.24))
        )
        #endif
    }()
}

// MARK: - Contrast math (WCAG 2.x), used by tests and available for UI checks

enum ThemeContrast {
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Live theme state

/// Holds the current theme selection. `@Observable`, so any view body that
/// reads `AppColors.*` (which reads through `ThemeManager.shared`) is
/// invalidated when the theme changes — no relaunch needed.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    static let selectedThemeKey = "appTheme"
    static let followsTimeOfDayKey = "appThemeFollowsTimeOfDay"

    @ObservationIgnored private let defaults: UserDefaults

    var selectedTheme: AppTheme {
        didSet { defaults.set(selectedTheme.rawValue, forKey: Self.selectedThemeKey) }
    }

    var followsTimeOfDay: Bool {
        didSet {
            defaults.set(followsTimeOfDay, forKey: Self.followsTimeOfDayKey)
            refreshTimeOfDay()
        }
    }

    /// Only flips at the 06:00 / 18:00 boundaries, so a periodic refresh
    /// doesn't invalidate every themed view each minute.
    private(set) var isDaytime: Bool

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        self.selectedTheme = defaults.string(forKey: Self.selectedThemeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
        self.followsTimeOfDay = defaults.bool(forKey: Self.followsTimeOfDayKey)
        self.isDaytime = AppTheme.isDaytime(now)
    }

    var effectiveTheme: AppTheme {
        AppTheme.resolve(selected: selectedTheme, followsTimeOfDay: followsTimeOfDay, isDaytime: isDaytime)
    }

    var palette: ThemePalette { effectiveTheme.palette }

    func refreshTimeOfDay(now: Date = .now) {
        let day = AppTheme.isDaytime(now)
        if day != isDaytime { isDaytime = day }
    }
}

// MARK: - Root modifier

/// Applied once at the app root: sets the app-wide tint and keeps the
/// time-of-day theme current (on foregrounding and once a minute).
private struct AppThemeRootModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    private let theme = ThemeManager.shared
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .tint(theme.palette.accent)
            .onAppear { theme.refreshTimeOfDay() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { theme.refreshTimeOfDay() }
            }
            .onReceive(minuteTimer) { _ in
                if theme.followsTimeOfDay { theme.refreshTimeOfDay() }
            }
    }
}

extension View {
    /// Apply the user's color theme (tint + time-of-day refresh) at the root.
    func appThemed() -> some View {
        modifier(AppThemeRootModifier())
    }
}

// MARK: - Settings picker

/// Swatch grid for choosing a theme, plus the time-of-day toggle.
struct ThemePickerSection: View {
    @Bindable private var theme = ThemeManager.shared

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AppTheme.allCases) { option in
                    ThemeSwatchButton(
                        theme: option,
                        isSelected: !theme.followsTimeOfDay && theme.selectedTheme == option
                    ) {
                        theme.selectedTheme = option
                        theme.followsTimeOfDay = false
                    }
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: $theme.followsTimeOfDay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Follow time of day")
                    Text("Calm from 6 AM, Dusk from 6 PM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text("Themes adapt to light and dark mode. This setting is per device.")
        }
    }
}

private struct ThemeSwatchButton: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = theme.palette
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.background)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palette.secondaryBackground)
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palette.secondaryBackground)
                            .frame(height: 14)
                    }
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 18, height: 18)
                        .padding(6)
                }
                .frame(height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? palette.accent : Color.secondary.opacity(0.3),
                                      lineWidth: isSelected ? 3 : 1)
                )

                Text(theme.displayName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) theme, \(theme.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Color helpers

extension Color {
    /// sRGB color from 0xRRGGBB.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A dynamic color that resolves per light/dark appearance.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
        #endif
    }
}
