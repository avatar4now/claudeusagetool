import XCTest
@testable import UsageCore

final class ForecastTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86_400

    /// A local time in New York on a day in September 2026 (14 is a Monday).
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Monday 2026-09-14 4:00 PM in New York.
    var now: Date { at(14, 16) }

    func sample(hoursAgo: Double, weekly: Double? = nil, weeklyReset: Date? = nil, fable: Double? = nil,
                fableReset: Date? = nil, fiveHour: Double? = nil, fiveHourReset: Date? = nil) -> UsageSample {
        UsageSample(at: now.addingTimeInterval(-hoursAgo * hour), fiveHour: fiveHour, fiveHourReset: fiveHourReset,
                    weekly: weekly, weeklyReset: weeklyReset, fable: fable, fableReset: fableReset)
    }

    func forecast(_ outcome: ForecastOutcome) -> LimitForecast? {
        if case .forecast(let forecast) = outcome { return forecast }
        return nil
    }

    /// Formatted times use a narrow no-break space before AM/PM; tests compare with a plain space.
    func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: When there is no forecast

    func testUnavailableWithoutASnapshotAPercentOrAResetTime() {
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: nil, samples: [], now: now, isStale: false), .unavailable)
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(fiveHourPercent: 20), samples: [], now: now, isStale: false),
                       .unavailable)
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 40), samples: [], now: now, isStale: false),
                       .unavailable, "without a reset time there is nothing to forecast toward")
    }

    func testUnavailableWhenTheNumbersAreStale() {
        let snapshot = UsageSnapshot(weeklyPercent: 40, weeklyResetsAt: now.addingTimeInterval(2 * day))
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: snapshot, samples: [], now: now, isStale: true), .unavailable)
        let full = UsageSnapshot(weeklyPercent: 100, weeklyResetsAt: now.addingTimeInterval(2 * day))
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: full, samples: [], now: now, isStale: true), .unavailable)
    }

    func testUnavailableOnceTheResetTimeHasPassed() {
        let passed = UsageSnapshot(weeklyPercent: 40, weeklyResetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: passed, samples: [], now: now, isStale: false), .unavailable)
        let exactlyNow = UsageSnapshot(fiveHourPercent: 100, fiveHourResetsAt: now)
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: exactlyNow, samples: [], now: now, isStale: false), .unavailable,
                       "a full window whose reset has passed is no longer a current limit")
    }

    func testUnavailableWhenTheResetIsMoreThanOneWindowAway() {
        let tooFar = UsageSnapshot(fiveHourPercent: 10, fiveHourResetsAt: now.addingTimeInterval(5 * hour + 61))
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: tooFar, samples: [], now: now, isStale: false), .unavailable)
        let wobble = UsageSnapshot(fiveHourPercent: 10, fiveHourResetsAt: now.addingTimeInterval(5 * hour + 60))
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: wobble, samples: [], now: now, isStale: false),
                       .tooEarly(resetsAt: now.addingTimeInterval(5 * hour + 60)), "up to a minute of wobble is allowed")
    }

    func testLimitReachedAtOneHundredPercent() {
        let reset = now.addingTimeInterval(2 * day)
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 100, weeklyResetsAt: reset),
                                          samples: [], now: now, isStale: false), .limitReached(resetsAt: reset))
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 100.5),
                                          samples: [], now: now, isStale: false), .limitReached(resetsAt: nil),
                       "a full limit is still full when the reset time is missing")
        let early = now.addingTimeInterval(4 * hour + 55 * 60)
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 100, fiveHourResetsAt: early),
                                          samples: [], now: now, isStale: false), .limitReached(resetsAt: early),
                       "a full limit is reported even in the first minutes of a window")
    }

    func testTooEarlyInTheFirstFifteenMinutesOfAFiveHourSession() {
        let fourteenMinutesIn = now.addingTimeInterval(5 * hour - 14 * 60)
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 10, fiveHourResetsAt: fourteenMinutesIn),
                                          samples: [], now: now, isStale: false), .tooEarly(resetsAt: fourteenMinutesIn))
        let fifteenMinutesIn = now.addingTimeInterval(5 * hour - 15 * 60)
        let result = forecast(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 10, fiveHourResetsAt: fifteenMinutesIn),
                                                 samples: [], now: now, isStale: false))
        XCTAssertEqual(result?.pointsPerHour ?? 0, 40, accuracy: 1e-9)
        let nothingUsedEarly = UsageSnapshot(fiveHourPercent: 0, fiveHourResetsAt: fourteenMinutesIn)
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: nothingUsedEarly, samples: [], now: now, isStale: false),
                       .tooEarly(resetsAt: fourteenMinutesIn), "too early wins over no usage")
    }

    func testTooEarlyInTheFirstThreePercentOfAWeek() {
        let fiveHoursIn = now.addingTimeInterval(7 * day - 5 * hour)
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 4, weeklyResetsAt: fiveHoursIn),
                                          samples: [], now: now, isStale: false), .tooEarly(resetsAt: fiveHoursIn))
        let laterIn = now.addingTimeInterval(7 * day - 5.1 * hour)
        XCTAssertNotNil(forecast(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 4, weeklyResetsAt: laterIn),
                                                    samples: [], now: now, isStale: false)))
        XCTAssertEqual(UsageForecast.minimumElapsed(for: .weekly), 7 * day * 0.03, accuracy: 1e-6)
        XCTAssertEqual(UsageForecast.minimumElapsed(for: .fiveHour), 15 * 60, accuracy: 1e-6)
    }

    func testNoUsageYetBelowOnePercent() {
        let reset = now.addingTimeInterval(2 * hour)
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 0.5, fiveHourResetsAt: reset),
                                          samples: [], now: now, isStale: false), .noUsageYet(resetsAt: reset))
        XCTAssertNotNil(forecast(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 1, fiveHourResetsAt: reset),
                                                    samples: [], now: now, isStale: false)))
    }

    func testNoUsageYetWhenNothingIsUsedAndThereIsNoResetTime() {
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 0), samples: [], now: now, isStale: false),
                       .noUsageYet(resetsAt: nil), "between sessions the 5-hour limit is 0% with no reset time")
        XCTAssertEqual(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 0), samples: [], now: now, isStale: false),
                       .noUsageYet(resetsAt: nil))
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 0), samples: [], now: now, isStale: true),
                       .unavailable, "stale numbers still get no forecast")
        XCTAssertEqual(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 1), samples: [], now: now, isStale: false),
                       .unavailable, "some usage with no reset time still has nothing to forecast toward")
    }

    // MARK: The five-hour session

    func testFiveHourUsesTheSessionSoFarAndShouldLast() throws {
        let reset = now.addingTimeInterval(3 * hour)
        let dayOld = sample(hoursAgo: 24, fiveHour: 0, fiveHourReset: reset)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 30, fiveHourResetsAt: reset),
                                                               samples: [dayOld], now: now, isStale: false)))
        XCTAssertEqual(result.kind, .fiveHour)
        XCTAssertEqual(result.basis, .windowSoFar, "the 5-hour limit never looks back a day")
        XCTAssertEqual(result.percent, 30)
        XCTAssertEqual(result.resetsAt, reset)
        XCTAssertEqual(result.pointsPerHour, 15, accuracy: 1e-9)
        XCTAssertEqual(result.projectedAtReset, 75, accuracy: 1e-9)
        XCTAssertNil(result.runsOutAt)
        XCTAssertEqual(result.pointsLeft, 70, accuracy: 1e-9)
        XCTAssertNil(result.dailyBudget)
        XCTAssertNil(result.recentPointsPerDay)
        XCTAssertEqual(ForecastStatus(.forecast(result)), .shouldLast)
    }

    func testFiveHourRunsOutBeforeItsReset() throws {
        let reset = now.addingTimeInterval(3 * hour)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.fiveHour, snapshot: UsageSnapshot(fiveHourPercent: 50, fiveHourResetsAt: reset),
                                                               samples: [], now: now, isStale: false)))
        XCTAssertEqual(result.pointsPerHour, 25, accuracy: 1e-9)
        XCTAssertEqual(result.projectedAtReset, 125, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.runsOutAt).timeIntervalSince(now), 2 * hour, accuracy: 0.001)
        XCTAssertEqual(ForecastStatus(.forecast(result)), .runsOut)
    }

    // MARK: Weekly limits and the last day

    func testWeeklyUsesTheMostRecentReadingFromAboutADayAgo() throws {
        let reset = now.addingTimeInterval(2 * day)
        let samples = [
            sample(hoursAgo: 30, weekly: 50, weeklyReset: reset),
            sample(hoursAgo: 26, weekly: 60, weeklyReset: reset),
            sample(hoursAgo: 21, weekly: 68, weeklyReset: reset.addingTimeInterval(5 * 60)),
            sample(hoursAgo: 20.5, weekly: nil, weeklyReset: reset),
            sample(hoursAgo: 10, weekly: 80, weeklyReset: reset)
        ]
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 89, weeklyResetsAt: reset),
                                                               samples: samples, now: now, isStale: false)))
        XCTAssertEqual(result.basis, .lastDay)
        XCTAssertEqual(result.pointsPerHour, 1, accuracy: 1e-9, "21 points over the 21 hours since the reading at 68%")
        XCTAssertEqual(result.projectedAtReset, 137, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.runsOutAt).timeIntervalSince(now), 11 * hour, accuracy: 0.001)
        XCTAssertEqual(result.pointsLeft, 11, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.dailyBudget), 5.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.recentPointsPerDay), 24, accuracy: 1e-9)
    }

    func testWeeklyFallsBackToTheWindowSoFarWithoutADayOldReading() throws {
        let reset = now.addingTimeInterval(2 * day)
        let snapshot = UsageSnapshot(weeklyPercent: 89, weeklyResetsAt: reset)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: [], now: now, isStale: false)))
        XCTAssertEqual(result.basis, .windowSoFar)
        XCTAssertEqual(result.pointsPerHour, 89.0 / 120, accuracy: 1e-9, "89 points over the 5 days since the window began")
        XCTAssertEqual(try XCTUnwrap(result.recentPointsPerDay), 89.0 / 5, accuracy: 1e-9)
    }

    func testAReadingOnly19HoursOldIsIgnored() throws {
        let reset = now.addingTimeInterval(2 * day)
        let snapshot = UsageSnapshot(weeklyPercent: 89, weeklyResetsAt: reset)
        let young = sample(hoursAgo: 19, weekly: 70, weeklyReset: reset)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: [young], now: now, isStale: false)))
        XCTAssertEqual(result.basis, .windowSoFar)

        let twentyHours = sample(hoursAgo: 20, weekly: 69, weeklyReset: reset)
        let withTwenty = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: [twentyHours, young],
                                                                   now: now, isStale: false)))
        XCTAssertEqual(withTwenty.basis, .lastDay, "exactly 20 hours old counts")
        XCTAssertEqual(withTwenty.pointsPerHour, 1, accuracy: 1e-9)

        let twentyEight = sample(hoursAgo: 28, weekly: 61, weeklyReset: reset)
        XCTAssertEqual(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: [twentyEight], now: now, isStale: false))?.basis,
                       .lastDay, "exactly 28 hours old counts")
        let tooOld = sample(hoursAgo: 28 + 1.0 / 60, weekly: 61, weeklyReset: reset)
        XCTAssertEqual(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: [tooOld], now: now, isStale: false))?.basis,
                       .windowSoFar)
    }

    func testAReadingFromAPreviousWindowIsIgnored() throws {
        let reset = now.addingTimeInterval(7 * day - 10 * hour)
        let previousWindow = sample(hoursAgo: 24, weekly: 80, weeklyReset: reset.addingTimeInterval(-7 * day))
        let elevenMinutesOff = sample(hoursAgo: 23, weekly: 1, weeklyReset: reset.addingTimeInterval(11 * 60))
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 5, weeklyResetsAt: reset),
                                                               samples: [previousWindow, elevenMinutesOff], now: now, isStale: false)))
        XCTAssertEqual(result.basis, .windowSoFar)
        XCTAssertEqual(result.pointsPerHour, 0.5, accuracy: 1e-9, "5 points in the 10 hours since this window began")
    }

    func testNothingUsedOverTheLastDayMeansARateOfZero() throws {
        let reset = now.addingTimeInterval(2 * day)
        let snapshot = UsageSnapshot(weeklyPercent: 89, weeklyResetsAt: reset)
        for earlier in [89.0, 89.4] {
            let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: snapshot,
                                                                   samples: [sample(hoursAgo: 24, weekly: earlier, weeklyReset: reset)],
                                                                   now: now, isStale: false)))
            XCTAssertEqual(result.basis, .lastDay)
            XCTAssertEqual(result.pointsPerHour, 0, "a small drop counts as no usage, never negative")
            XCTAssertEqual(result.projectedAtReset, 89, accuracy: 1e-9)
            XCTAssertNil(result.runsOutAt)
            XCTAssertEqual(result.recentPointsPerDay, 0)
            XCTAssertEqual(ForecastStatus(.forecast(result)), .shouldLast)
        }
    }

    func testProjectedExactlyOneHundredDoesNotRunOut() throws {
        let reset = now.addingTimeInterval(day)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 76, weeklyResetsAt: reset),
                                                               samples: [sample(hoursAgo: 24, weekly: 52, weeklyReset: reset)],
                                                               now: now, isStale: false)))
        XCTAssertEqual(result.projectedAtReset, 100)
        XCTAssertNil(result.runsOutAt, "reaching 100% right at the reset is not running out before it")
        XCTAssertEqual(try XCTUnwrap(result.dailyBudget), 24, accuracy: 1e-9, "exactly one day left still gets a daily budget")
        XCTAssertEqual(ForecastStatus(.forecast(result)), .cuttingItClose)
    }

    func testWeeklyAndFableUseTheirOwnResetTimes() throws {
        let weeklyReset = now.addingTimeInterval(2 * day)
        let fableReset = now.addingTimeInterval(3 * day)
        let snapshot = UsageSnapshot(weeklyPercent: 89, weeklyResetsAt: weeklyReset, fableWeeklyPercent: 94, fableWeeklyResetsAt: fableReset)
        let samples = [
            sample(hoursAgo: 24, weekly: 65, weeklyReset: weeklyReset, fable: 70, fableReset: fableReset),
            sample(hoursAgo: 21, weekly: 68, weeklyReset: weeklyReset, fable: 90, fableReset: weeklyReset)
        ]
        let weekly = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: snapshot, samples: samples, now: now, isStale: false)))
        XCTAssertEqual(weekly.resetsAt, weeklyReset)
        XCTAssertEqual(weekly.pointsPerHour, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(weekly.runsOutAt).timeIntervalSince(now), 11 * hour, accuracy: 0.001)

        let fable = try XCTUnwrap(forecast(UsageForecast.make(.fableWeekly, snapshot: snapshot, samples: samples, now: now, isStale: false)))
        XCTAssertEqual(fable.kind, .fableWeekly)
        XCTAssertEqual(fable.resetsAt, fableReset)
        XCTAssertEqual(fable.basis, .lastDay)
        XCTAssertEqual(fable.pointsPerHour, 1, accuracy: 1e-9, "the 21-hour reading has a different Fable reset, so the 24-hour one is used")
        XCTAssertEqual(fable.projectedAtReset, 166, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fable.runsOutAt).timeIntervalSince(now), 6 * hour, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fable.dailyBudget), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fable.recentPointsPerDay), 24, accuracy: 1e-9)
    }

    func testNoDailyBudgetInTheLastDay() throws {
        let reset = now.addingTimeInterval(14 * hour)
        let result = try XCTUnwrap(forecast(UsageForecast.make(.weekly, snapshot: UsageSnapshot(weeklyPercent: 94, weeklyResetsAt: reset),
                                                               samples: [], now: now, isStale: false)))
        XCTAssertNil(result.dailyBudget)
        XCTAssertEqual(result.pointsLeft, 6, accuracy: 1e-9)
        XCTAssertNotNil(result.recentPointsPerDay)
    }

    func testBasisText() {
        XCTAssertEqual(ForecastBasis.lastDay.text, "Based on the last 24 hours")
        XCTAssertEqual(ForecastBasis.windowSoFar.text, "Based on this window so far")
    }

    // MARK: Status chips

    func testStatusForEachOutcome() {
        XCTAssertEqual(ForecastStatus(.limitReached(resetsAt: nil)), .limitReached)
        XCTAssertEqual(ForecastStatus(.noUsageYet(resetsAt: now)), .noUsageYet)
        XCTAssertEqual(ForecastStatus(.tooEarly(resetsAt: now)), .tooEarly)
        XCTAssertEqual(ForecastStatus(.unavailable), .unavailable)
        XCTAssertEqual(ForecastStatus(.forecast(make(projected: 89.9))), .shouldLast)
        XCTAssertEqual(ForecastStatus(.forecast(make(projected: 90))), .cuttingItClose)
        XCTAssertEqual(ForecastStatus(.forecast(make(projected: 120, runsOutAt: at(15, 9)))), .runsOut)

        XCTAssertEqual(ForecastStatus.runsOut.title, "Runs out before reset")
        XCTAssertEqual(ForecastStatus.shouldLast.title, "Should last")
        XCTAssertEqual(ForecastStatus.cuttingItClose.title, "Cutting it close")
        XCTAssertEqual(ForecastStatus.limitReached.title, "Limit reached")
        XCTAssertEqual(ForecastStatus.tooEarly.title, "Too early to tell")
        XCTAssertEqual(ForecastStatus.noUsageYet.title, "No usage yet")
        XCTAssertEqual(ForecastStatus.unavailable.title, "Not available")
    }

    /// A weekly forecast for the text tests; only the fields a test names matter.
    func make(kind: LimitKind = .weekly, percent: Double = 70, resetsAt: Date? = nil, basis: ForecastBasis = .lastDay,
              pointsPerHour: Double = 0.5, projected: Double, runsOutAt: Date? = nil, dailyBudget: Double? = 10,
              recentPointsPerDay: Double? = 12) -> LimitForecast {
        LimitForecast(kind: kind, percent: percent, resetsAt: resetsAt ?? at(17, 3), basis: basis, pointsPerHour: pointsPerHour,
                      projectedAtReset: projected, runsOutAt: runsOutAt, pointsLeft: max(0, 100 - percent),
                      dailyBudget: dailyBudget, recentPointsPerDay: recentPointsPerDay)
    }

    // MARK: Row text

    func testRunsOutOnAnotherDayWithADailyBudget() {
        let forecast = make(percent: 94, resetsAt: at(16, 20, 48), projected: 120, runsOutAt: at(15, 4),
                            dailyBudget: 6 / 2.2, recentPointsPerDay: 12)
        let row = ForecastRow.make(.forecast(forecast), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(row.status, .runsOut)
        XCTAssertEqual(plain(row.headline), "Reaches 100% around Tue 4:00 AM, 1d 16h before it resets")
        XCTAssertEqual(row.detail, "Budget: about 3 pts a day for the next 2.2 days · lately about 12 pts a day")
        XCTAssertEqual(row.basis, "Based on the last 24 hours")
    }

    func testRunsOutTodayShowsJustTheTime() {
        let forecast = make(kind: .fiveHour, percent: 50, resetsAt: at(14, 19), basis: .windowSoFar, projected: 150,
                            runsOutAt: at(14, 18), dailyBudget: nil, recentPointsPerDay: nil)
        let row = ForecastRow.make(.forecast(forecast), kind: .fiveHour, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(plain(row.headline), "Reaches 100% around 6:00 PM, 1h before it resets")
        XCTAssertNil(row.detail, "the 5-hour limit has no budget line")
        XCTAssertEqual(row.basis, "Based on this window so far")
    }

    func testShouldLastSaysWhatWillBeUsedAtTheReset() {
        let forecast = make(percent: 60, resetsAt: at(17, 3), basis: .windowSoFar, projected: 77.6, dailyBudget: 40 / (59.0 / 24),
                            recentPointsPerDay: 8.4)
        let row = ForecastRow.make(.forecast(forecast), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(row.status, .shouldLast)
        XCTAssertEqual(plain(row.headline), "About 78% used when it resets Thu 3:00 AM")
        XCTAssertEqual(row.detail, "Budget: about 16 pts a day for the next 2.5 days · so far about 8 pts a day")

        let fiveHour = make(kind: .fiveHour, percent: 30, resetsAt: at(14, 19), basis: .windowSoFar, projected: 75,
                            dailyBudget: nil, recentPointsPerDay: nil)
        XCTAssertEqual(plain(ForecastRow.make(.forecast(fiveHour), kind: .fiveHour, now: now, calendar: calendar, locale: locale).headline),
                       "About 75% used when it resets at 7:00 PM")
    }

    func testBudgetInTheLastDayAndForSmallNumbers() {
        let lastDay = make(percent: 94.8, resetsAt: at(15, 6), projected: 99, dailyBudget: nil)
        XCTAssertEqual(ForecastRow.make(.forecast(lastDay), kind: .weekly, now: now, calendar: calendar, locale: locale).detail,
                       "6 pts left for the next 14h", "points left match the rounded-down percent on the cards")
        let lastHalfHour = make(percent: 99.5, resetsAt: at(14, 16, 30), projected: 99.9, dailyBudget: nil)
        XCTAssertEqual(ForecastRow.make(.forecast(lastHalfHour), kind: .weekly, now: now, calendar: calendar, locale: locale).detail,
                       "1 pt left for the next 30m")

        let quiet = make(percent: 99, resetsAt: at(16, 16), pointsPerHour: 0, projected: 99, dailyBudget: 0.5, recentPointsPerDay: 0)
        XCTAssertEqual(ForecastRow.make(.forecast(quiet), kind: .weekly, now: now, calendar: calendar, locale: locale).detail,
                       "Budget: less than 1 pt a day for the next 2.0 days · none used lately")
        let slow = make(percent: 80, resetsAt: at(16, 16), basis: .windowSoFar, projected: 81, dailyBudget: 1.2, recentPointsPerDay: 0.3)
        XCTAssertEqual(ForecastRow.make(.forecast(slow), kind: .weekly, now: now, calendar: calendar, locale: locale).detail,
                       "Budget: about 1 pt a day for the next 2.0 days · so far less than 1 pt a day")
    }

    func testOtherOutcomesExplainThemselves() {
        let reached = ForecastRow.make(.limitReached(resetsAt: at(17, 3)), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(reached.status, .limitReached)
        XCTAssertEqual(reached.headline, "All of this limit is used")
        XCTAssertEqual(plain(reached.detail), "Resets Thu 3:00 AM")
        XCTAssertNil(reached.basis)
        XCTAssertNil(ForecastRow.make(.limitReached(resetsAt: nil), kind: .weekly, now: now, calendar: calendar, locale: locale).detail)

        let early = ForecastRow.make(.tooEarly(resetsAt: at(14, 20, 55)), kind: .fiveHour, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(plain(early.headline), "A forecast starts around 4:10 PM")
        XCTAssertEqual(plain(early.detail), "Resets at 8:55 PM")

        let unused = ForecastRow.make(.noUsageYet(resetsAt: at(17, 3)), kind: .fableWeekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(unused.headline, "Nothing used yet in this window")
        XCTAssertEqual(plain(unused.detail), "Resets Thu 3:00 AM")

        let idleSession = ForecastRow.make(.noUsageYet(resetsAt: nil), kind: .fiveHour, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(idleSession.status, .noUsageYet)
        XCTAssertEqual(idleSession.headline, "Nothing used yet · a session starts with your next message")
        XCTAssertNil(idleSession.detail, "there is no reset time to show")
        let idleWeek = ForecastRow.make(.noUsageYet(resetsAt: nil), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(idleWeek.headline, "Nothing used yet in this window")
        XCTAssertNil(idleWeek.detail)

        let unavailable = ForecastRow.make(.unavailable, kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertEqual(unavailable.headline, "Needs a current reading with a reset time")
        XCTAssertNil(unavailable.detail)
        XCTAssertNil(unavailable.basis)
    }

    func testATimeAboutAWeekAwayAlsoShowsTheDate() {
        // Now is Monday 4:00 PM, so "Mon 3:00 AM" on its own would look like this morning.
        let nextWeek = make(percent: 5, resetsAt: at(21, 3), basis: .windowSoFar, projected: 45)
        XCTAssertEqual(plain(ForecastRow.make(.forecast(nextWeek), kind: .weekly, now: now, calendar: calendar, locale: locale).headline),
                       "About 45% used when it resets Mon, Sep 21 at 3:00 AM")
        let runsOut = make(percent: 5, resetsAt: at(21, 3), projected: 120, runsOutAt: at(21, 1))
        XCTAssertEqual(plain(ForecastRow.make(.forecast(runsOut), kind: .weekly, now: now, calendar: calendar, locale: locale).headline),
                       "Reaches 100% around Mon, Sep 21 at 1:00 AM, 2h before it resets")
        let reached = ForecastRow.make(.limitReached(resetsAt: at(20, 3)), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(plain(reached.detail), "Resets Sun, Sep 20 at 3:00 AM", "six days ahead also shows the date")
        let sooner = ForecastRow.make(.limitReached(resetsAt: at(19, 23)), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(plain(sooner.detail), "Resets Sat 11:00 PM", "within five days the weekday is enough")
    }

    func testAccessibilityLabelReadsAsOneSentence() {
        let forecast = make(percent: 94, resetsAt: at(16, 20, 48), projected: 120, runsOutAt: at(15, 4),
                            dailyBudget: 6 / 2.2, recentPointsPerDay: 12)
        let row = ForecastRow.make(.forecast(forecast), kind: .weekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(plain(row.accessibilityLabel),
                       "Weekly · all models, runs out before reset. Reaches 100% around Tue 4:00 AM, 1d 16h before it resets, "
                       + "budget: about 3 pts a day for the next 2.2 days, lately about 12 pts a day, based on the last 24 hours.")
        let unavailable = ForecastRow.make(.unavailable, kind: .fableWeekly, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(unavailable.accessibilityLabel, "Weekly · Fable, not available. Needs a current reading with a reset time.")
    }

    // MARK: Chart projection

    func testProjectionEndsWhenItReachesOneHundredOrAtTheReset() {
        let week = WeekSeries(start: at(17, 3).addingTimeInterval(-7 * day), end: at(17, 3), points: [])
        let runsOut = make(percent: 70, resetsAt: at(17, 3), projected: 120, runsOutAt: at(15, 16))
        XCTAssertEqual(runsOut.projection(now: now, within: week),
                       [SeriesPoint(at: now, value: 70), SeriesPoint(at: at(15, 16), value: 100)])
        let lasts = make(percent: 60, resetsAt: at(17, 3), projected: 77.6)
        XCTAssertEqual(lasts.projection(now: now, within: week),
                       [SeriesPoint(at: now, value: 60), SeriesPoint(at: at(17, 3), value: 77.6)])
        let wobbly = make(percent: 60, resetsAt: at(17, 3, 4), projected: 80)
        let clipped = wobbly.projection(now: now, within: week)
        XCTAssertEqual(clipped.last?.at, week.end, "a reset a few minutes after the chart's end is clipped to the chart")
        XCTAssertEqual(clipped.last?.value ?? 0, 60 + 20 * (59.0 * 60) / (59.0 * 60 + 4), accuracy: 1e-6)
    }

    func testNoProjectionForAnotherWindowOrAfterTheChartEnds() {
        let week = WeekSeries(start: at(17, 3).addingTimeInterval(-7 * day), end: at(17, 3), points: [])
        let otherWindow = make(percent: 60, resetsAt: at(18, 3), projected: 80)
        XCTAssertEqual(otherWindow.projection(now: now, within: week), [], "Fable with its own reset time isn't drawn on this week's chart")
        let ended = WeekSeries(start: at(14, 16).addingTimeInterval(-7 * day), end: at(14, 16), points: [])
        XCTAssertEqual(make(percent: 60, resetsAt: at(14, 16), projected: 80).projection(now: now, within: ended), [])
    }
}
