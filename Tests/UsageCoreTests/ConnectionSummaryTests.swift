import XCTest
@testable import UsageCore

final class ConnectionSummaryTests: XCTestCase {
    let snapshot = UsageSnapshot(fiveHourPercent: 42.9, weeklyPercent: 7, fableWeeklyPercent: 12)

    func testMetricsLineListsKnownValuesOnly() {
        XCTAssertEqual(ConnectionSummary.metricsLine(snapshot), "5-hour 42% · weekly 7% · Fable 12%")
        XCTAssertEqual(ConnectionSummary.metricsLine(UsageSnapshot(weeklyPercent: 3)), "weekly 3%")
    }

    func testSuccessWithTheTokenIsShort() {
        let line = ConnectionSummary.message(for: .success(UsageReport(snapshot: snapshot, route: .oauthToken)))
        XCTAssertTrue(line.isSuccess)
        XCTAssertEqual(line.text, "Connected. 5-hour 42% · weekly 7% · Fable 12%.")
    }

    func testFallbackSuccessSaysTheTokenCanBeCleared() {
        let report = UsageReport(snapshot: snapshot, route: .sessionKey, tokenFailure: .tokenCannotReadUsage)
        let line = ConnectionSummary.message(for: .success(report))
        XCTAssertTrue(line.isSuccess)
        XCTAssertTrue(line.text.hasPrefix("Connected with your session key. 5-hour 42%"), line.text)
        XCTAssertTrue(line.text.contains("can't read usage"), line.text)
        XCTAssertTrue(line.text.contains("clear"), line.text)
    }

    func testFailureShowsTheErrorMessage() {
        let line = ConnectionSummary.message(for: .failure(.sessionKeyRejected))
        XCTAssertFalse(line.isSuccess)
        XCTAssertEqual(line.text, UsageError.sessionKeyRejected.message)
    }
}
