import XCTest
@testable import UsageCore

final class GlanceTests: XCTestCase {
    /// Monday 2026-09-14 20:00:00 UTC.
    let now = Date(timeIntervalSince1970: 1_789_416_000)

    // MARK: Headline (menu bar)

    func testAutoHeadlinesTheLimitClosestToFull() {
        let headline = Headline.make(for: UsageSnapshot(fiveHourPercent: 20, weeklyPercent: 67, fableWeeklyPercent: 94.8), metric: .auto)
        XCTAssertEqual(headline.limit, .fableWeekly)
        XCTAssertEqual(headline.text, "F 94%")
        XCTAssertFalse(headline.hiddenLimitWarning, "Auto already shows the tightest limit")
    }

    func testAutoIgnoresMissingValuesAndBreaksTiesInDisplayOrder() {
        XCTAssertEqual(Headline.make(for: UsageSnapshot(weeklyPercent: 7), metric: .auto).text, "W 7%")
        XCTAssertEqual(Headline.make(for: UsageSnapshot(fiveHourPercent: 50, weeklyPercent: 50), metric: .auto).limit, .fiveHour)
    }

    func testFixedMetricNamesItsLimitAndWarnsAboutAHighHiddenLimit() {
        let snapshot = UsageSnapshot(fiveHourPercent: 20, weeklyPercent: 67, fableWeeklyPercent: 92.4)
        let headline = Headline.make(for: snapshot, metric: .fiveHour)
        XCTAssertEqual(headline.text, "5h 20%")
        XCTAssertTrue(headline.hiddenLimitWarning)
        XCTAssertFalse(Headline.make(for: UsageSnapshot(fiveHourPercent: 20, fableWeeklyPercent: 89.9), metric: .fiveHour).hiddenLimitWarning)
    }

    func testMissingValuesShowADash() {
        XCTAssertEqual(Headline.make(for: UsageSnapshot(fiveHourPercent: 20), metric: .fableWeekly).text, "F —")
        let empty = Headline.make(for: nil, metric: .auto)
        XCTAssertEqual(empty.text, "—")
        XCTAssertNil(empty.limit)
    }

    // MARK: Pace

    func testPaceComparesUsageWithElapsedTime() throws {
        let halfway = now.addingTimeInterval(9000) // 2.5 h left of a 5 h window
        let window = LimitKind.fiveHour.windowLength
        let reading = try XCTUnwrap(Pace.reading(percent: 50, resetsAt: halfway, window: window, now: now))
        XCTAssertEqual(reading.elapsedFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reading.status, .onPace)
        XCTAssertEqual(Pace.reading(percent: 62, resetsAt: halfway, window: window, now: now)?.status, .ahead(points: 12))
        XCTAssertEqual(Pace.reading(percent: 42, resetsAt: halfway, window: window, now: now)?.status, .under(points: 8))
        XCTAssertEqual(Pace.reading(percent: 54.9, resetsAt: halfway, window: window, now: now)?.status, .onPace)
    }

    func testWeeklyPaceUsesSevenDays() {
        let reading = Pace.reading(percent: 50, resetsAt: now.addingTimeInterval(3.5 * 86_400),
                                   window: LimitKind.fableWeekly.windowLength, now: now)
        XCTAssertEqual(reading?.status, .onPace)
    }

    func testPaceLabels() {
        XCTAssertEqual(PaceStatus.onPace.label, "On pace")
        XCTAssertEqual(PaceStatus.ahead(points: 12).label, "12 pts ahead of pace")
        XCTAssertEqual(PaceStatus.under(points: 8).label, "8 pts under pace")
    }

    func testPaceIsHiddenWhenItCannotBeTrusted() {
        let window = LimitKind.fiveHour.windowLength
        XCTAssertNil(Pace.reading(percent: nil, resetsAt: now.addingTimeInterval(9000), window: window, now: now))
        XCTAssertNil(Pace.reading(percent: 50, resetsAt: nil, window: window, now: now))
        XCTAssertNil(Pace.reading(percent: 50, resetsAt: now.addingTimeInterval(-1), window: window, now: now), "reset already passed")
        XCTAssertNil(Pace.reading(percent: 1, resetsAt: now.addingTimeInterval(window * 0.98), window: window, now: now),
                     "too early in the window")
        XCTAssertNil(Pace.reading(percent: 50, resetsAt: now.addingTimeInterval(window + 600), window: window, now: now),
                     "a reset further away than the window length is inconsistent")
    }

    // MARK: Freshness

    func testReadingsGoStaleAfterThreeMissedIntervals() {
        XCTAssertFalse(Freshness.isStale(fetchedAt: now.addingTimeInterval(-359), refreshSeconds: 120, now: now))
        XCTAssertTrue(Freshness.isStale(fetchedAt: now.addingTimeInterval(-361), refreshSeconds: 120, now: now))
        XCTAssertTrue(Freshness.isStale(fetchedAt: nil, refreshSeconds: 120, now: now))
        XCTAssertTrue(Freshness.isStale(fetchedAt: now.addingTimeInterval(600), refreshSeconds: 120, now: now),
                      "a reading from the future is not trustworthy")
        XCTAssertEqual(Freshness.staleAt(fetchedAt: now, refreshSeconds: 120), now.addingTimeInterval(360))
    }

    // MARK: Limit rows

    func testLimitDisplayHidesPaceForStaleDataAndMarksPassedResets() {
        let snapshot = UsageSnapshot(fiveHourPercent: 62.9, fiveHourResetsAt: now.addingTimeInterval(9000),
                                     weeklyPercent: nil, weeklyResetsAt: nil,
                                     fableWeeklyPercent: 90, fableWeeklyResetsAt: now.addingTimeInterval(-10))
        let fiveHour = LimitDisplay.make(.fiveHour, snapshot: snapshot, now: now, isStale: false)
        XCTAssertEqual(fiveHour.percent, 62)
        XCTAssertEqual(fiveHour.pace?.status, .ahead(points: 13))
        XCTAssertFalse(fiveHour.awaitingReset)

        XCTAssertNil(LimitDisplay.make(.fiveHour, snapshot: snapshot, now: now, isStale: true).pace)

        let weekly = LimitDisplay.make(.weekly, snapshot: snapshot, now: now, isStale: false)
        XCTAssertNil(weekly.percent, "missing stays unknown, never 0")

        let fable = LimitDisplay.make(.fableWeekly, snapshot: snapshot, now: now, isStale: false)
        XCTAssertTrue(fable.awaitingReset)
        XCTAssertNil(fable.pace)
        XCTAssertEqual(fable.resetText, "Awaiting reset")
        XCTAssertEqual(fiveHour.resetText, "Resets in 2h 30m")
    }

    // MARK: Reset boundaries and scheduling

    func testTimelineAddsEntriesAtResetsBeforeTheNextReload() {
        let snapshot = UsageSnapshot(fiveHourPercent: 90, fiveHourResetsAt: now.addingTimeInterval(60),
                                     weeklyPercent: 10, weeklyResetsAt: now.addingTimeInterval(86_400),
                                     fableWeeklyPercent: 5, fableWeeklyResetsAt: now.addingTimeInterval(60))
        XCTAssertEqual(ResetBoundary.entryDates(for: snapshot, now: now, before: now.addingTimeInterval(120)),
                       [now.addingTimeInterval(60)])
        XCTAssertEqual(ResetBoundary.entryDates(for: nil, now: now, before: now.addingTimeInterval(120)), [])
    }

    func testNextRefreshComesSoonAfterAResetButNeverBeforeACooldownEnds() {
        let snapshot = UsageSnapshot(fiveHourPercent: 90, fiveHourResetsAt: now.addingTimeInterval(30))
        XCTAssertEqual(RefreshSchedule.nextRefresh(after: now, refreshSeconds: 120, snapshot: snapshot, cooldown: nil),
                       now.addingTimeInterval(60))
        XCTAssertEqual(RefreshSchedule.nextRefresh(after: now, refreshSeconds: 120, snapshot: nil, cooldown: nil),
                       now.addingTimeInterval(120))
        let passed = UsageSnapshot(fiveHourPercent: 90, fiveHourResetsAt: now.addingTimeInterval(-300))
        XCTAssertEqual(RefreshSchedule.nextRefresh(after: now, refreshSeconds: 120, snapshot: passed, cooldown: nil),
                       now.addingTimeInterval(120), "a reset that already passed must not cause rapid polling")
        let cooldown = Cooldown(until: now.addingTimeInterval(600), fromServer: true, needsReview: false)
        XCTAssertEqual(RefreshSchedule.nextRefresh(after: now, refreshSeconds: 120, snapshot: snapshot, cooldown: cooldown),
                       now.addingTimeInterval(600))
    }

    func testFirstRefreshAfterLaunchWaitsForTheCachedReadingToAge() {
        XCTAssertEqual(RefreshSchedule.firstRefresh(now: now, refreshSeconds: 120, lastSuccessAt: now.addingTimeInterval(-30), cooldown: nil),
                       now.addingTimeInterval(90))
        XCTAssertEqual(RefreshSchedule.firstRefresh(now: now, refreshSeconds: 120, lastSuccessAt: now.addingTimeInterval(-600), cooldown: nil), now)
        XCTAssertEqual(RefreshSchedule.firstRefresh(now: now, refreshSeconds: 120, lastSuccessAt: nil, cooldown: nil), now)
        let cooldown = Cooldown(until: now.addingTimeInterval(300), fromServer: true, needsReview: false)
        XCTAssertEqual(RefreshSchedule.firstRefresh(now: now, refreshSeconds: 120, lastSuccessAt: nil, cooldown: cooldown),
                       now.addingTimeInterval(300), "relaunching never skips a server cooldown")
    }
}
