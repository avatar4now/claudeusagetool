import XCTest
@testable import UsageCore

final class UsageHistoryTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// A local time in New York on a day in September 2026 (14 is a Monday).
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    // MARK: Recording policy

    func testRecordsTheFirstReadingThenAtMostEveryFiveMinutesUnlessSomethingChangesMeaningfully() {
        let reset = at(18, 12)
        let first = UsageSample(at: at(14, 9), fiveHour: 20, fiveHourReset: at(14, 13), weekly: 40, weeklyReset: reset,
                                fable: 50, fableReset: reset)
        XCTAssertTrue(HistoryPolicy.shouldRecord(first, after: nil))

        var soon = first
        soon.at = at(14, 9, 2)
        XCTAssertFalse(HistoryPolicy.shouldRecord(soon, after: first))

        var later = first
        later.at = at(14, 9, 6)
        XCTAssertTrue(HistoryPolicy.shouldRecord(later, after: first))

        var jump = soon
        jump.fiveHour = 26
        XCTAssertTrue(HistoryPolicy.shouldRecord(jump, after: first), "a jump of 5 points or more is worth keeping")

        var rolled = soon
        rolled.fiveHourReset = at(14, 18)
        XCTAssertTrue(HistoryPolicy.shouldRecord(rolled, after: first), "a new window is always recorded")
    }

    func testSamplesAreBuiltFromSnapshots() {
        let snapshot = UsageSnapshot(fiveHourPercent: 22, fiveHourResetsAt: at(14, 13), weeklyPercent: 89,
                                     weeklyResetsAt: at(18, 12), fableWeeklyPercent: 94, fableWeeklyResetsAt: at(18, 12))
        let sample = UsageSample(snapshot: snapshot, at: at(14, 9))
        XCTAssertEqual(sample, UsageSample(at: at(14, 9), fiveHour: 22, fiveHourReset: at(14, 13), weekly: 89,
                                           weeklyReset: at(18, 12), fable: 94, fableReset: at(18, 12)))
    }

    // MARK: Daily totals

    func testDailyWeeklyPointsCountRisesWithinAWindowAndRestartAfterAReset() {
        let reset = at(18, 12)
        let next = at(25, 12)
        let samples = [
            UsageSample(at: at(14, 9), fiveHour: nil, fiveHourReset: nil, weekly: 10, weeklyReset: reset, fable: 5, fableReset: reset),
            UsageSample(at: at(14, 12), fiveHour: nil, fiveHourReset: nil, weekly: 14, weeklyReset: reset, fable: 8, fableReset: reset),
            UsageSample(at: at(14, 18), fiveHour: nil, fiveHourReset: nil, weekly: 20, weeklyReset: reset, fable: 12, fableReset: reset),
            UsageSample(at: at(15, 10), fiveHour: nil, fiveHourReset: nil, weekly: 22, weeklyReset: reset, fable: 13, fableReset: reset),
            UsageSample(at: at(15, 11), fiveHour: nil, fiveHourReset: nil, weekly: 21, weeklyReset: reset, fable: 13, fableReset: reset),
            UsageSample(at: at(15, 12), fiveHour: nil, fiveHourReset: nil, weekly: 25, weeklyReset: reset, fable: 15, fableReset: reset),
            UsageSample(at: at(18, 13), fiveHour: nil, fiveHourReset: nil, weekly: 3, weeklyReset: next, fable: 1, fableReset: next),
        ]
        let days = UsageHistoryAnalysis.daily(samples, days: 5, endingOn: at(18, 20), calendar: calendar)
        XCTAssertEqual(days.map(\.day), [at(14, 0), at(15, 0), at(16, 0), at(17, 0), at(18, 0)])

        XCTAssertEqual(days[0].weeklyPoints, 10, "the first reading has no earlier one to compare with")
        XCTAssertEqual(days[0].fablePoints, 7)
        XCTAssertTrue(days[0].hasReadings)
        XCTAssertFalse(days[0].includesTimeAppWasClosed)

        XCTAssertEqual(days[1].weeklyPoints, 6, "a small downward correction counts as zero, not negative")
        XCTAssertEqual(days[1].fablePoints, 3)
        XCTAssertTrue(days[1].includesTimeAppWasClosed, "the overnight gap's usage lands on the next reading's day")

        XCTAssertFalse(days[2].hasReadings)
        XCTAssertEqual(days[2].weeklyPoints, 0)

        XCTAssertEqual(days[4].weeklyPoints, 3, "after a reset, usage counts from zero")
        XCTAssertEqual(days[4].fablePoints, 1)
    }

    func testDailyFiveHourPeaksAndSessionsThatReachedNinetyPercent() {
        let samples = [
            UsageSample(at: at(14, 9), fiveHour: 40, fiveHourReset: at(14, 14), weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(14, 13), fiveHour: 92, fiveHourReset: at(14, 14), weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(14, 13, 30), fiveHour: 95, fiveHourReset: at(14, 14, 3), weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(14, 16), fiveHour: 91, fiveHourReset: at(14, 19), weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(15, 10), fiveHour: 50, fiveHourReset: at(15, 13), weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
        ]
        let days = UsageHistoryAnalysis.daily(samples, days: 2, endingOn: at(15, 20), calendar: calendar)
        XCTAssertEqual(days[0].peakFiveHour, 95)
        XCTAssertEqual(days[0].fiveHourSessionsOverNinety, 2, "reset times a few minutes apart are the same session")
        XCTAssertEqual(days[1].peakFiveHour, 50)
        XCTAssertEqual(days[1].fiveHourSessionsOverNinety, 0)
    }

    // MARK: Charts

    func testCurrentWeekSeriesFollowsTheLatestWeeklyWindow() throws {
        let old = at(11, 12)
        let reset = at(18, 12)
        let samples = [
            UsageSample(at: at(10, 9), fiveHour: nil, fiveHourReset: nil, weekly: 80, weeklyReset: old, fable: 70, fableReset: old),
            UsageSample(at: at(12, 9), fiveHour: nil, fiveHourReset: nil, weekly: 5, weeklyReset: reset, fable: 4, fableReset: reset),
            UsageSample(at: at(14, 9), fiveHour: nil, fiveHourReset: nil, weekly: 40, weeklyReset: reset, fable: 44, fableReset: reset),
        ]
        let week = try XCTUnwrap(UsageHistoryAnalysis.currentWeek(samples, now: at(14, 10)))
        XCTAssertEqual(week.start, at(11, 12))
        XCTAssertEqual(week.end, reset)
        XCTAssertEqual(week.points.map(\.at), [at(12, 9), at(14, 9)])
        XCTAssertEqual(week.points.map(\.weekly), [5, 40])
        XCTAssertEqual(week.points.map(\.fable), [4, 44])
        XCTAssertNil(UsageHistoryAnalysis.currentWeek([], now: at(14, 10)))
    }

    func testRecentFiveHourSeriesKeepsOnlyTheLastDay() {
        let samples = [
            UsageSample(at: at(13, 9), fiveHour: 10, fiveHourReset: nil, weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(14, 9), fiveHour: 30, fiveHourReset: nil, weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil),
            UsageSample(at: at(14, 10), fiveHour: nil, fiveHourReset: nil, weekly: 5, weeklyReset: nil, fable: nil, fableReset: nil),
        ]
        let series = UsageHistoryAnalysis.recentFiveHour(samples, now: at(14, 12))
        XCTAssertEqual(series.map(\.at), [at(14, 9)])
        XCTAssertEqual(series.map(\.value), [30])
    }

    // MARK: Storage

    func makeStore() throws -> (UsageHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (UsageHistoryStore(directory: directory), directory)
    }

    func testAppendAndLoadRoundTripAndTheFileIsPrivate() throws {
        let (store, _) = try makeStore()
        let a = UsageSample(at: at(14, 9), fiveHour: 20, fiveHourReset: at(14, 13), weekly: 40, weeklyReset: at(18, 12), fable: nil, fableReset: nil)
        let b = UsageSample(at: at(14, 10), fiveHour: 25, fiveHourReset: at(14, 13), weekly: 41, weeklyReset: at(18, 12), fable: 3, fableReset: at(18, 12))
        try store.append(a)
        try store.append(b)
        XCTAssertEqual(store.load(now: at(14, 12)), [a, b])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testDamagedLinesAreSkippedAndOldReadingsExpire() throws {
        let (store, _) = try makeStore()
        let old = UsageSample(at: at(1, 9), fiveHour: 1, fiveHourReset: nil, weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil)
        let recent = UsageSample(at: at(14, 9), fiveHour: 2, fiveHourReset: nil, weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil)
        try store.append(old)
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try store.append(recent)

        let now = at(14, 12)
        XCTAssertEqual(store.load(now: now, retention: 10 * 86_400), [recent])
        try store.compact(now: now, retention: 10 * 86_400)
        XCTAssertEqual(store.load(now: now, retention: 365 * 86_400), [recent], "compacting removes expired and damaged lines")
    }

    func testClearDeletesEverything() throws {
        let (store, _) = try makeStore()
        try store.append(UsageSample(at: at(14, 9), fiveHour: 2, fiveHourReset: nil, weekly: nil, weeklyReset: nil, fable: nil, fableReset: nil))
        try store.clear()
        XCTAssertEqual(store.load(now: at(14, 12)), [])
        XCTAssertNoThrow(try store.clear())
    }
}
