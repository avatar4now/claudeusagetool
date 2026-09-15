import XCTest
@testable import UsageCore

final class BackoffTests: XCTestCase {
    /// Monday 2026-09-14 20:00:00 UTC.
    let now = Date(timeIntervalSince1970: 1_789_416_000)

    func testRetryAfterAcceptsSecondsAndHTTPDates() {
        XCTAssertEqual(RetryAfter.parse("120", now: now), 120)
        XCTAssertEqual(RetryAfter.parse(" 45 ", now: now), 45)
        XCTAssertEqual(RetryAfter.parse("0", now: now), 0)
        XCTAssertEqual(RetryAfter.parse("Mon, 14 Sep 2026 20:05:00 GMT", now: now), 300)
        XCTAssertEqual(RetryAfter.parse("Mon, 14 Sep 2026 19:00:00 GMT", now: now), 0, "a past date means retry now")
        XCTAssertNil(RetryAfter.parse("-5", now: now))
        XCTAssertNil(RetryAfter.parse("soon", now: now))
        XCTAssertNil(RetryAfter.parse(nil, now: now))
    }

    func testServerDeadlineIsHonoredExactlyWithoutJitter() {
        let cooldown = BackoffPolicy.cooldown(afterRateLimit: 1, retryAfter: 90, refreshSeconds: 120, now: now, jitter: 1)
        XCTAssertEqual(cooldown.until, now.addingTimeInterval(90))
        XCTAssertTrue(cooldown.fromServer)
        XCTAssertFalse(cooldown.needsReview)
    }

    func testLocalBackoffDoublesWithOnlyPositiveJitterAndACap() {
        func until(_ count: Int, jitter: Double) -> TimeInterval {
            BackoffPolicy.cooldown(afterRateLimit: count, retryAfter: nil, refreshSeconds: 120, now: now, jitter: jitter)
                .until.timeIntervalSince(now)
        }
        XCTAssertEqual(until(1, jitter: 0), 240)
        XCTAssertEqual(until(2, jitter: 0), 480)
        XCTAssertEqual(until(1, jitter: 1), 264, accuracy: 0.001)
        XCTAssertEqual(until(10, jitter: 1), 1800, "locally invented waits are capped at 30 minutes")
        XCTAssertFalse(BackoffPolicy.cooldown(afterRateLimit: 1, retryAfter: nil, refreshSeconds: 120, now: now, jitter: 0).fromServer)
    }

    func testImplausibleServerDelayIsHonoredButFlaggedForReview() {
        let cooldown = BackoffPolicy.cooldown(afterRateLimit: 1, retryAfter: 8 * 3600, refreshSeconds: 120, now: now, jitter: 0)
        XCTAssertEqual(cooldown.until, now.addingTimeInterval(8 * 3600))
        XCTAssertTrue(cooldown.needsReview)
    }

    func testCooldownBlocksEveryRefreshUntilItEnds() {
        let server = Cooldown(until: now.addingTimeInterval(60), fromServer: true, needsReview: false)
        XCTAssertTrue(server.blocks(at: now, manual: false))
        XCTAssertTrue(server.blocks(at: now, manual: true), "a manual tap never overrules a server deadline")
        XCTAssertFalse(server.blocks(at: now.addingTimeInterval(60), manual: false))

        let review = Cooldown(until: now.addingTimeInterval(8 * 3600), fromServer: true, needsReview: true)
        XCTAssertTrue(review.blocks(at: now, manual: false))
        XCTAssertFalse(review.blocks(at: now, manual: true), "an implausible wait can be retried by hand")
    }
}
