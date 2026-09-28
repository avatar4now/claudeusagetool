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

    func state(fetchedAgo seconds: TimeInterval?, generation: String? = "gen") -> SharedUsageState {
        SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: seconds.map { now.addingTimeInterval(-$0) },
                         credentialGeneration: generation)
    }

    func testSharedSnapshotIsUsedWhileFreshAndForTheSameCredentials() {
        XCTAssertEqual(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: 170), generation: "gen", now: now), snapshot)
    }

    func testSharedSnapshotIsIgnoredOnceStaleMissingFromTheFutureOrFromOtherCredentials() {
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: nil, generation: "gen", now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: 181), generation: "gen", now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: nil), generation: "gen", now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: -120), generation: "gen", now: now),
                     "a clock change must not freeze old numbers on screen")
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: 10), generation: "other", now: now))
        XCTAssertNil(RefreshSchedule.freshSnapshot(in: state(fetchedAgo: 10, generation: nil), generation: nil, now: now),
                     "an unknown generation gets no cached numbers")
    }

    func testCachedSnapshotIgnoresAgeButStillRequiresMatchingCredentials() {
        let cached = RefreshSchedule.cachedSnapshot(in: state(fetchedAgo: 86_400), generation: "gen")
        XCTAssertEqual(cached?.snapshot, snapshot)
        XCTAssertEqual(cached?.fetchedAt, now.addingTimeInterval(-86_400))
        XCTAssertNil(RefreshSchedule.cachedSnapshot(in: state(fetchedAgo: 10), generation: "other"))
        XCTAssertNil(RefreshSchedule.cachedSnapshot(in: state(fetchedAgo: nil), generation: "gen"))
    }

    func testSharedStateRoundTripsThroughJSON() throws {
        let state = SharedUsageState(refreshSeconds: 60,
                                     snapshot: UsageSnapshot(fiveHourPercent: 42.5, fableWeeklyPercent: 3, fableWeeklyResetsAt: now),
                                     fetchedAt: now,
                                     cooldown: Cooldown(until: now.addingTimeInterval(90), fromServer: true, needsReview: false),
                                     credentialGeneration: "gen",
                                     appHeartbeatUntil: now.addingTimeInterval(210),
                                     appErrorMessage: UsageError.network.message,
                                     appProblemCause: .offline)
        XCTAssertEqual(try SharedUsageState.decode(try state.encoded()), state)
        XCTAssertEqual(state.schemaVersion, SharedUsageState.currentSchemaVersion)
    }

    func testOlderSharedStateStillDecodesAndNewerIsRefused() throws {
        let older = Data(#"{"refreshSeconds":120,"fetchedAt":779999000}"#.utf8)
        let decoded = try SharedUsageState.decode(older)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.credentialGeneration)
        XCTAssertNil(decoded.cooldown)
        XCTAssertNil(decoded.appProblemCause)

        let newer = Data(#"{"refreshSeconds":120,"schemaVersion":99}"#.utf8)
        XCTAssertThrowsError(try SharedUsageState.decode(newer))
    }

    func testAProblemCauseFromANewerBuildDecodesAsNilWithoutLosingTheRest() throws {
        let known = Data(#"{"refreshSeconds":120,"schemaVersion":2,"appErrorMessage":"x","appProblemCause":"botCheck"}"#.utf8)
        XCTAssertEqual(try SharedUsageState.decode(known).appProblemCause, .botCheck)

        let unknown = Data(#"{"refreshSeconds":60,"schemaVersion":2,"appErrorMessage":"x","appProblemCause":"somethingNew"}"#.utf8)
        let decoded = try SharedUsageState.decode(unknown)
        XCTAssertNil(decoded.appProblemCause)
        XCTAssertEqual(decoded.refreshSeconds, 60)
        XCTAssertEqual(decoded.appErrorMessage, "x")

        let wrongType = Data(#"{"refreshSeconds":60,"appProblemCause":7}"#.utf8)
        XCTAssertNil(try SharedUsageState.decode(wrongType).appProblemCause)
    }

    func testAppearanceTravelsToTheWidget() throws {
        var appearance = Appearance()
        appearance.theme = .dusk
        appearance.numbers = .left
        let state = SharedUsageState(refreshSeconds: 120, snapshot: nil, fetchedAt: nil, appearance: appearance)
        XCTAssertEqual(try SharedUsageState.decode(state.encoded()).appearance, appearance)

        let old = Data(#"{"refreshSeconds":120,"schemaVersion":2}"#.utf8)
        XCTAssertNil(try SharedUsageState.decode(old).appearance, "state from an older app has no appearance")

        let broken = Data(#"{"refreshSeconds":120,"schemaVersion":2,"appearance":5,"appErrorMessage":"x"}"#.utf8)
        let decoded = try SharedUsageState.decode(broken)
        XCTAssertNil(decoded.appearance)
        XCTAssertEqual(decoded.appErrorMessage, "x", "a bad appearance never breaks the rest of the handoff")
    }
}
