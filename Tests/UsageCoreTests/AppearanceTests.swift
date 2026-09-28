import AppKit
import XCTest
@testable import UsageCore

final class AppearanceTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    /// A local time in New York on a day in September 2026 (14 is a Monday).
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Monday 2026-09-14 4:00 PM in New York.
    var now: Date { at(14, 16) }

    /// Formatted times use a narrow no-break space before AM/PM; tests compare with a plain space.
    func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: Saved settings

    func testDefaultsKeepTheOriginalLook() {
        let standard = Appearance.standard
        XCTAssertEqual(standard.theme, .classic)
        XCTAssertEqual(standard.colorMeaning, .fullness)
        XCTAssertEqual(standard.yellowAt, 50)
        XCTAssertEqual(standard.redAt, 90, "90% keeps the menu bar's hidden-limit warning where it was")
        XCTAssertEqual(standard.numbers, .used)
        XCTAssertEqual(standard.resetStyle, .countdown)
        XCTAssertEqual(standard.menuBarIcon, .status)
        XCTAssertEqual(standard.menuBarText, .labelAndPercent)
        XCTAssertTrue(standard.shadeCharts)
        XCTAssertTrue(standard.showPaceGuides)
        XCTAssertTrue(standard.showForecastLines)
    }

    func testRoundTripsThroughJSON() throws {
        var appearance = Appearance()
        appearance.theme = .ocean
        appearance.colorMeaning = .pace
        appearance.yellowAt = 40
        appearance.redAt = 75
        appearance.numbers = .left
        appearance.resetStyle = .both
        appearance.menuBarIcon = .ring
        appearance.menuBarText = .percentAndReset
        appearance.shadeCharts = false
        appearance.showPaceGuides = false
        appearance.showForecastLines = false
        let data = try JSONEncoder().encode(appearance)
        XCTAssertEqual(try JSONDecoder().decode(Appearance.self, from: data), appearance)
    }

    func testUnknownOrMissingValuesFallBackOneAtATime() throws {
        let json = #"{"theme":"neon","numbers":"left","yellowAt":"lots","menuBarIcon":"ring"}"#
        let appearance = try JSONDecoder().decode(Appearance.self, from: Data(json.utf8))
        XCTAssertEqual(appearance.theme, .classic, "a theme from a newer version falls back to the default")
        XCTAssertEqual(appearance.numbers, .left)
        XCTAssertEqual(appearance.yellowAt, 50)
        XCTAssertEqual(appearance.menuBarIcon, .ring)
        XCTAssertEqual(try JSONDecoder().decode(Appearance.self, from: Data("{}".utf8)), .standard)
    }

    func testLevelsStayInOrderAndInRange() {
        var appearance = Appearance()
        appearance.yellowAt = 0
        appearance.redAt = 150
        XCTAssertEqual(appearance.sanitized().yellowAt, 5)
        XCTAssertEqual(appearance.sanitized().redAt, 100)

        appearance.yellowAt = 70
        appearance.redAt = 60
        XCTAssertEqual(appearance.sanitized().yellowAt, 70)
        XCTAssertEqual(appearance.sanitized().redAt, 75, "red always comes at least 5 points after yellow")

        appearance.yellowAt = 99
        XCTAssertEqual(appearance.sanitized().yellowAt, 95)
        XCTAssertEqual(appearance.sanitized().redAt, 100)
    }

    func testDecodingAlsoSanitizes() throws {
        let json = #"{"yellowAt":80,"redAt":20}"#
        let appearance = try JSONDecoder().decode(Appearance.self, from: Data(json.utf8))
        XCTAssertEqual(appearance.yellowAt, 80)
        XCTAssertEqual(appearance.redAt, 85)
    }

    func testTheMenuBarNeverEndsUpEmpty() {
        var appearance = Appearance()
        appearance.menuBarIcon = .none
        appearance.menuBarText = .none
        XCTAssertEqual(appearance.sanitized().menuBarIcon, .status)
        appearance.menuBarText = .percentOnly
        XCTAssertEqual(appearance.sanitized().menuBarIcon, .none, "text alone is fine")
    }

    // MARK: Themes

    /// Relative luminance, from the WCAG definition.
    func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    func testEveryThemeKeepsItsColorsApartAndReadableOnLightAndDark() {
        for theme in ColorTheme.allCases {
            let palette = theme.palette
            let series = [palette.allModels, palette.fable, palette.fiveHour]
            for first in 0..<series.count {
                for second in (first + 1)..<series.count {
                    XCTAssertGreaterThan(series[first].distance(to: series[second]), 0.25,
                                         "\(theme): chart colors \(first) and \(second) are too alike")
                }
            }
            for color in series {
                XCTAssert((0.08...0.6).contains(luminance(color)),
                          "\(theme): chart color \(color) would disappear on a light or dark background")
            }
            XCTAssertGreaterThan(palette.calm.distance(to: palette.alert), 0.35, "\(theme): calm and alert are too alike")
            XCTAssertGreaterThan(palette.calm.distance(to: palette.caution), 0.2, "\(theme): calm and caution are too alike")
            XCTAssertGreaterThan(palette.caution.distance(to: palette.alert), 0.15, "\(theme): caution and alert are too alike")
            for color in series + [palette.calm, palette.caution, palette.alert] {
                for channel in [color.red, color.green, color.blue] {
                    XCTAssert((0...1).contains(channel), "\(theme): \(color) is out of range")
                }
            }
            XCTAssertFalse(theme.title.isEmpty)
        }
    }

    func testThemesHaveStableSavedNames() {
        XCTAssertEqual(ColorTheme.allCases.map(\.rawValue), ["classic", "clay", "ocean", "dusk", "graphite", "colorBlindSafe"])
    }

    // MARK: What colors mean

    func testFullnessBlendsFromCalmThroughCautionToAlert() {
        let appearance = Appearance.standard
        let palette = appearance.theme.palette
        XCTAssertEqual(appearance.levelColor(for: 0), palette.calm)
        XCTAssertEqual(appearance.levelColor(for: 50), palette.caution)
        XCTAssertEqual(appearance.levelColor(for: 90), palette.alert)
        XCTAssertEqual(appearance.levelColor(for: 130), palette.alert)
        let distances = stride(from: 0.0, through: 90, by: 10).map { appearance.levelColor(for: $0).distance(to: palette.alert) }
        XCTAssertEqual(distances, distances.sorted(by: >), "colors move steadily toward alert as usage rises")
        let twenty = appearance.levelColor(for: 20)
        XCTAssertLessThan(twenty.distance(to: palette.calm), twenty.distance(to: palette.caution),
                          "well below the yellow level it still looks calm")
    }

    func testCustomLevelsMoveTheColors() {
        var appearance = Appearance()
        appearance.yellowAt = 30
        appearance.redAt = 60
        XCTAssertEqual(appearance.levelColor(for: 30), appearance.theme.palette.caution)
        XCTAssertEqual(appearance.levelColor(for: 60), appearance.theme.palette.alert)
    }

    func testPaceColorsFollowPaceAndFallBackToFullness() {
        var appearance = Appearance()
        appearance.colorMeaning = .pace
        let palette = appearance.theme.palette
        func reading(_ status: PaceStatus) -> PaceReading { PaceReading(elapsedFraction: 0.5, status: status) }
        XCTAssertEqual(appearance.color(percent: 30, pace: reading(.under(points: 20))), palette.calm)
        XCTAssertEqual(appearance.color(percent: 52, pace: reading(.onPace)), palette.calm, "using it evenly is fine")
        XCTAssertEqual(appearance.color(percent: 60, pace: reading(.ahead(points: 10))), palette.caution)
        XCTAssertEqual(appearance.color(percent: 70, pace: reading(.ahead(points: 20))), palette.alert)
        XCTAssertEqual(appearance.color(percent: 100, pace: reading(.onPace)), palette.alert, "a used-up limit is always alert")
        XCTAssertEqual(appearance.color(percent: 40, pace: nil), appearance.levelColor(for: 40),
                       "without a pace reading it colors by how full the limit is")
        XCTAssertNil(appearance.color(percent: nil, pace: nil))
        XCTAssertEqual(Appearance.standard.color(percent: 60, pace: reading(.under(points: 20))),
                       Appearance.standard.levelColor(for: 60), "fullness mode ignores pace")
    }

    // MARK: Used or left

    func testNumbersShowUsedOrLeft() {
        var appearance = Appearance()
        XCTAssertEqual(appearance.percentText(94), "94%")
        XCTAssertEqual(appearance.numberText(94), "94")
        XCTAssertEqual(appearance.numberCaption, "used")
        XCTAssertEqual(appearance.barFraction(94), 0.94, accuracy: 1e-9)
        XCTAssertEqual(appearance.paceMarkFraction(0.7), 0.7, accuracy: 1e-9)

        appearance.numbers = .left
        XCTAssertEqual(appearance.percentText(94), "6% left")
        XCTAssertEqual(appearance.numberText(94), "6")
        XCTAssertEqual(appearance.numberCaption, "left")
        XCTAssertEqual(appearance.barFraction(94), 0.06, accuracy: 1e-9)
        XCTAssertEqual(appearance.paceMarkFraction(0.7), 0.3, accuracy: 1e-9)
        XCTAssertEqual(appearance.percentText(130), "0% left", "never negative")
        XCTAssertEqual(appearance.barFraction(130), 0, accuracy: 1e-9)
        XCTAssertEqual(appearance.percentText(nil), "—")
        XCTAssertEqual(appearance.numberText(nil), "—")
    }

    // MARK: Menu bar symbols

    func testGaugeNeedleAndBatteryFollowUsage() {
        XCTAssertEqual(MenuBarSymbols.gauge(percentUsed: 5), "gauge.with.dots.needle.0percent")
        XCTAssertEqual(MenuBarSymbols.gauge(percentUsed: 30), "gauge.with.dots.needle.33percent")
        XCTAssertEqual(MenuBarSymbols.gauge(percentUsed: 50), "gauge.with.dots.needle.50percent")
        XCTAssertEqual(MenuBarSymbols.gauge(percentUsed: 70), "gauge.with.dots.needle.67percent")
        XCTAssertEqual(MenuBarSymbols.gauge(percentUsed: 95), "gauge.with.dots.needle.100percent")
        XCTAssertEqual(MenuBarSymbols.battery(percentUsed: 5), "battery.100percent")
        XCTAssertEqual(MenuBarSymbols.battery(percentUsed: 30), "battery.75percent")
        XCTAssertEqual(MenuBarSymbols.battery(percentUsed: 50), "battery.50percent")
        XCTAssertEqual(MenuBarSymbols.battery(percentUsed: 80), "battery.25percent")
        XCTAssertEqual(MenuBarSymbols.battery(percentUsed: 95), "battery.0percent")
    }

    func testEveryMenuBarSymbolExists() {
        var names = Set(MenuBarIconStyle.allCases.map(\.previewSymbol))
        for percent in stride(from: 0.0, through: 100, by: 1) {
            names.insert(MenuBarSymbols.gauge(percentUsed: percent))
            names.insert(MenuBarSymbols.battery(percentUsed: percent))
        }
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) isn't an SF Symbol")
        }
    }

    // MARK: Reset times

    func testResetPhrasesInEachStyle() {
        let today = at(14, 18, 10)
        func phrase(_ date: Date?, _ style: ResetStyle) -> String? {
            plain(UsageFormatting.resetPhrase(until: date, now: now, style: style, calendar: calendar, locale: locale))
        }
        XCTAssertEqual(phrase(today, .countdown), "Resets in 2h 10m")
        XCTAssertEqual(phrase(today, .clockTime), "Resets at 6:10 PM")
        XCTAssertEqual(phrase(today, .both), "Resets at 6:10 PM, in 2h 10m")

        let thursday = at(17, 3)
        XCTAssertEqual(phrase(thursday, .countdown), "Resets in 2d 11h")
        XCTAssertEqual(phrase(thursday, .clockTime), "Resets Thu 3:00 AM")
        XCTAssertEqual(phrase(thursday, .both), "Resets Thu 3:00 AM, in 2d 11h")

        XCTAssertEqual(phrase(at(21, 3), .clockTime), "Resets Mon, Sep 21 at 3:00 AM", "a week away also shows the date")
        XCTAssertEqual(phrase(now.addingTimeInterval(-60), .clockTime), "Resets now")
        XCTAssertNil(phrase(nil, .both))
    }

    // MARK: Menu bar text

    func testMenuBarTextStyles() {
        let snapshot = UsageSnapshot(fiveHourPercent: 30.4, fiveHourResetsAt: at(14, 18, 10),
                                     weeklyPercent: 91, weeklyResetsAt: at(17, 3),
                                     fableWeeklyPercent: 94, fableWeeklyResetsAt: at(17, 3))
        let headline = Headline.make(for: snapshot, metric: .fiveHour, now: now)
        func text(_ change: (inout Appearance) -> Void) -> String? {
            var appearance = Appearance()
            change(&appearance)
            return plain(headline.menuBarText(appearance, now: now, calendar: calendar, locale: locale))
        }
        let flag = "\u{26A0}\u{FE0E}W F"
        XCTAssertEqual(text { _ in }, "5h 30% \(flag)")
        XCTAssertEqual(text { $0.menuBarText = .percentOnly }, "30% \(flag)")
        XCTAssertEqual(text { $0.menuBarText = .percentAndReset }, "5h 30% · 2h 10m \(flag)")
        XCTAssertEqual(text { $0.menuBarText = .percentAndReset; $0.resetStyle = .clockTime }, "5h 30% · 6:10 PM \(flag)")
        XCTAssertEqual(text { $0.menuBarText = .none }, flag, "an important warning still shows without other text")
        XCTAssertEqual(text { $0.numbers = .left }, "5h 70% left \(flag)")
        XCTAssertEqual(headline.menuBarText, "5h 30% \(flag)", "the plain property keeps the standard look")

        let quiet = Headline.make(for: UsageSnapshot(fiveHourPercent: 30.4), metric: .fiveHour, now: now)
        var iconOnly = Appearance()
        iconOnly.menuBarText = .none
        XCTAssertEqual(quiet.menuBarText(iconOnly, now: now), "")
        XCTAssertEqual(Headline.make(for: nil, metric: .auto).menuBarText(iconOnly, now: now), "—")
    }

    func testHiddenWarningUsesTheRedLevel() {
        let snapshot = UsageSnapshot(fiveHourPercent: 20, fableWeeklyPercent: 80)
        XCTAssertEqual(Headline.make(for: snapshot, metric: .fiveHour, warningAt: 75).hiddenWarningLimits, [.fableWeekly])
        XCTAssertEqual(Headline.make(for: snapshot, metric: .fiveHour).hiddenWarningLimits, [], "90% by default")
    }

    // MARK: One limit, ready to draw

    func testLimitDisplayFollowsTheAppearance() {
        var appearance = Appearance()
        appearance.numbers = .left
        appearance.resetStyle = .clockTime
        let snapshot = UsageSnapshot(weeklyPercent: 89.6, weeklyResetsAt: at(17, 3))
        let display = LimitDisplay.make(.weekly, snapshot: snapshot, now: now, isStale: false, appearance: appearance,
                                        calendar: calendar, locale: locale)
        XCTAssertEqual(display.percent, 89)
        XCTAssertEqual(display.percentText, "11% left")
        XCTAssertEqual(display.numberText, "11")
        XCTAssertEqual(plain(display.resetText), "Resets Thu 3:00 AM")
        XCTAssertEqual(display.barFraction, 0.11, accuracy: 1e-9)
        let pace = try? XCTUnwrap(display.pace)
        XCTAssertEqual(display.paceMarkFraction ?? -1, 1 - (pace?.elapsedFraction ?? 0), accuracy: 1e-9)
        XCTAssertEqual(display.tint, appearance.color(percent: 89, pace: display.pace))

        appearance.showPaceGuides = false
        let noGuides = LimitDisplay.make(.weekly, snapshot: snapshot, now: now, isStale: false, appearance: appearance)
        XCTAssertNil(noGuides.paceMarkFraction, "pace marks can be hidden")
        XCTAssertNotNil(noGuides.pace, "the pace wording stays")

        let unknown = LimitDisplay.make(.fableWeekly, snapshot: snapshot, now: now, isStale: false, appearance: appearance)
        XCTAssertNil(unknown.tint)
        XCTAssertEqual(unknown.percentText, "—")
        XCTAssertEqual(unknown.barFraction, 0)
    }

    func testMomentMatchesTheForecastWording() {
        XCTAssertEqual(plain(UsageFormatting.moment(at(14, 21, 40), now: now, calendar: calendar, locale: locale)), "9:40 PM")
        XCTAssertEqual(plain(UsageFormatting.moment(at(16, 21, 40), now: now, calendar: calendar, locale: locale)), "Wed 9:40 PM")
        XCTAssertEqual(plain(UsageFormatting.moment(at(20, 9, 0), now: now, calendar: calendar, locale: locale)),
                       "Sun, Sep 20 at 9:00 AM")
    }

    // MARK: Simple choices

    func testWarningsComeInThreeSimpleSettings() {
        XCTAssertEqual(WarningLevel.allCases.map(\.title), ["Early", "Normal", "Late"])
        XCTAssertEqual([WarningLevel.early, .normal, .late].map(\.yellowAt), [40, 50, 65])
        XCTAssertEqual([WarningLevel.early, .normal, .late].map(\.redAt), [75, 90, 95])
        XCTAssertEqual(WarningLevel(appearance: .standard), .normal, "the default look is Normal")
        var custom = Appearance()
        custom.yellowAt = 30
        custom.redAt = 60
        XCTAssertNil(WarningLevel(appearance: custom), "levels set by hand count as custom")
        var appearance = Appearance()
        WarningLevel.early.apply(to: &appearance)
        XCTAssertEqual(appearance.yellowAt, 40)
        XCTAssertEqual(appearance.redAt, 75)
    }

    func testMenuBarStylesPairAnIconWithText() {
        XCTAssertEqual(MenuBarStyle.allCases.count, 6)
        for style in MenuBarStyle.allCases {
            var appearance = Appearance()
            style.apply(to: &appearance)
            XCTAssertEqual(MenuBarStyle(appearance: appearance), style, "\(style) should round-trip")
            XCTAssertFalse(style.title.isEmpty)
            XCTAssertFalse(appearance.menuBarIcon == .none && appearance.menuBarText == .none, "a style never hides everything")
        }
        XCTAssertEqual(MenuBarStyle(appearance: .standard), .gauge, "the default look is the gauge")
        var older = Appearance()
        older.menuBarIcon = .gauge
        XCTAssertEqual(MenuBarStyle(appearance: older), .gauge, "both gauge settings count as the gauge style")
        var unusual = Appearance()
        unusual.menuBarIcon = .battery
        unusual.menuBarText = .none
        XCTAssertNil(MenuBarStyle(appearance: unusual), "a combination no style uses isn't shown as one")
    }
}
