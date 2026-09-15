import Foundation

/// What the app hands to the widget: the chosen refresh interval, the latest good numbers, any cooldown,
/// and which credentials those numbers came from.
struct SharedUsageState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var refreshSeconds: Int
    var snapshot: UsageSnapshot?
    var fetchedAt: Date?
    var cooldown: Cooldown? = nil
    var credentialGeneration: String? = nil
    var schemaVersion: Int = SharedUsageState.currentSchemaVersion

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Accepts older versions (missing fields stay empty) and refuses versions newer than this build understands.
    static func decode(_ data: Data) throws -> SharedUsageState {
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.schemaVersion <= currentSchemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported schema version \(state.schemaVersion)"))
        }
        return state
    }
}

extension SharedUsageState {
    // Declared in an extension so the memberwise initializer stays available.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try container.decode(Int.self, forKey: .refreshSeconds)
        snapshot = try container.decodeIfPresent(UsageSnapshot.self, forKey: .snapshot)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        cooldown = try container.decodeIfPresent(Cooldown.self, forKey: .cooldown)
        credentialGeneration = try container.decodeIfPresent(String.self, forKey: .credentialGeneration)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

/// How often usage refreshes, and when saved numbers may be reused.
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

    /// True only when both sides know the generation and it matches, so numbers never cross credentials.
    static func matches(_ state: SharedUsageState?, generation: String?) -> Bool {
        guard let generation, let stored = state?.credentialGeneration else { return false }
        return stored == generation
    }

    /// The app's latest numbers, if recent enough for the widget to show instead of fetching.
    static func freshSnapshot(in state: SharedUsageState?, generation: String?, now: Date = Date()) -> UsageSnapshot? {
        guard matches(state, generation: generation), let state, let snapshot = state.snapshot,
              let fetchedAt = state.fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= -grace, age <= TimeInterval(sanitized(state.refreshSeconds)) + grace else { return nil }
        return snapshot
    }

    /// The last good numbers for these credentials, however old. Callers must label their age.
    static func cachedSnapshot(in state: SharedUsageState?, generation: String?) -> (snapshot: UsageSnapshot, fetchedAt: Date)? {
        guard matches(state, generation: generation), let snapshot = state?.snapshot, let fetchedAt = state?.fetchedAt else {
            return nil
        }
        return (snapshot, fetchedAt)
    }

    /// When the next automatic refresh should happen: one interval from now, or shortly after an upcoming reset
    /// if that comes first. Never before a cooldown ends.
    static func nextRefresh(after now: Date, refreshSeconds: Int, snapshot: UsageSnapshot?, cooldown: Cooldown?) -> Date {
        var next = now.addingTimeInterval(TimeInterval(sanitized(refreshSeconds)))
        if let snapshot {
            for kind in LimitKind.allCases {
                guard let reset = snapshot.resetsAt(for: kind) else { continue }
                let confirm = reset.addingTimeInterval(ResetBoundary.confirmationDelay)
                if confirm > now, confirm < next { next = confirm }
            }
        }
        if let cooldown, cooldown.until > next { next = cooldown.until }
        return next
    }

    /// The first refresh after launch: wait until the cached reading is one interval old, and past any cooldown.
    static func firstRefresh(now: Date, refreshSeconds: Int, lastSuccessAt: Date?, cooldown: Cooldown?) -> Date {
        var first = now
        if let lastSuccessAt {
            let due = lastSuccessAt.addingTimeInterval(TimeInterval(sanitized(refreshSeconds)))
            if due > now { first = due }
        }
        if let cooldown, cooldown.until > first { first = cooldown.until }
        return first
    }
}
