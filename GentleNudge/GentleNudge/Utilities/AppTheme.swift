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
        case .calm: return "Sage and white"
        case .dusk: return "Soft indigo and lavender"
        case .paper: return "Warm paper, ink accents"
        case .ocean: return "Deep teal and coral"
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
                background: .init(light: 0xEEF3EB, dark: 0x131714),
                secondaryBackground: .init(light: 0xE2EADD, dark: 0x1E241F),
                tertiaryBackground: .init(light: 0xFAFCF8, dark: 0x283029)
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
                background: .init(light: 0xE6F3F5, dark: 0x0A181C),
                secondaryBackground: .init(light: 0xD5E9EC, dark: 0x142429),
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

/// Sizes for the miniature Today card drawn in each picker swatch.
enum ThemeSwatchMetrics {
    static let height: CGFloat = 104
    static let outerPadding: CGFloat = 7
    static let outerCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 5
    static let maxCardCornerRadius: CGFloat = 12
    static let headerBandHeight: CGFloat = 20
    static let maxShadowRadius: CGFloat = 4
    static let maxShadowY: CGFloat = 2
    static let headerFontSize: CGFloat = 10
    static let titleHeight: CGFloat = 24
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
                        .foregroundStyle(style.titleForeground)
                        .dynamicTypeSize(.large)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(height: ThemeSwatchMetrics.titleHeight, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today")
                            .font(.system(size: ThemeSwatchMetrics.headerFontSize,
                                          weight: style.headerUppercased ? .bold : .semibold))
                            .fontWidth(style.headerWidth)
                            .textCase(style.headerUppercased ? .uppercase : nil)
                            .tracking(style.swatchHeaderTracking)
                            .foregroundStyle(style.headerInkColor)
                            .lineLimit(1)
                        swatchRow(style: style, palette: palette, filled: false)
                        swatchRow(style: style, palette: palette, filled: true)
                    }
                    .modifier(ThemedSectionCardModifier(tint: palette.accent, style: style.card.miniature,
                                                        padding: ThemeSwatchMetrics.cardPadding))
                }
                .fontDesign(style.fontDesign)
                .padding(ThemeSwatchMetrics.outerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ThemeSwatchMetrics.height, alignment: .top)
                .background { ThemedPageBackground(theme: theme) }
                .clipShape(RoundedRectangle(cornerRadius: ThemeSwatchMetrics.outerCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThemeSwatchMetrics.outerCornerRadius, style: .continuous)
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

// MARK: - Theme style (typography + main-screen surfaces)

/// A value that differs between light and dark appearance (opacities).
struct ThemeOpacity: Equatable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    var light: Double
    var dark: Double

    init(light: Double, dark: Double) {
        self.light = light
        self.dark = dark
    }

    init(floatLiteral value: Double) { self.init(light: value, dark: value) }
    init(integerLiteral value: Int) { self.init(light: Double(value), dark: Double(value)) }

    func value(_ scheme: ColorScheme) -> Double { scheme == .dark ? dark : light }
}

/// A drop shadow. In the schemes listed in `tintGlowSchemes` the color is
/// swapped for the surface's own tint (a glow) — unless Reduce Transparency.
struct ThemeShadow: Equatable {
    var color: ThemeHexColor
    var opacity: ThemeOpacity
    var radius: CGFloat
    var y: CGFloat
    var tintGlowSchemes: Set<ColorScheme> = []
}

/// How a Today section card is drawn. `ThemeCardStyle.system` reproduces the
/// pre-theme look exactly.
struct ThemeCardStyle: Equatable {
    /// Opaque base fill. `nil` = transparent (only the tint wash shows).
    var fill: ThemeHexColor?
    /// Opacity of the section's tint washed over the fill.
    var tintWash: ThemeOpacity
    /// Wash fades from `tintWash` at the top to `tintWashGradientFloor` of it.
    var tintWashIsGradient = false
    var tintWashGradientFloor: Double = 0.15
    /// Height of a tint gradient band behind the header (0 = none).
    var headerBandHeight: CGFloat = 0
    var headerBandOpacity: Double = 0.24
    var cornerRadius: CGFloat
    var continuousCorners = true
    /// Border color; `nil` = `Color.primary` (unless `borderUsesTint`).
    var border: ThemeHexColor?
    var borderOpacity: ThemeOpacity = 1
    var borderWidth: CGFloat = 0
    var borderUsesTint = false
    var shadow: ThemeShadow?
    /// Solid tint rule along the top edge (editorial) — 0 = none.
    var topRuleHeight: CGFloat = 0
    /// Solid tint bar along the leading edge — 0 = none.
    var leadingRuleWidth: CGFloat = 0

    static let system = ThemeCardStyle(fill: nil, tintWash: 0.08, cornerRadius: Constants.CornerRadius.lg)

    /// The original macOS section card (12pt padding/radius, circular corners).
    static let macSystem = ThemeCardStyle(fill: nil, tintWash: 0.08, cornerRadius: 12, continuousCorners: false)
    static let macSystemPadding: CGFloat = 12

    /// Same look at picker-swatch scale.
    var miniature: ThemeCardStyle {
        var mini = self
        mini.cornerRadius = min(cornerRadius, ThemeSwatchMetrics.maxCardCornerRadius)
        mini.headerBandHeight = headerBandHeight > 0 ? ThemeSwatchMetrics.headerBandHeight : 0
        mini.shadow = shadow.map {
            var s = $0
            s.radius = min(s.radius, ThemeSwatchMetrics.maxShadowRadius)
            s.y = min(s.y, ThemeSwatchMetrics.maxShadowY)
            return s
        }
        return mini
    }
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
    /// Also card the plain rows inside category sections (System keeps them
    /// bare, as before themes).
    var cardsListRows = false

    static let system = ThemeRowStyle(fill: nil, cornerRadius: Constants.CornerRadius.md,
                                      border: nil, borderOpacity: 0.06, borderWidth: 1)
}

/// Status colors that must keep their meaning but need darker/lighter
/// variants to stay legible on a theme's surfaces.
enum ThemeSemanticRole: CaseIterable {
    case dueToday
    case overdue
    case done
}

/// Per-theme personality for the main screens: typography, text colors and
/// card surfaces. `.system` leaves every value at the pre-theme look.
struct ThemeStyle {
    // Typography — applied to themed content (Today, the Mac list), not the
    // app shell, so navigation titles and Settings stay consistent.
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
    var swatchHeaderTracking: CGFloat = 0
    /// Thin rule under each section header (editorial).
    var headerRule = false
    var headerRuleOpacity: Double = 0.35

    // Colors (`nil` = system semantic color)
    /// Primary text on main-screen rows.
    var ink: ThemeHexColor?
    /// Secondary text (counts, muted titles) on main screens.
    var secondaryInk: ThemeHexColor?
    /// Section-title and category-subgroup label text.
    var headerInk: ThemeHexColor?
    /// Empty completion circle (non-text glyph, ≥ 3:1).
    var circle: ThemeHexColor?
    /// In-progress half-filled circle (`nil` = indigo). Kept in the theme's
    /// accent/cool family so it never reads as a warning.
    var inProgress: ThemeHexColor?
    /// Section counts drawn as a soft pill in this ink (`nil` = plain text).
    var countInk: ThemeHexColor?
    var countPillOpacity: Double = 0.14
    /// Legible variants of the semantic status colors (`nil` = system).
    var dueToday: ThemeHexColor?
    var overdue: ThemeHexColor?
    var done: ThemeHexColor?
    /// Vertical page gradient on Today (`nil` = flat palette background).
    var pageGradient: (top: ThemeHexColor, bottom: ThemeHexColor)?
    /// Hairline above the custom tab bar, as an ink opacity.
    var barHairlineOpacity: Double = 0.12

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

    /// Row-title text: theme ink, or the hierarchical styles System always used.
    func textStyle(muted: Bool) -> AnyShapeStyle {
        if muted {
            return secondaryInk.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
        }
        return ink.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary)
    }

    /// Status color for a semantic role (System: orange / red / green).
    func semantic(_ role: ThemeSemanticRole) -> Color {
        switch role {
        case .dueToday: return dueToday?.color ?? .orange
        case .overdue: return overdue?.color ?? .red
        case .done: return done?.color ?? .green
        }
    }

    func semanticHex(_ role: ThemeSemanticRole) -> ThemeHexColor? {
        switch role {
        case .dueToday: return dueToday
        case .overdue: return overdue
        case .done: return done
        }
    }

    /// Category-subgroup label text: header ink on custom themes (only the
    /// icon keeps the category color); System keeps the category color.
    func subgroupLabelColor(category: Color) -> Color { headerInk?.color ?? category }

    var titleForeground: AnyShapeStyle {
        if let g = titleGradient {
            return AnyShapeStyle(LinearGradient(colors: [g.0.color, g.1.color], startPoint: .leading, endPoint: .trailing))
        }
        if let titleInk { return AnyShapeStyle(titleInk.color) }
        return AnyShapeStyle(.primary)
    }

    /// Completion glyph color: done (semantic), then in-progress, then empty.
    func completionColor(isCompleted: Bool, isInProgress: Bool) -> Color {
        isCompleted ? semantic(.done) : (isInProgress ? inProgressColor : circleColor)
    }
}

/// Shared legible status colors for the light-surfaced custom themes.
private enum ThemeSemanticPalette {
    static let dueToday = ThemeHexColor(light: 0x8F4A00, dark: 0xFFB547)
    static let overdue = ThemeHexColor(light: 0xB42318, dark: 0xFF8A7A)
    static let done = ThemeHexColor(light: 0x1F7A35, dark: 0x4ADE80)
}

extension AppTheme {
    /// Resolved once per theme; views read it on every row.
    private static let styleTable: [AppTheme: ThemeStyle] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeStyle()) })

    var style: ThemeStyle { Self.styleTable[self] ?? .system }

    private func makeStyle() -> ThemeStyle {
        switch self {
        case .system:
            return .system

        case .calm:
            // Quiet garden: a sage page, plain white cards, soft sage rows.
            // Only the title is rounded; body text stays in the system face.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .system(.largeTitle, design: .rounded, weight: .bold),
                titleWidth: nil,
                titleInk: .init(light: 0x3B6649, dark: 0xA3D1AE),
                headerFont: .headline,
                headerWidth: nil,
                ink: .init(light: 0x24302A, dark: 0xE6EDE4),
                secondaryInk: .init(light: 0x56645A, dark: 0xA9B8AB),
                headerInk: .init(light: 0x2F5A3D, dark: 0xB4D9BC),
                circle: .init(light: 0x7D8C7F, dark: 0x8D9A8F),
                inProgress: .init(light: 0x3E7A50, dark: 0x8CC69B),
                dueToday: ThemeSemanticPalette.dueToday,
                overdue: ThemeSemanticPalette.overdue,
                done: ThemeSemanticPalette.done,
                pageGradient: nil,
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFFFF, dark: 0x1D231E),
                    tintWash: 0,
                    cornerRadius: 16,
                    shadow: ThemeShadow(color: .init(light: 0x2F4A36, dark: 0x000000),
                                        opacity: ThemeOpacity(light: 0.07, dark: 0.30), radius: 8, y: 2)
                ),
                row: ThemeRowStyle(fill: .init(light: 0xF2F6EF, dark: 0x262E28), cornerRadius: 11,
                                   border: nil, borderOpacity: 0, borderWidth: 0, cardsListRows: true)
            )

        case .dusk:
            // Twilight, kept quiet: an indigo-to-plum title, small tracked
            // caps headers, faint tint washes; the glow is for dark mode only.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .largeTitle.weight(.bold),
                titleGradient: (.init(light: 0x4B45B8, dark: 0xB0A6FF),
                                .init(light: 0x75469E, dark: 0xD8B0EE)),
                headerFont: .subheadline.weight(.bold),
                headerUppercased: true,
                headerTracking: 1.0,
                swatchHeaderTracking: 0.6,
                ink: .init(light: 0x24213A, dark: 0xECE9FF),
                secondaryInk: .init(light: 0x5A5578, dark: 0xADA7D8),
                headerInk: .init(light: 0x4F4A9E, dark: 0xBDB4FF),
                circle: .init(light: 0x7D77C2, dark: 0x8E87D9),
                inProgress: .init(light: 0x4B45B8, dark: 0xA79BFF),
                dueToday: ThemeSemanticPalette.dueToday,
                overdue: ThemeSemanticPalette.overdue,
                done: ThemeSemanticPalette.done,
                pageGradient: (top: .init(light: 0xF3F1FA, dark: 0x1B1734),
                               bottom: .init(light: 0xEAE6F5, dark: 0x0C0B15)),
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFFFF, dark: 0x1C1930),
                    tintWash: ThemeOpacity(light: 0.04, dark: 0.10),
                    tintWashIsGradient: true,
                    cornerRadius: 18,
                    borderOpacity: ThemeOpacity(light: 0.10, dark: 0.25),
                    borderWidth: 1,
                    borderUsesTint: true,
                    shadow: ThemeShadow(color: .init(light: 0x1E1A3A, dark: 0x000000),
                                        opacity: ThemeOpacity(light: 0.05, dark: 0.18),
                                        radius: 12, y: 2, tintGlowSchemes: [.dark])
                ),
                row: ThemeRowStyle(fill: .init(light: 0xF6F5FC, dark: 0x252239), cornerRadius: 12,
                                   border: nil, borderOpacity: 0, borderWidth: 0, cardsListRows: true)
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
                inProgress: .init(light: 0x2E3F5C, dark: 0x93A8CC),
                dueToday: ThemeSemanticPalette.dueToday,
                overdue: ThemeSemanticPalette.overdue,
                done: ThemeSemanticPalette.done,
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
                                   borderWidth: 1, bottomRuleOnly: true, cardsListRows: true)
            )

        case .ocean:
            // Tide pool: a wide deep-teal title over a strong aqua-to-mist
            // gradient (strong enough to show between cards on a phone),
            // white cards with a tinted header band, aqua-outlined rows, and
            // sandy-coral count pills as the one warm note.
            return ThemeStyle(
                fontDesign: nil,
                titleFont: .largeTitle.weight(.bold),
                titleWidth: .expanded,
                titleGradient: (.init(light: 0x053E50, dark: 0x9FE3E8),
                                .init(light: 0x0B5F66, dark: 0x6CC6E0)),
                headerFont: .headline.weight(.semibold),
                ink: .init(light: 0x0D262C, dark: 0xE1F1F3),
                secondaryInk: .init(light: 0x41606A, dark: 0x9DBCC2),
                headerInk: .init(light: 0x074E5A, dark: 0x8AD8DB),
                circle: .init(light: 0x4F818B, dark: 0x6FA3AB),
                inProgress: .init(light: 0x2C66A8, dark: 0x79AEEC),
                countInk: .init(light: 0x9A4524, dark: 0xF4A98A),
                countPillOpacity: 0.18,
                dueToday: ThemeSemanticPalette.dueToday,
                overdue: ThemeSemanticPalette.overdue,
                done: ThemeSemanticPalette.done,
                pageGradient: (top: .init(light: 0xA9DCE5, dark: 0x0B3540),
                               bottom: .init(light: 0xEAF5F7, dark: 0x07131A)),
                card: ThemeCardStyle(
                    fill: .init(light: 0xFFFFFF, dark: 0x11252B),
                    tintWash: 0,
                    headerBandHeight: 64,
                    headerBandOpacity: 0.30,
                    cornerRadius: 18,
                    border: .init(light: 0x0E7477, dark: 0x5FB8BC),
                    borderOpacity: ThemeOpacity(light: 0.14, dark: 0.22),
                    borderWidth: 1,
                    shadow: ThemeShadow(color: .init(light: 0x0B4F5C, dark: 0x000000),
                                        opacity: ThemeOpacity(light: 0.16, dark: 0.40), radius: 12, y: 5)
                ),
                row: ThemeRowStyle(fill: .init(light: 0xF2F9FA, dark: 0x183238), cornerRadius: 12,
                                   border: .init(light: 0x0E7477, dark: 0x6FC2C6), borderOpacity: 0.22,
                                   borderWidth: 1, cardsListRows: true)
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
                dueToday: .init(light: 0x7A3E00, dark: 0xFFC266),
                overdue: .init(light: 0x9E0B0B, dark: 0xFF9A8F),
                done: .init(light: 0x146C2E, dark: 0x5BE38A),
                pageGradient: nil,
                barHairlineOpacity: 1,
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
                                   border: .init(light: 0x000000, dark: 0xFFFFFF), borderOpacity: 1,
                                   borderWidth: 1, cardsListRows: true)
            )
        }
    }
}

// MARK: - Themed view modifiers

/// Page background: the theme's vertical gradient, or the flat palette
/// background (System, flat themes, and Reduce Transparency).
struct ThemedPageBackground: View {
    var theme: AppTheme = ThemeManager.shared.effectiveTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let g = reduceTransparency ? nil : theme.style.pageGradient
        let base = theme.palette.background
        LinearGradient(colors: [g?.top.color ?? base, g?.bottom.color ?? base],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct ThemedSectionCardModifier: ViewModifier {
    let tint: Color
    let style: ThemeCardStyle
    var padding: CGFloat = Constants.Spacing.md

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius,
                                     style: style.continuousCorners ? .continuous : .circular)
        let wash = style.tintWash.value(scheme)
        let washFloor = (style.tintWashIsGradient && !reduceTransparency) ? style.tintWashGradientFloor : 1
        let band = reduceTransparency ? 0 : style.headerBandHeight
        content
            .padding(.leading, style.leadingRuleWidth)
            .padding(.top, style.topRuleHeight)
            .padding(padding)
            .background {
                ZStack(alignment: .top) {
                    shape.fill(style.fill?.color ?? .clear)
                    shape.fill(LinearGradient(colors: [tint.opacity(wash), tint.opacity(wash * washFloor)],
                                              startPoint: .top, endPoint: .bottom))
                    LinearGradient(colors: [tint.opacity(style.headerBandOpacity), tint.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: band)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .opacity(band > 0 ? 1 : 0)
                    Rectangle().fill(tint)
                        .frame(height: style.topRuleHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(tint)
                        .frame(width: style.leadingRuleWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .clipShape(shape)
                .shadow(color: shadowColor, radius: style.shadow?.radius ?? 0, y: style.shadow?.y ?? 0)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: style.borderWidth)
                    .opacity(style.borderWidth > 0 ? 1 : 0)
            }
    }

    private var shadowColor: Color {
        guard let s = style.shadow else { return .clear }
        let glows = s.tintGlowSchemes.contains(scheme) && !reduceTransparency
        return (glows ? tint : s.color.color).opacity(s.opacity.value(scheme))
    }

    private var borderColor: Color {
        let opacity = style.borderOpacity.value(scheme)
        if style.borderUsesTint { return tint.opacity(opacity) }
        return (style.border?.color ?? .primary).opacity(opacity)
    }
}

private struct ThemedRowCardModifier: ViewModifier {
    let style: ThemeRowStyle
    let pageBackground: Color
    /// false = draw nothing (System's bare category rows).
    var enabled = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let stroke = (style.border?.color ?? .primary).opacity(enabled ? style.borderOpacity : 0)
        content
            .background(enabled ? (style.fill?.color ?? pageBackground) : .clear, in: shape)
            .overlay(alignment: .bottom) {
                Rectangle().fill(stroke)
                    .frame(height: style.bottomRuleOnly ? style.borderWidth : 0)
                    .padding(.horizontal, style.cornerRadius)
            }
            .overlay {
                shape.strokeBorder(stroke, lineWidth: style.borderWidth)
                    .opacity(style.bottomRuleOnly || style.borderWidth == 0 ? 0 : 1)
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

/// Big screen title: font, width (dropped at large accessibility sizes so
/// it can wrap instead of truncating), gradient/ink.
private struct ThemedScreenTitleModifier: ViewModifier {
    let style: ThemeStyle
    let fallback: AnyShapeStyle?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let wide = style.titleWidth != nil && dynamicTypeSize <= .accessibility1
        let usesFallback = style.titleGradient == nil && style.titleInk == nil
        content
            .font(style.titleFont)
            .fontWidth(wide ? style.titleWidth : nil)
            .foregroundStyle(usesFallback ? (fallback ?? style.titleForeground) : style.titleForeground)
            // Wide titles would otherwise wrap "Gentle Nudge".
            .lineLimit(wide ? 1 : nil)
            .minimumScaleFactor(wide ? 0.7 : 1)
    }
}

/// Section count: plain secondary text, or a soft pill in the theme's
/// count ink (Ocean).
private struct ThemedCountModifier: ViewModifier {
    let style: ThemeStyle

    func body(content: Content) -> some View {
        let pill = style.countInk
        content
            .foregroundStyle(pill.map { AnyShapeStyle($0.color) } ?? style.textStyle(muted: true))
            .padding(.horizontal, pill == nil ? 0 : Constants.Spacing.xs)
            .padding(.vertical, pill == nil ? 0 : 2)
            .background((pill?.color ?? .clear).opacity(style.countPillOpacity), in: Capsule())
    }
}

/// Editorial hairline under a section header (Paper); no-op elsewhere.
private struct ThemedHeaderRuleModifier: ViewModifier {
    let style: ThemeStyle

    func body(content: Content) -> some View {
        content
            .padding(.bottom, style.headerRule ? Constants.Spacing.xs + 1 : 0)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(style.headerInkColor.opacity(style.headerRule ? style.headerRuleOpacity : 0))
                    .frame(height: style.headerRule ? 1 : 0)
            }
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

    /// Row chrome for the plain rows in category sections: carded on custom
    /// themes (so ledger rules etc. are consistent), bare on System.
    func themedListRow(enabled: Bool = true,
                       theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        let row = theme.style.row
        return modifier(ThemedRowCardModifier(style: row, pageBackground: theme.palette.background,
                                              enabled: enabled && row.cardsListRows))
    }

    /// Section-header title typography + color for the current theme.
    func themedSectionTitle(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedSectionTitleModifier(style: theme.style))
    }

    /// Section count styling (secondary ink, or Ocean's coral pill).
    func themedCount(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedCountModifier(style: theme.style))
    }

    /// Editorial hairline under a section header (Paper); no-op elsewhere.
    func themedHeaderRule(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        modifier(ThemedHeaderRuleModifier(style: theme.style))
    }

    /// The theme's font design for themed content (Today, the Mac list).
    /// Scoped there rather than app-wide so navigation titles, Settings and
    /// the tab bar stay in one typeface.
    func themedFontDesign(theme: AppTheme = ThemeManager.shared.effectiveTheme) -> some View {
        fontDesign(theme.style.fontDesign)
    }

    /// Put on screens presented or pushed from themed content (detail sheets,
    /// category pages) so the themed typeface doesn't leak into a screen with
    /// a standard navigation title.
    func unthemedPresentation() -> some View {
        fontDesign(nil)
    }

    /// Big screen-title typography (font, width, gradient/ink). `fallback`
    /// replaces `.primary` for themes without their own title ink (System).
    func themedScreenTitle(theme: AppTheme = ThemeManager.shared.effectiveTheme,
                           fallback: AnyShapeStyle? = nil) -> some View {
        modifier(ThemedScreenTitleModifier(style: theme.style, fallback: fallback))
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
