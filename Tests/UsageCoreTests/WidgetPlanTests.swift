import XCTest
@testable import UsageCore

final class WidgetPlanTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_416_000)
    let snapshot = UsageSnapshot(fiveHourPercent: 42, weeklyPercent: 7)

    func state(fetchedAgo: TimeInterval = 30, generation: String? = "gen", heartbeatIn: TimeInterval? = nil,
               cooldownFor: TimeInterval? = nil, appError: String? = nil) -> SharedUsageState {
        SharedUsageState(refreshSeconds: 120, snapshot: snapshot, fetchedAt: now.addingTimeInterval(-fetchedAgo),
                         cooldown: cooldownFor.map { Cooldown(until: now.addingTimeInterval($0), fromServer: true, needsReview: false) },
                         credentialGeneration: generation,
                         appHeartbeatUntil: heartbeatIn.map { now.addingTimeInterval($0) },
                         appErrorMessage: appError)
    }

    func testFreshNumbersFromTheAppAreShownWithoutFetching() {
        XCTAssertEqual(WidgetPlan.decide(state: state(), generation: "gen", widgetCooldown: nil, now: now),
                       .showFresh(CachedReading(snapshot: snapshot, fetchedAt: now.addingTimeInterval(-30))))
    }

    func testWhileTheAppIsRunningTheWidgetWaitsForItInsteadOfFetching() {
        let plan = WidgetPlan.decide(state: state(fetchedAgo: 900, heartbeatIn: 120, appError: UsageError.network.message),
                                     generation: "gen", widgetCooldown: nil, now: now)
        XCTAssertEqual(plan, .waitForApp(cached: CachedReading(snapshot: snapshot, fetchedAt: now.addingTimeInterval(-900)),
                                         notice: UsageError.network.message, until: now.addingTimeInterval(120)))
    }

    func testAnExpiredHeartbeatMeansTheAppIsGoneAndTheWidgetFetches() {
        let plan = WidgetPlan.decide(state: state(fetchedAgo: 900, heartbeatIn: -5), generation: "gen", widgetCooldown: nil, now: now)
        XCTAssertEqual(plan, .fetch(cached: CachedReading(snapshot: snapshot, fetchedAt: now.addingTimeInterval(-900))))
    }

    func testCooldownsFromEitherSideBlockTheWidgetsOwnFetch() {
        let shared = WidgetPlan.decide(state: state(fetchedAgo: 900, cooldownFor: 300), generation: "gen", widgetCooldown: nil, now: now)
        XCTAssertEqual(shared, .waitForCooldown(cached: CachedReading(snapshot: snapshot, fetchedAt: now.addingTimeInterval(-900)),
                                                until: now.addingTimeInterval(300)))
        let own = Cooldown(until: now.addingTimeInterval(600), fromServer: false, needsReview: false)
        let local = WidgetPlan.decide(state: state(fetchedAgo: 900, cooldownFor: 300), generation: "gen", widgetCooldown: own, now: now)
        XCTAssertEqual(local, .waitForCooldown(cached: CachedReading(snapshot: snapshot, fetchedAt: now.addingTimeInterval(-900)),
                                               until: now.addingTimeInterval(600)), "the later of the two cooldowns wins")
    }

    func testNumbersFromOtherCredentialsAreNeverShownOrWaitedFor() {
        let plan = WidgetPlan.decide(state: state(generation: "old", heartbeatIn: 120), generation: "new", widgetCooldown: nil, now: now)
        XCTAssertEqual(plan, .fetch(cached: nil))
        XCTAssertEqual(WidgetPlan.decide(state: nil, generation: "gen", widgetCooldown: nil, now: now), .fetch(cached: nil))
    }
}
