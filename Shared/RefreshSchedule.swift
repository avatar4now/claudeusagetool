import Foundation

/// What the app hands to the widget: the chosen refresh interval and the latest good numbers.
struct SharedUsageState: Codable, Equatable, Sendable {
    var refreshSeconds: Int
    var snapshot: UsageSnapshot?
    var fetchedAt: Date?

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> SharedUsageState { try JSONDecoder().decode(Self.self, from: data) }
}

/// How often usage refreshes, and when the widget may reuse numbers the app already fetched.
enum RefreshSchedule {
    /// One minute is the fastest choice, to stay well clear of the usage endpoint's rate limit.
    static let choices = [60, 120, 300, 900]
    static let defaultSeconds = 120

    /// Extra time allowed for the app's next refresh to land before the widget fetches for itself.
    static let grace: TimeInterval = 60

    /// Snaps any stored value to the nearest allowed choice.
    static func sanitized(_ seconds: Int?) -> Int {
        guard let seconds else { return defaultSeconds }
        return choices.min { abs($0 - seconds) < abs($1 - seconds) } ?? defaultSeconds
    }

    static func label(for seconds: Int) -> String {
        "\(sanitized(seconds) / 60) min"
    }

    /// The app's latest numbers, if they are recent enough for the widget to show instead of fetching.
    static func freshSnapshot(in state: SharedUsageState?, now: Date = Date()) -> UsageSnapshot? {
        guard let state, let snapshot = state.snapshot, let fetchedAt = state.fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= -grace, age <= TimeInterval(sanitized(state.refreshSeconds)) + grace else { return nil }
        return snapshot
    }
}
