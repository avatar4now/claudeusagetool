import XCTest
@testable import UsageCore

final class UsageFormattingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_416_000)

    func testWholePercentRoundsDownLikeClaudeCode() {
        XCTAssertEqual(UsageFormatting.wholePercent(42.9), 42)
        XCTAssertEqual(UsageFormatting.wholePercent(0), 0)
        XCTAssertEqual(UsageFormatting.wholePercent(100), 100)
        XCTAssertEqual(UsageFormatting.wholePercent(-3), 0)
        XCTAssertNil(UsageFormatting.wholePercent(nil))
    }

    func testPercentTextShowsADashWhenUnknown() {
        XCTAssertEqual(UsageFormatting.percentText(61.5), "61%")
        XCTAssertEqual(UsageFormatting.percentText(nil), "—")
    }

    func testResetTextUsesTheLargestSensibleUnits() {
        XCTAssertNil(UsageFormatting.resetText(until: nil, now: now))
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(45 * 60 + 30), now: now), "45m")
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now), "2h 5m")
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(86400), now: now), "1d 0h")
        XCTAssertEqual(UsageFormatting.resetText(until: now.addingTimeInterval(3 * 86400 + 4 * 3600 + 59 * 60), now: now), "3d 4h")
    }

    func testMenuBarTitleShowsTheFiveHourPercent() {
        XCTAssertEqual(UsageFormatting.menuBarTitle(for: UsageSnapshot(fiveHourPercent: 42.7, weeklyPercent: 7)), "42%")
        XCTAssertEqual(UsageFormatting.menuBarTitle(for: UsageSnapshot(weeklyPercent: 7)), "—")
        XCTAssertEqual(UsageFormatting.menuBarTitle(for: nil), "—")
    }
}
