import Foundation

/// Reads an HTTP Retry-After header, which is either a number of seconds or an HTTP date.
enum RetryAfter {
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Seconds to wait from `now`, or nil when the header is missing or unreadable. A date in the past means 0.
    static func parse(_ value: String?, now: Date) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber), let seconds = TimeInterval(text) { return seconds }
        guard let date = httpDate.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// A period when no automatic request may be sent, after the usage service said "too many requests".
struct Cooldown: Codable, Equatable, Sendable {
    let until: Date
    /// True when the time came from the server's Retry-After header rather than the app's own backoff.
    let fromServer: Bool
    /// True when the server asked for an unusually long wait. It is honored, but a manual retry is allowed.
    let needsReview: Bool

    func blocks(at date: Date, manual: Bool) -> Bool {
        guard date < until else { return false }
        return !(manual && needsReview)
    }
}

/// How long to wait after a rate limit.
///
/// A server deadline is honored exactly and never shortened. Without one, waits double from the refresh
/// interval up to 30 minutes, plus up to 10% extra so the app and widget don't retry at the same moment.
enum BackoffPolicy {
    static let maximumLocalDelay: TimeInterval = 30 * 60
    static let implausibleServerDelay: TimeInterval = 6 * 3600

    /// - Parameters:
    ///   - count: consecutive rate limits so far, starting at 1.
    ///   - jitter: a random number from 0 to 1, passed in so tests are repeatable.
    static func cooldown(afterRateLimit count: Int, retryAfter: TimeInterval?, refreshSeconds: Int,
                         now: Date, jitter: Double) -> Cooldown {
        if let retryAfter, retryAfter >= 0 {
            return Cooldown(until: now.addingTimeInterval(retryAfter), fromServer: true,
                            needsReview: retryAfter > implausibleServerDelay)
        }
        let doublings = Double(min(max(count, 1), 16))
        let base = TimeInterval(refreshSeconds) * pow(2, doublings)
        let delay = min(base * (1 + 0.1 * min(max(jitter, 0), 1)), maximumLocalDelay)
        return Cooldown(until: now.addingTimeInterval(delay), fromServer: false, needsReview: false)
    }
}
