import XCTest
@testable import GentleNudge_iOS

final class AppThemeTests: XCTestCase {

    private func date(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Time of day

    func test_isDaytime_boundaries() {
        XCTAssertFalse(AppTheme.isDaytime(date(hour: 5, minute: 59), calendar: utc))
        XCTAssertTrue(AppTheme.isDaytime(date(hour: 6), calendar: utc))
        XCTAssertTrue(AppTheme.isDaytime(date(hour: 17, minute: 59), calendar: utc))
        XCTAssertFalse(AppTheme.isDaytime(date(hour: 18), calendar: utc))
        XCTAssertFalse(AppTheme.isDaytime(date(hour: 0), calendar: utc))
    }

    func test_resolve_followTimeOfDay_picksCalmByDayDuskAtNight() {
        XCTAssertEqual(AppTheme.resolve(selected: .ocean, followsTimeOfDay: true, isDaytime: true), .calm)
        XCTAssertEqual(AppTheme.resolve(selected: .ocean, followsTimeOfDay: true, isDaytime: false), .dusk)
    }

    func test_resolve_withoutFollow_usesSelection() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(AppTheme.resolve(selected: theme, followsTimeOfDay: false, isDaytime: true), theme)
            XCTAssertEqual(AppTheme.resolve(selected: theme, followsTimeOfDay: false, isDaytime: false), theme)
        }
    }

    // MARK: Persistence

    func test_manager_defaultsToSystem_andPersistsSelection() {
        let suite = "AppThemeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ThemeManager(defaults: defaults, now: date(hour: 12))
        XCTAssertEqual(manager.selectedTheme, .system)
        XCTAssertFalse(manager.followsTimeOfDay)
        XCTAssertEqual(manager.effectiveTheme, .system)

        manager.selectedTheme = .paper
        manager.followsTimeOfDay = true

        let reloaded = ThemeManager(defaults: defaults, now: date(hour: 12))
        XCTAssertEqual(reloaded.selectedTheme, .paper)
        XCTAssertTrue(reloaded.followsTimeOfDay)
    }

    func test_manager_unknownStoredValue_fallsBackToSystem() {
        let suite = "AppThemeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("neon", forKey: ThemeManager.selectedThemeKey)

        XCTAssertEqual(ThemeManager(defaults: defaults).selectedTheme, .system)
    }

    // MARK: Contrast

    /// White text sits on the accent (chat bubbles, selected chips, prominent
    /// buttons), and the accent sits on the background as text/icons. Every
    /// custom theme must be at least as legible as the system blue (~3.6:1).
    func test_customThemes_meetContrastFloors() {
        let white: UInt32 = 0xFFFFFF
        for theme in AppTheme.allCases {
            guard let p = theme.hexPalette else { continue }
            for (accent, bg, mode) in [(p.accent.light, p.background.light, "light"),
                                       (p.accent.dark, p.background.dark, "dark")] {
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(white, accent), 3.4, "\(theme) \(mode): white on accent")
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(accent, bg), 4.0, "\(theme) \(mode): accent on background")
            }
        }
    }

    func test_highContrast_meetsAA() {
        let p = AppTheme.highContrast.hexPalette!
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(0xFFFFFF, p.accent.light), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(0xFFFFFF, p.accent.dark), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.accent.light, p.background.light), 4.5)
        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.accent.dark, p.background.dark), 4.5)
        XCTAssertEqual(ThemeContrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    func test_systemTheme_hasNoCustomPalette() {
        XCTAssertNil(AppTheme.system.hexPalette)
    }

    // MARK: Style tokens

    /// System must keep the pre-theme main screen: no custom type, colors,
    /// gradients, or surfaces.
    func test_systemStyle_isUnchangedLook() {
        let s = AppTheme.system.style
        XCTAssertNil(s.fontDesign)
        XCTAssertNil(s.titleWidth)
        XCTAssertNil(s.ink)
        XCTAssertNil(s.secondaryInk)
        XCTAssertNil(s.headerInk)
        XCTAssertNil(s.circle)
        XCTAssertNil(s.inProgress)
        XCTAssertNil(s.pageGradient)
        XCTAssertFalse(s.headerUppercased)
        XCTAssertFalse(s.headerRule)
        XCTAssertEqual(s.card, .system)
        XCTAssertEqual(s.row, .system)
        XCTAssertEqual(s.card.tintWash, 0.08)
        XCTAssertEqual(s.card.cornerRadius, Constants.CornerRadius.lg)
        XCTAssertEqual(s.row.cornerRadius, Constants.CornerRadius.md)
    }

    /// The themes must actually differ from each other on the main screen —
    /// not just in accent color.
    func test_customThemes_haveDistinctPersonalities() {
        let custom = AppTheme.allCases.filter { $0 != .system }
        let signatures = Set(custom.map { theme -> String in
            let s = theme.style
            return "\(String(describing: s.fontDesign))|\(String(describing: s.titleWidth))|\(s.card.cornerRadius)|\(s.card.borderWidth)|\(s.headerUppercased)"
        })
        XCTAssertEqual(signatures.count, custom.count)
        XCTAssertEqual(AppTheme.calm.style.fontDesign, .rounded)
        XCTAssertEqual(AppTheme.paper.style.fontDesign, .serif)
        XCTAssertNil(AppTheme.paper.style.card.shadow, "Paper is flat")
        XCTAssertNil(AppTheme.highContrast.style.card.shadow)
        XCTAssertEqual(AppTheme.highContrast.style.card.tintWash, 0, "High Contrast: no translucency")
    }

    /// Every text token is ≥ 4.5:1 on every surface it can sit on (card, row,
    /// page background, both page-gradient stops), in light and dark; glyph
    /// tokens (completion / in-progress circles) are ≥ 3:1 on cards and rows.
    func test_customThemes_styleTokensMeetAA() {
        for theme in AppTheme.allCases {
            guard let palette = theme.hexPalette else { continue }
            let s = theme.style
            guard let card = s.card.fill, let row = s.row.fill else {
                XCTFail("\(theme): custom themes need opaque card and row fills")
                continue
            }
            var surfaces: [(String, ThemeHexColor)] = [("card", card), ("row", row), ("background", palette.background)]
            if let g = s.pageGradient {
                surfaces += [("gradient top", g.top), ("gradient bottom", g.bottom)]
            }
            var pageTexts: [(String, ThemeHexColor?)] = [("title", s.titleInk)]
            if let g = s.titleGradient { pageTexts += [("title gradient start", g.0), ("title gradient end", g.1)] }
            let texts: [(String, ThemeHexColor?)] = [("ink", s.ink), ("secondaryInk", s.secondaryInk), ("headerInk", s.headerInk)]

            for (mode, pick) in [("light", { (c: ThemeHexColor) in c.light }), ("dark", { (c: ThemeHexColor) in c.dark })] {
                for (name, color) in texts {
                    guard let color else { XCTFail("\(theme): missing \(name)"); continue }
                    for (surfaceName, surface) in surfaces {
                        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pick(color), pick(surface)), 4.5,
                                                    "\(theme) \(mode): \(name) on \(surfaceName)")
                    }
                }
                for (name, color) in pageTexts {
                    guard let color else { continue }
                    for (surfaceName, surface) in surfaces where surfaceName != "card" && surfaceName != "row" {
                        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pick(color), pick(surface)), 4.5,
                                                    "\(theme) \(mode): \(name) on \(surfaceName)")
                    }
                }
                for (name, color) in [("circle", s.circle), ("inProgress", s.inProgress)] {
                    guard let color else { XCTFail("\(theme): missing \(name)"); continue }
                    for (surfaceName, surface) in [("card", card), ("row", row)] {
                        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pick(color), pick(surface)), 3.0,
                                                    "\(theme) \(mode): \(name) on \(surfaceName)")
                    }
                }
            }
        }
    }

    /// Status colors keep their meaning but must stay legible on every custom
    /// theme's card and row fills: due-today / overdue labels are text
    /// (≥ 4.5:1), the done checkmark is a glyph (≥ 3:1). Count pills too.
    func test_customThemes_semanticColorsMeetContrast() {
        for theme in AppTheme.allCases where theme != .system {
            let s = theme.style
            guard let card = s.card.fill, let row = s.row.fill else {
                XCTFail("\(theme): custom themes need opaque card and row fills")
                continue
            }
            for (mode, pick) in [("light", { (c: ThemeHexColor) in c.light }), ("dark", { (c: ThemeHexColor) in c.dark })] {
                for role in ThemeSemanticRole.allCases {
                    guard let color = s.semanticHex(role) else {
                        XCTFail("\(theme): missing semantic \(role)")
                        continue
                    }
                    let floor = role == .done ? 3.0 : 4.5
                    for (surfaceName, surface) in [("card", card), ("row", row)] {
                        XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pick(color), pick(surface)), floor,
                                                    "\(theme) \(mode): \(role) on \(surfaceName)")
                    }
                }
                if let count = s.countInk {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(pick(count), pick(card)), 4.5,
                                                "\(theme) \(mode): count ink on card")
                }
            }
        }
    }

    /// System keeps the stock status colors.
    func test_systemStyle_semanticColorsAreStock() {
        let s = AppTheme.system.style
        XCTAssertEqual(s.semantic(.dueToday), .orange)
        XCTAssertEqual(s.semantic(.overdue), .red)
        XCTAssertEqual(s.semantic(.done), .green)
        XCTAssertEqual(s.subgroupLabelColor(category: .teal), .teal)
    }

    /// In-progress must never read as a warning: keep it out of the
    /// red–orange–yellow hues used by overdue / due-today.
    func test_customThemes_inProgressIsNotWarmWarningHue() {
        for theme in AppTheme.allCases where theme != .system {
            guard let hex = theme.style.inProgress else {
                XCTFail("\(theme): missing inProgress")
                continue
            }
            for value in [hex.light, hex.dark] {
                let hue = Self.hueDegrees(value)
                XCTAssertTrue((70...300).contains(hue), "\(theme): in-progress hue \(hue)° collides with warnings")
            }
        }
    }

    private static func hueDegrees(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return 0 }
        var h: Double
        if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }
}
