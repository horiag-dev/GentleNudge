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
}
