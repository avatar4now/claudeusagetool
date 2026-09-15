import Foundation

/// The usage limits the app shows, in display order.
enum LimitKind: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
    case fableWeekly

    /// How long one window lasts. Model-specific weekly limits are assumed to last a week as well.
    var windowLength: TimeInterval {
        self == .fiveHour ? 5 * 3600 : 7 * 86_400
    }

    /// One or two characters for the menu bar, so every number names its limit.
    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "W"
        case .fableWeekly: return "F"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour session"
        case .weekly: return "Weekly · all models"
        case .fableWeekly: return "Weekly · Fable"
        }
    }
}

extension UsageSnapshot {
    func percent(for limit: LimitKind) -> Double? {
        switch limit {
        case .fiveHour: return fiveHourPercent
        case .weekly: return weeklyPercent
        case .fableWeekly: return fableWeeklyPercent
        }
    }

    func resetsAt(for limit: LimitKind) -> Date? {
        switch limit {
        case .fiveHour: return fiveHourResetsAt
        case .weekly: return weeklyResetsAt
        case .fableWeekly: return fableWeeklyResetsAt
        }
    }
}

// MARK: - Pace

enum PaceStatus: Equatable, Sendable {
    case onPace
    case ahead(points: Int)
    case under(points: Int)

    var label: String {
        switch self {
        case .onPace: return "On pace"
        case .ahead(let points): return "\(points) pts ahead of pace"
        case .under(let points): return "\(points) pts under pace"
        }
    }
}

struct PaceReading: Equatable, Sendable {
    /// How much of the window has passed, from 0 to 1. The bar's tick sits here.
    let elapsedFraction: Double
    let status: PaceStatus
}

/// Compares usage with how much of the window has passed. It describes, it doesn't predict:
/// "12 pts ahead" means more is used than an even spread would have used by now.
enum Pace {
    /// Hidden for the first 3% of a window, when a few messages would swing it wildly.
    static let minimumElapsedFraction = 0.03
    /// Within this many percentage points counts as on pace.
    static let tolerance = 5.0

    static func reading(percent: Double?, resetsAt: Date?, window: TimeInterval, now: Date) -> PaceReading? {
        guard let percent, let resetsAt, window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window + 60 else { return nil }
        let elapsed = min(max(1 - remaining / window, 0), 1)
        guard elapsed >= minimumElapsedFraction else { return nil }
        let delta = percent - elapsed * 100
        let status: PaceStatus
        if abs(delta) < tolerance {
            status = .onPace
        } else if delta > 0 {
            status = .ahead(points: Int(delta.rounded()))
        } else {
            status = .under(points: Int((-delta).rounded()))
        }
        return PaceReading(elapsedFraction: elapsed, status: status)
    }
}

// MARK: - Menu bar headline

enum MenuBarMetric: String, CaseIterable, Sendable {
    case auto
    case fiveHour
    case weekly
    case fableWeekly

    var title: String {
        switch self {
        case .auto: return "Closest to full"
        case .fiveHour: return "5-hour session"
        case .weekly: return "Weekly · all models"
        case .fableWeekly: return "Weekly · Fable"
        }
    }

    var limit: LimitKind? {
        switch self {
        case .auto: return nil
        case .fiveHour: return .fiveHour
        case .weekly: return .weekly
        case .fableWeekly: return .fableWeekly
        }
    }
}

/// What the menu bar shows.
struct Headline: Equatable, Sendable {
    let limit: LimitKind?
    let text: String
    /// True when a limit the menu bar isn't showing is at or above 90%.
    let hiddenLimitWarning: Bool

    static let hiddenWarningThreshold = 90.0

    /// "Closest to full" picks the highest reported percentage; ties go to the earlier limit in display order.
    /// That is not a forecast of which limit you'll hit first.
    static func make(for snapshot: UsageSnapshot?, metric: MenuBarMetric) -> Headline {
        guard let snapshot else { return Headline(limit: nil, text: "—", hiddenLimitWarning: false) }
        let reported = LimitKind.allCases.compactMap { kind in snapshot.percent(for: kind).map { (kind, $0) } }
        let shown: LimitKind?
        if let fixed = metric.limit {
            shown = fixed
        } else {
            shown = reported.reduce(nil as (LimitKind, Double)?) { best, next in
                guard let best else { return next }
                return next.1 > best.1 ? next : best
            }?.0
        }
        guard let shown else { return Headline(limit: nil, text: "—", hiddenLimitWarning: false) }
        let text = "\(shown.shortLabel) \(UsageFormatting.percentText(snapshot.percent(for: shown)))"
        let warning = reported.contains { $0.0 != shown && $0.1 >= hiddenWarningThreshold }
        return Headline(limit: shown, text: text, hiddenLimitWarning: warning)
    }
}

// MARK: - Freshness

enum Freshness {
    /// A reading is stale after three refresh intervals pass without a successful fetch.
    static let missedIntervals = 3

    static func staleAt(fetchedAt: Date, refreshSeconds: Int) -> Date {
        fetchedAt.addingTimeInterval(TimeInterval(refreshSeconds * missedIntervals))
    }

    static func isStale(fetchedAt: Date?, refreshSeconds: Int, now: Date) -> Bool {
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        return age < -60 || now > staleAt(fetchedAt: fetchedAt, refreshSeconds: refreshSeconds)
    }
}

// MARK: - One limit, ready to draw

/// Everything a bar needs, shared by the widget and the menu bar panel so both tell the same story.
struct LimitDisplay: Equatable, Sendable {
    let kind: LimitKind
    /// Whole percent rounded down, or nil when the service didn't report it.
    let percent: Int?
    let resetsAt: Date?
    let awaitingReset: Bool
    /// Nil when pace can't be trusted: stale data, a passed reset, or too early in the window.
    let pace: PaceReading?
    let resetText: String?

    static func make(_ kind: LimitKind, snapshot: UsageSnapshot?, now: Date, isStale: Bool) -> LimitDisplay {
        let percent = snapshot?.percent(for: kind)
        let resetsAt = snapshot?.resetsAt(for: kind)
        let awaiting = ResetBoundary.isAwaitingReset(resetsAt, now: now)
        let pace = (isStale || awaiting) ? nil
            : Pace.reading(percent: percent, resetsAt: resetsAt, window: kind.windowLength, now: now)
        let resetText: String?
        if awaiting {
            resetText = "Awaiting reset"
        } else if let remaining = UsageFormatting.resetText(until: resetsAt, now: now) {
            resetText = "Resets in \(remaining)"
        } else {
            resetText = nil
        }
        return LimitDisplay(kind: kind, percent: UsageFormatting.wholePercent(percent), resetsAt: resetsAt,
                            awaitingReset: awaiting, pace: pace, resetText: resetText)
    }
}

// MARK: - Reset boundaries

enum ResetBoundary {
    /// How long after a reset to ask for fresh numbers, so the service has had time to roll over.
    static let confirmationDelay: TimeInterval = 30

    /// True once the expected reset time has passed but no new reading has confirmed it.
    /// Passing time alone never turns a limit into 0%.
    static func isAwaitingReset(_ resetsAt: Date?, now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// Distinct reset times between now and the next reload, where the widget should redraw.
    static func entryDates(for snapshot: UsageSnapshot?, now: Date, before end: Date) -> [Date] {
        guard let snapshot else { return [] }
        let dates = LimitKind.allCases.compactMap { snapshot.resetsAt(for: $0) }.filter { $0 > now && $0 < end }
        return Array(Set(dates)).sorted()
    }
}
