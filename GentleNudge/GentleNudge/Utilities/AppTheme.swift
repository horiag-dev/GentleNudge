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
            // nil for System/Dusk/Ocean/High Contrast = the default design.
            .fontDesign(theme.effectiveTheme.style.fontDesign)
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

/// A miniature Today screen in the theme's own type, page, card and row
/// styles, so the picker previews the personality — not just a color.
private struct ThemeSwatchButton: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = theme.palette
        let style = theme.style
        Button(action: action) {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aa")
                        .font(style.titleFont)
                        .fontWidth(style.titleWidth)
                        .fontDesign(style.fontDesign)
                        .foregroundStyle(style.titleForeground)
                        .dynamicTypeSize(.large)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(height: 24, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today")
                            .font(.system(size: 10, weight: style.headerUppercased ? .bold : .semibold))
                            .fontWidth(style.headerWidth)
                            .fontDesign(style.fontDesign)
                            .textCase(style.headerUppercased ? .uppercase : nil)
                            .tracking(style.headerTracking > 0 ? 0.8 : 0)
                            .foregroundStyle(style.headerInkColor)
                            .lineLimit(1)
                        swatchRow(style: style, palette: palette, filled: false)
                        swatchRow(style: style, palette: palette, filled: true)
                    }
                    .themedSectionCardMini(tint: palette.accent, theme: theme)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 104, alignment: .top)
                .background { ThemedPageBackground(theme: theme) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? palette.accent : Color.secondary.opacity(0.3),
                                      lineWidth: isSelected ? 3 : 1)
                )

                Text(theme.displayName)
                    .font(.caption)
                    .fontDesign(style.fontDesign)
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

    private func swatchRow(style: ThemeStyle, palette: ThemePalette, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: filled ? "circle.lefthalf.filled" : "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(filled ? style.inProgressColor : style.circleColor)
            Capsule()
                .fill(style.inkColor.opacity(0.55))
                .frame(width: filled ? 30 : 40, height: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .themedRowCard(theme: theme)
    }
}

private extension View {
    /// The section card at swatch scale: same fill/border/rules, tighter padding.
    func themedSectionCardMini(tint: Color, theme: AppTheme) -> some View {
        let card = theme.style.card
        var mini = card
        mini.cornerRadius = min(card.cornerRadius, 12)
        mini.headerBandHeight = card.headerBandHeight > 0 ? 20 : 0
        mini.shadow = card.shadow.map { var s = $0; s.radius = min(s.radius, 4); s.y = min(s.y, 2); return s }
        return self.modifier(ThemedSectionCardModifier(tint: tint, style: mini, padding: 5))
    }
}

// MARK: - Theme style (typography + main-screen surfaces)

/// A drop shadow; `usesTint` swaps the color for the surface's own tint (a glow).
struct ThemeShadow: Equatable {
    var color: ThemeHexColor
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat
    var usesTint = false
}

/// How a Today section card is drawn. Every field has a "System" value that
/// reproduces the pre-theme look exactly (`ThemeCardStyle.system`).
struct ThemeCardStyle: Equatable {
    /// Opaque base fill. `nil` = transparent (only the tint wash shows).
    var fill: ThemeHexColor?
    /// Opacity of the section's tint washed over the fill.
    var tintWash: Double
    /// Wash fades from `tintWash` at the top to nothing at the bottom.
    var tintWashIsGradient = false
    /// Height of a tint gradient band behind the header (0 = none).
    var headerBandHeight: CGFloat = 0
    var cornerRadius: CGFloat
    /// Border color; `nil` with `borderUsesTint == false` = no border.
    var border: ThemeHexColor?
    var borderOpacity: Double = 1
    var borderWidth: CGFloat = 0
    var borderUsesTint = false
    var shadow: ThemeShadow?
    /// Solid tint rule along the top edge (editorial) — 0 = none.
    var topRuleHeight: CGFloat = 0
    /// Solid tint bar along the leading edge — 0 = none.
    var leadingRuleWidth: CGFloat = 0

    static let system = ThemeCardStyle(fill: nil, tintWash: 0.08, cornerRadius: Constants.CornerRadius.lg)
}

/// How a reminder card inside a section is drawn.
struct ThemeRowStyle: Equatable {
    /// `nil` = the theme's page background (the pre-theme behavior).
    var fill: ThemeHexColor?
    var cornerRadius: CGFloat
    /// `nil` = `Color.primary` at `borderOpacity`.
    var border: ThemeHexColor?
    var borderOpacity: Double
    var borderWidth: CGFloat
    /// Draw only a bottom hairline instead of a full outline (ledger rows).
    var bottomRuleOnly = false

    static let system = ThemeRowStyle(fill: nil, cornerRadius: Constants.CornerRadius.md,
                                      border: nil, borderOpacity: 0.06, borderWidth: 1)
}

/// Per-theme personality for the main screens: typography, text colors and
/// card surfaces. `.system` leaves every value at the pre-theme look.
struct ThemeStyle {
    // Typography
    /// Applied at the app root; propagates to every system-font Text.
    var fontDesign: Font.Design?
    var titleFont: Font = .largeTitle.weight(.bold)
    var titleWidth: Font.Width?
    /// Two-stop gradient for the big title (`nil` = plain `titleInk`).
    var titleGradient: (ThemeHexColor, ThemeHexColor)?
    var titleInk: ThemeHexColor?
    var headerFont: Font = .headline
    var headerWidth: Font.Width?
    var headerUppercased = false
    var headerTracking: CGFloat = 0
    /// Thin rule under each section header (editorial).
    var headerRule = false

    // Colors (`nil` = system semantic color)
    /// Primary text on main screens.
    var ink: ThemeHexColor?
    /// Secondary text (counts, metadata) on main screens.
    var secondaryInk: ThemeHexColor?
    /// Section-title text.
    var headerInk: ThemeHexColor?
    /// Empty completion circle (non-text glyph, ≥ 3:1).
    var circle: ThemeHexColor?
    /// In-progress half-filled circle (`nil` = indigo).
    var inProgress: ThemeHexColor?
    /// Vertical page gradient on Today (`nil` = flat palette background).
    var pageGradient: (top: ThemeHexColor, bottom: ThemeHexColor)?

    // Surfaces
    var card: ThemeCardStyle = .system
    var row: ThemeRowStyle = .system

    static let system = ThemeStyle()

    // MARK: Resolved colors

    var inkColor: Color { ink?.color ?? .primary }
    var secondaryInkColor: Color { secondaryInk?.color ?? .secondary }
    var headerInkColor: Color { headerInk?.color ?? .primary }
    var circleColor: Color { circle?.color ?? .secondary }
    var inProgressColor: Color { inProgress?.color ?? .indigo }

    var titleForeground: AnyShapeStyle {
        if let g = titleGradient {
            return AnyShapeStyle(LinearGradient(colors: [g.0.color, g.1.color], startPoint: .leading, endPoint: .trailing))
        }
        if let titleInk { return AnyShapeStyle(titleInk.color) }
        return AnyShapeStyle(.primary)
    }

    /// Completion glyph color for the shared circle used by every row: green
    /// (semantic "done") when completed, then in-progress, then empty.
    func completionColor(isCompleted: Bool, isInProgress: Bool) -> Color {
        isCompleted ? .green : (isInProgress ? inProgressColor : circleColor)
    }
}

extension AppTheme {
    var style: ThemeStyle {
        switch self {
        case .system:
            return .system

        case .calm:
            // Soft and rounded: pillowy cream cards, big radii, gentle shadow.
            return ThemeStyle(
                fontDesign: .rounded,
                titleFont: .largeTitle.weight(.bold),
                titleInk: .init(light: 0x3E6B4C, dark: 0x9CCBA8),
                headerFont: .headline.weight(.semibold),
                ink: .init(light: 0x2F3A31, dark: 0xE6EDE4),
                secondaryInk: .init(light: 0x5A675C, dark: 0xA9B8AB),
                headerInk: .init(light: 0x3E6B4C, dark: 0x9CCBA8),
                circle: .init(light: 0x6F8F76, dark: 0x82A88A),
                inProgress: .init(light: 0xB0661F, dark: 0xE3A15C),
                pageGradient: (top: .init(light: 0xF7F2E6, dark: 0x171A16),
                               bottom: .init(light: 0xE7EEDF, dark: 0x111710)),
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFDF7, dark: 0x222823),
                    tintWash: 0.07,
                    cornerRadius: 26,
                    shadow: ThemeShadow(color: .init(light: 0x3B4A3E, dark: 0x000000),
                                        opacity: 0.12, radius: 14, y: 6)
                ),
                row: ThemeRowStyle(fill: .init(light: 0xF3EEE2, dark: 0x2C332D), cornerRadius: 16,
                                   border: nil, borderOpacity: 0, borderWidth: 0)
            )

        case .dusk:
            // Twilight: heavy gradient title, small-caps headers, deep cards
            // with a tint glow.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .largeTitle.weight(.heavy),
                titleGradient: (.init(light: 0x4B45B8, dark: 0xA79BFF),
                                .init(light: 0x96376F, dark: 0xF0A3D2)),
                headerFont: .subheadline.weight(.bold),
                headerUppercased: true,
                headerTracking: 1.4,
                ink: .init(light: 0x221F3A, dark: 0xECE9FF),
                secondaryInk: .init(light: 0x58537A, dark: 0xADA7D8),
                headerInk: .init(light: 0x4B45B8, dark: 0xBDB4FF),
                circle: .init(light: 0x7D77C2, dark: 0x8E87D9),
                inProgress: .init(light: 0xB0457F, dark: 0xEC8FC4),
                pageGradient: (top: .init(light: 0xEFEBFB, dark: 0x1D1838),
                               bottom: .init(light: 0xE2DBF4, dark: 0x0B0A14)),
                card: ThemeCardStyle(
                    fill: .init(light: 0xFDFCFF, dark: 0x1C1930),
                    tintWash: 0.16,
                    tintWashIsGradient: true,
                    cornerRadius: 20,
                    borderOpacity: 0.35,
                    borderWidth: 1,
                    borderUsesTint: true,
                    shadow: ThemeShadow(color: .init(light: 0x000000, dark: 0x000000),
                                        opacity: 0.28, radius: 16, y: 2, usesTint: true)
                ),
                row: ThemeRowStyle(fill: .init(light: 0xF5F3FD, dark: 0x272340), cornerRadius: 12,
                                   border: .init(light: 0x5A55C9, dark: 0x9C92F0), borderOpacity: 0.18, borderWidth: 1)
            )

        case .paper:
            // Editorial: serif type, flat paper, hairline ink rules, no shadow.
            return ThemeStyle(
                fontDesign: .serif,
                titleFont: .largeTitle.weight(.regular),
                titleInk: .init(light: 0x2B2620, dark: 0xEDE6D8),
                headerFont: .title3.weight(.semibold),
                headerRule: true,
                ink: .init(light: 0x2B2620, dark: 0xEDE6D8),
                secondaryInk: .init(light: 0x6B6153, dark: 0xB3A893),
                headerInk: .init(light: 0x2B2620, dark: 0xEDE6D8),
                circle: .init(light: 0x6B6153, dark: 0xB3A893),
                inProgress: .init(light: 0x9E4526, dark: 0xE38D66),
                pageGradient: nil,
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFDF7, dark: 0x24211C),
                    tintWash: 0,
                    cornerRadius: 3,
                    border: .init(light: 0x2B2620, dark: 0xEDE6D8),
                    borderOpacity: 0.28,
                    borderWidth: 1,
                    shadow: nil,
                    topRuleHeight: 3
                ),
                row: ThemeRowStyle(fill: .init(light: 0xFFFDF7, dark: 0x24211C), cornerRadius: 0,
                                   border: .init(light: 0x2B2620, dark: 0xEDE6D8), borderOpacity: 0.16,
                                   borderWidth: 1, bottomRuleOnly: true)
            )

        case .ocean:
            // Cool and airy: wide (expanded) headers, misty gradient page,
            // tinted gradient band across each card's header.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .largeTitle.weight(.bold),
                titleWidth: .expanded,
                titleInk: .init(light: 0x0B4F5C, dark: 0xA6E0E4),
                headerFont: .headline.weight(.semibold),
                headerWidth: .expanded,
                ink: .init(light: 0x0F2A30, dark: 0xE1F1F3),
                secondaryInk: .init(light: 0x46646C, dark: 0x9DBCC2),
                headerInk: .init(light: 0x0B5560, dark: 0x8AD8DB),
                circle: .init(light: 0x5A8790, dark: 0x6FA3AB),
                inProgress: .init(light: 0x2C66A8, dark: 0x79AEEC),
                pageGradient: (top: .init(light: 0xD8ECF0, dark: 0x0C2629),
                               bottom: .init(light: 0xF3F8F9, dark: 0x091416)),
                card: ThemeCardStyle(
                    fill: .init(light: 0xFAFDFD, dark: 0x13262A),
                    tintWash: 0,
                    headerBandHeight: 64,
                    cornerRadius: 18,
                    shadow: ThemeShadow(color: .init(light: 0x0E7477, dark: 0x000000),
                                        opacity: 0.14, radius: 10, y: 4)
                ),
                row: ThemeRowStyle(fill: .init(light: 0xEDF5F6, dark: 0x1B3236), cornerRadius: 10,
                                   border: nil, borderOpacity: 0, borderWidth: 0)
            )

        case .highContrast:
            // Maximum legibility: black type, solid surfaces, strong borders,
            // no translucency; the section tint survives only as a solid bar.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .largeTitle.weight(.black),
                titleInk: .init(light: 0x000000, dark: 0xFFFFFF),
                headerFont: .headline.weight(.heavy),
                ink: .init(light: 0x000000, dark: 0xFFFFFF),
                secondaryInk: .init(light: 0x3A3A3C, dark: 0xD1D1D6),
                headerInk: .init(light: 0x000000, dark: 0xFFFFFF),
                circle: .init(light: 0x000000, dark: 0xFFFFFF),
                inProgress: .init(light: 0x0033CC, dark: 0x6F9BFF),
                pageGradient: nil,
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFFFF, dark: 0x000000),
                    tintWash: 0,
                    cornerRadius: 10,
                    border: .init(light: 0x000000, dark: 0xFFFFFF),
                    borderWidth: 2,
                    shadow: nil,
                    leadingRuleWidth: 6
                ),
                row: ThemeRowStyle(fill: .init(light: 0xFFFFFF, dark: 0x1C1C1E), cornerRadius: 8,
                                   border: .init(light: 0x000000, dark: 0xFFFFFF), borderOpacity: 1, borderWidth: 1)
            )
        }
    }
}

// MARK: - Themed view modifiers

/// Today page background: the theme's vertical gradient, or the flat palette
/// background (System and flat themes).
struct ThemedPageBackground: View {
    var theme: AppTheme = ThemeManager.shared.effectiveTheme

    var body: some View {
        if let g = theme.style.pageGradient {
            LinearGradient(colors: [g.top.color, g.bottom.color], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        } else {
            theme.palette.background
                .ignoresSafeArea()
        }
    }
}

private struct ThemedSectionCardModifier: ViewModifier {
    let tint: Color
    let style: ThemeCardStyle
    var padding: CGFloat = Constants.Spacing.md

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        content
            .padding(.leading, style.leadingRuleWidth)
            .padding(.top, style.topRuleHeight)
            .padding(padding)
            .background {
                ZStack(alignment: .top) {
                    if let fill = style.fill {
                        shape.fill(fill.color)
                    }
                    if style.tintWash > 0 {
                        if style.tintWashIsGradient {
                            shape.fill(LinearGradient(
                                colors: [tint.opacity(style.tintWash), tint.opacity(style.tintWash * 0.15)],
                                startPoint: .top, endPoint: .bottom))
                        } else {
                            shape.fill(tint.opacity(style.tintWash))
                        }
                    }
                    if style.headerBandHeight > 0 {
                        LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: style.headerBandHeight)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    if style.topRuleHeight > 0 {
                        Rectangle().fill(tint)
                            .frame(height: style.topRuleHeight)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    if style.leadingRuleWidth > 0 {
                        Rectangle().fill(tint)
                            .frame(width: style.leadingRuleWidth)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .clipShape(shape)
                .shadow(color: shadowColor, radius: style.shadow?.radius ?? 0, y: style.shadow?.y ?? 0)
            }
            .overlay {
                if style.borderWidth > 0 {
                    shape.strokeBorder(borderColor, lineWidth: style.borderWidth)
                }
            }
    }

    private var shadowColor: Color {
        guard let s = style.shadow else { return .clear }
        return (s.usesTint ? tint : s.color.color).opacity(s.opacity)
    }

    private var borderColor: Color {
        if style.borderUsesTint { return tint.opacity(style.borderOpacity) }
        return (style.border?.color ?? .primary).opacity(style.borderOpacity)
    }
}

private struct ThemedRowCardModifier: ViewModifier {
    let style: ThemeRowStyle
    let pageBackground: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let stroke = (style.border?.color ?? .primary).opacity(style.borderOpacity)
        content
            .background(style.fill?.color ?? pageBackground, in: shape)
            .overlay(alignment: .bottom) {
                if style.bottomRuleOnly {
                    Rectangle().fill(stroke).frame(height: style.borderWidth)
                }
            }
            .overlay {
                if !style.bottomRuleOnly, style.borderWidth > 0 {
                    shape.strokeBorder(stroke, lineWidth: style.borderWidth)
                }
            }
    }
}

/// Section title text styled per theme (font, width, case, tracking, color).
private struct ThemedSectionTitleModifier: ViewModifier {
    let style: ThemeStyle

    func body(content: Content) -> some View {
        content
            .font(style.headerFont)
            .fontWidth(style.headerWidth)
            .textCase(style.headerUppercased ? .uppercase : nil)
            .tracking(style.headerTracking)
            .foregroundStyle(style.headerInkColor)
    }
}

extension View {
    /// Section container chrome (fill, wash, border, shadow, rules) for the
    /// current theme. System: padding + soft tint wash, as before themes.
    func themedSectionCard(tint: Color, theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedSectionCardModifier(tint: tint, style: theme.style.card))
    }

    /// Reminder-card chrome inside a section for the current theme.
    func themedRowCard(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedRowCardModifier(style: theme.style.row, pageBackground: theme.palette.background))
    }

    /// Section-header title typography + color for the current theme.
    func themedSectionTitle(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedSectionTitleModifier(style: theme.style))
    }

    /// Main-screen primary text color (no-op for System, which keeps the
    /// semantic `.primary` so `.secondary`/`.tertiary` resolve as before).
    @ViewBuilder
    func themedInk(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        if let ink = theme.style.ink {
            self.foregroundStyle(ink.color)
        } else {
            self
        }
    }

    /// Editorial hairline under a section header (Paper); no-op elsewhere.
    @ViewBuilder
    func themedHeaderRule(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        let style = theme.style
        if style.headerRule {
            VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                self
                Rectangle()
                    .fill(style.headerInkColor.opacity(0.35))
                    .frame(height: 1)
            }
        } else {
            self
        }
    }

    /// Big screen-title typography (font, width, gradient/ink).
    @ViewBuilder
    func themedScreenTitle(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        let style = theme.style
        let titled = self
            .font(style.titleFont)
            .fontWidth(style.titleWidth)
            .foregroundStyle(style.titleForeground)
        if style.titleWidth != nil {
            // Wide (expanded) titles would otherwise wrap "Gentle Nudge".
            titled.lineLimit(1).minimumScaleFactor(0.7)
        } else {
            titled
        }
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
