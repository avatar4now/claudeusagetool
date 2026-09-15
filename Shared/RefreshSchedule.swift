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
    /// While this is in the future the app is running and will publish again, so the widget shouldn't fetch.
    var appHeartbeatUntil: Date? = nil
    /// The app's latest problem, as fixed text, so the widget can show the same message without fetching.
    var appErrorMessage: String? = nil
    /// The kind of problem behind appErrorMessage, so the widget can show the matching icon and title.
    var appProblemCause: ProblemCause? = nil
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
        appHeartbeatUntil = try container.decodeIfPresent(Date.self, forKey: .appHeartbeatUntil)
        appErrorMessage = try container.decodeIfPresent(String.self, forKey: .appErrorMessage)
        // A cause this build doesn't know (from a newer app) is dropped rather than failing the whole state.
        let causeText = (try? container.decodeIfPresent(String.self, forKey: .appProblemCause)) ?? nil
        appProblemCause = causeText.flatMap(ProblemCause.init(rawValue:))
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
    static func cachedSnapshot(in state: SharedUsageState?, generation: String?) -> CachedReading? {
        guard matches(state, generation: generation), let snapshot = state?.snapshot, let fetchedAt = state?.fetchedAt else {
            return nil
        }
        return CachedReading(snapshot: snapshot, fetchedAt: fetchedAt)
    }

    /// When the next automatic refresh should happen: one interval from now, or shortly after an upcoming reset
    /// if that comes first. Never before a cooldown ends.
    static func nextRefresh(after now: Date, refreshSeconds: Int, snapshot: UsageSnapshot?, cooldown: Cooldown?) -> Date {
        let next = earliestResetConfirmation(in: snapshot, after: now,
                                             before: now.addingTimeInterval(TimeInterval(sanitized(refreshSeconds))))
        if let cooldown, cooldown.until > next { return cooldown.until }
        return next
    }

    /// The first refresh after launch: wait until the cached reading is one interval old (or an upcoming reset passes),
    /// and past any cooldown. A reading dated in the future is ignored.
    static func firstRefresh(now: Date, refreshSeconds: Int, lastSuccessAt: Date?, snapshot: UsageSnapshot?,
                             cooldown: Cooldown?) -> Date {
        var first = now
        if let lastSuccessAt, lastSuccessAt.timeIntervalSince(now) <= grace {
            let due = lastSuccessAt.addingTimeInterval(TimeInterval(sanitized(refreshSeconds)))
            if due > now { first = earliestResetConfirmation(in: snapshot, after: now, before: due) }
        }
        if let cooldown, cooldown.until > first { first = cooldown.until }
        return first
    }

    /// `before`, or 30 s after the first reset between `after` and `before` if one comes sooner.
    private static func earliestResetConfirmation(in snapshot: UsageSnapshot?, after now: Date, before limit: Date) -> Date {
        var next = limit
        guard let snapshot else { return next }
        for kind in LimitKind.allCases {
            guard let reset = snapshot.resetsAt(for: kind) else { continue }
            let confirm = reset.addingTimeInterval(ResetBoundary.confirmationDelay)
            if confirm > now, confirm < next { next = confirm }
        }
        return next
    }
}

/// A saved reading and when it was fetched.
struct CachedReading: Equatable, Sendable {
    let snapshot: UsageSnapshot
    let fetchedAt: Date
}

/// What the widget does on each reload. The app owns fetching while it runs; the widget fetches only when the app
/// is gone and nothing says to wait.
enum WidgetPlan: Equatable, Sendable {
    /// The app's numbers are recent: show them.
    case showFresh(CachedReading)
    /// The app is running and will publish soon: show what it last shared, with its latest problem and that problem's
    /// cause, and don't fetch.
    case waitForApp(cached: CachedReading?, notice: String?, cause: ProblemCause?, until: Date)
    /// A rate limit is in force: show the last numbers and wait.
    case waitForCooldown(cached: CachedReading?, until: Date)
    /// Nothing else applies: fetch, keeping the last numbers in case the fetch fails for an unclear reason.
    case fetch(cached: CachedReading?)

    static func decide(state: SharedUsageState?, generation: String?, widgetCooldown: Cooldown?, now: Date) -> WidgetPlan {
        let cached = RefreshSchedule.cachedSnapshot(in: state, generation: generation)
        if let fresh = RefreshSchedule.freshSnapshot(in: state, generation: generation, now: now), let cached {
            return .showFresh(CachedReading(snapshot: fresh, fetchedAt: cached.fetchedAt))
        }
        if RefreshSchedule.matches(state, generation: generation), let heartbeat = state?.appHeartbeatUntil, heartbeat > now {
            let notice = state?.appErrorMessage
            return .waitForApp(cached: cached, notice: notice, cause: notice == nil ? nil : state?.appProblemCause, until: heartbeat)
        }
        let blocking = [RefreshSchedule.matches(state, generation: generation) ? state?.cooldown : nil, widgetCooldown]
            .compactMap { $0 }
            .filter { $0.blocks(at: now, manual: false) }
            .max { $0.until < $1.until }
        if let blocking {
            return .waitForCooldown(cached: cached, until: blocking.until)
        }
        return .fetch(cached: cached)
    }
}
