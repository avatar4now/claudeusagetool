import XCTest
@testable import UsageCore

final class RefreshScheduleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_416_000)
    let snapshot = UsageSnapshot(fiveHourPercent: 42, weeklyPercent: 7)

    func testChoicesAndDefault() {
        XCTAssertEqual(RefreshSchedule.choices, [60, 120, 300, 900])
        XCTAssertEqual(RefreshSchedule.defaultSeconds, 120)
    }

    func testSanitizedSnapsAnyValueToTheNearestChoice() {
        XCTAssertEqual(RefreshSchedule.sanitized(nil), 120)
        XCTAssertEqual(RefreshSchedule.sanitized(300), 300)
        XCTAssertEqual(RefreshSchedule.sanitized(5), 60, "never faster than once a minute")
        XCTAssertEqual(RefreshSchedule.sanitized(200), 120)
        XCTAssertEqual(RefreshSchedule.sanitized(100_000), 900)
    }

    func testLabels() {
        XCTAssertEqual(RefreshSchedule.label(for: 60), "1 min")
        XCTAssertEqual(RefreshSchedule.label(for: 900), "15 min")
    }

    func testSharedSnapshotIsUsedWhileFresh() {
        let state = SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: now.addingTimeInterval(-170))
        XCTAssertEqual(RefreshSchedule.freshSnapshot(in: state, now: now), snapshot, "within one interval plus a minute of grace")
    }

    func testSharedSnapshotIsIgnoredOnceStaleMissingOrFromTheFuture() {
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: nil, now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(
            in: SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: now.addingTimeInterval(-181)), now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(
            in: SharedUsageState(refreshSeconds: 120, snapshot: nil, fetchedAt: now), now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(
            in: SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: nil), now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(
            in: SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: now.addingTimeInterval(120)), now: now),
            "a clock change must not freeze old numbers on screen")
    }

    func testSharedStateRoundTripsThroughJSON() throws {
        let state = SharedUsageState(refreshSeconds: 60, snapshot: UsageSnapshot(fiveHourPercent: 42.5, fableWeeklyPercent: 3,
                                     fableWeeklyResetsAt: now), fetchedAt: now)
        XCTAssertEqual(try SharedUsageState.decode(try state.encoded()), state)
    }
}
