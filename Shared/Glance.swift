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
    /// Limits the menu bar isn't showing that are at or above 90% and haven't passed their reset, in display order.
    let hiddenWarningLimits: [LimitKind]
    /// True when the shown limit's reset time has passed but no new reading has confirmed it.
    let awaitingReset: Bool
    /// The shown limit's percentage and reset time, for menu bar styles that show more than the headline text.
    var percent: Double? = nil
    var resetsAt: Date? = nil
    /// Hidden limits at or above this percentage are flagged.
    var warningAt: Double = Headline.hiddenWarningThreshold

    static let hiddenWarningThreshold = 90.0
    /// The warning sign drawn as a plain text glyph (not a color emoji), so it matches the menu bar's text.
    static let warningSign = "\u{26A0}\u{FE0E}"

    /// True when a limit the menu bar isn't showing is at or above 90%.
    var hiddenLimitWarning: Bool { !hiddenWarningLimits.isEmpty }

    /// The menu bar's text in the standard style, such as "5h 22% ⚠︎F".
    var menuBarText: String { menuBarText(.standard) }

    /// The menu bar's text in the chosen style, such as "5h 22% ⚠︎F", "22%", "5h 22% · 2h 10m", or "78% left".
    /// The menu bar draws only one symbol, so a warning about a hidden limit is part of the text, and it stays even
    /// when the style asks for no text.
    func menuBarText(_ appearance: Appearance, now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        guard let limit else { return text }
        let number = appearance.percentText(UsageFormatting.wholePercent(percent))
        var base: String
        switch appearance.menuBarText {
        case .labelAndPercent:
            base = "\(limit.shortLabel) \(number)"
        case .percentOnly:
            base = number
        case .percentAndReset:
            base = "\(limit.shortLabel) \(number)"
            if !awaitingReset, let resetsAt, resetsAt > now {
                let piece = appearance.resetStyle == .clockTime
                    ? UsageFormatting.moment(resetsAt, now: now, calendar: calendar, locale: locale)
                    : UsageFormatting.resetText(until: resetsAt, now: now)
                if let piece { base += " · \(piece)" }
            }
        case .none:
            base = ""
        }
        guard hiddenLimitWarning else { return base }
        let flag = Self.warningSign + hiddenWarningLimits.map(\.shortLabel).joined(separator: " ")
        return base.isEmpty ? flag : "\(base) \(flag)"
    }

    /// Names the hidden limits for VoiceOver, such as "Weekly · Fable is above 90 percent". Nil when there are none.
    var hiddenWarningSummary: String? {
        guard hiddenLimitWarning else { return nil }
        let names = hiddenWarningLimits.map(\.title).joined(separator: " and ")
        return "\(names) \(hiddenWarningLimits.count == 1 ? "is" : "are") above \(Int(warningAt)) percent"
    }

    /// "Closest to full" picks the highest reported percentage among windows that haven't reset yet; ties go to
    /// the earlier limit in display order. That is not a forecast of which limit you'll hit first.
    static func make(for snapshot: UsageSnapshot?, metric: MenuBarMetric, now: Date = Date(),
                     warningAt: Double = hiddenWarningThreshold) -> Headline {
        let empty = Headline(limit: nil, text: "—", hiddenWarningLimits: [], awaitingReset: false, warningAt: warningAt)
        guard let snapshot else { return empty }
        let reported = LimitKind.allCases.compactMap { kind in snapshot.percent(for: kind).map { (kind, $0) } }
        let current = reported.filter { !ResetBoundary.isAwaitingReset(snapshot.resetsAt(for: $0.0), now: now) }
        let shown: LimitKind?
        if let fixed = metric.limit {
            shown = fixed
        } else {
            shown = highest(current.isEmpty ? reported : current)
        }
        guard let shown else { return empty }
        let text = "\(shown.shortLabel) \(UsageFormatting.percentText(snapshot.percent(for: shown)))"
        let warnings = current.filter { $0.0 != shown && $0.1 >= warningAt }.map(\.0)
        return Headline(limit: shown, text: text, hiddenWarningLimits: warnings,
                        awaitingReset: ResetBoundary.isAwaitingReset(snapshot.resetsAt(for: shown), now: now),
                        percent: snapshot.percent(for: shown), resetsAt: snapshot.resetsAt(for: shown), warningAt: warningAt)
    }

    private static func highest(_ readings: [(LimitKind, Double)]) -> LimitKind? {
        readings.reduce(nil as (LimitKind, Double)?) { best, next in
            guard let best else { return next }
            return next.1 > best.1 ? next : best
        }?.0
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
    /// The chosen look: colors, used or left, and pace marks.
    var appearance: Appearance = .standard

    /// "94%" or "6% left".
    var percentText: String { appearance.percentText(percent) }
    /// The bare number for a big display with a caption, such as "94" or "6".
    var numberText: String { appearance.numberText(percent) }
    /// The color for this limit, or nil when its percentage is unknown.
    var tint: RGB? { appearance.color(percent: percent.map(Double.init), pace: pace) }
    /// How much of a bar or ring to fill.
    var barFraction: Double { percent.map(appearance.barFraction) ?? 0 }
    /// Where to draw the even-pace tick, or nil when pace is unknown or pace marks are turned off.
    var paceMarkFraction: Double? {
        guard appearance.showPaceGuides, let pace else { return nil }
        return appearance.paceMarkFraction(pace.elapsedFraction)
    }

    static func make(_ kind: LimitKind, snapshot: UsageSnapshot?, now: Date, isStale: Bool,
                     appearance: Appearance = .standard, calendar: Calendar = .current,
                     locale: Locale = .current) -> LimitDisplay {
        let percent = snapshot?.percent(for: kind)
        let resetsAt = snapshot?.resetsAt(for: kind)
        let awaiting = ResetBoundary.isAwaitingReset(resetsAt, now: now)
        let pace = (isStale || awaiting) ? nil
            : Pace.reading(percent: percent, resetsAt: resetsAt, window: kind.windowLength, now: now)
        let resetText = awaiting
            ? "Awaiting reset"
            : UsageFormatting.resetPhrase(until: resetsAt, now: now, style: appearance.resetStyle, calendar: calendar, locale: locale)
        return LimitDisplay(kind: kind, percent: UsageFormatting.wholePercent(percent), resetsAt: resetsAt,
                            awaitingReset: awaiting, pace: pace, resetText: resetText, appearance: appearance)
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
