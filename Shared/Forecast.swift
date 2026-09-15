import Foundation

// MARK: - The forecast

/// Which readings the usage rate comes from.
enum ForecastBasis: Equatable, Sendable {
    /// The change since a reading from about a day ago in the same window.
    case lastDay
    /// Everything used since the window began.
    case windowSoFar

    var text: String {
        switch self {
        case .lastDay: return "Based on the last 24 hours"
        case .windowSoFar: return "Based on this window so far"
        }
    }
}

/// Where a limit is heading if usage keeps the same pace.
struct LimitForecast: Equatable, Sendable {
    let kind: LimitKind
    let percent: Double
    let resetsAt: Date
    let basis: ForecastBasis
    /// Percentage points used per hour.
    let pointsPerHour: Double
    /// The percentage expected at the reset. It can go past 100.
    let projectedAtReset: Double
    /// When 100% would be reached. Nil unless that happens before the reset.
    let runsOutAt: Date?
    /// Points left before 100%, never negative.
    let pointsLeft: Double
    /// Points a day that would last until the reset. Weekly limits only, and nil when less than a day is left.
    let dailyBudget: Double?
    /// Points a day at the current pace. Weekly limits only.
    let recentPointsPerDay: Double?
}

enum ForecastOutcome: Equatable, Sendable {
    case forecast(LimitForecast)
    /// The limit is at 100%. The reset time is nil when the service didn't report a usable one.
    case limitReached(resetsAt: Date?)
    /// Less than 1% used. The reset time is nil when no window has started yet, as between 5-hour sessions.
    case noUsageYet(resetsAt: Date?)
    case tooEarly(resetsAt: Date)
    /// Stale numbers, a reset time that has passed, or some usage with no reset time.
    case unavailable
}

enum UsageForecast {
    /// A reading this old or older can stand in for "a day ago"...
    static let lastDayMinimumAge: TimeInterval = 20 * 3600
    /// ...as long as it isn't older than this.
    static let lastDayMaximumAge: TimeInterval = 28 * 3600

    /// How far into a window a forecast starts: the same 3% as pace, but never under 15 minutes.
    static func minimumElapsed(for kind: LimitKind) -> TimeInterval {
        max(kind.windowLength * Pace.minimumElapsedFraction, 15 * 60)
    }

    /// Projects one limit to its reset. Percentages only rise within a window, so the change between two readings is
    /// the usage in between, even if the app was closed for part of it.
    static func make(_ kind: LimitKind, snapshot: UsageSnapshot?, samples: [UsageSample], now: Date, isStale: Bool) -> ForecastOutcome {
        guard let snapshot, let percent = snapshot.percent(for: kind), !isStale else { return .unavailable }
        let reported = snapshot.resetsAt(for: kind)
        guard !ResetBoundary.isAwaitingReset(reported, now: now) else { return .unavailable }
        let resetsAt = reported.flatMap { $0.timeIntervalSince(now) <= kind.windowLength + 60 ? $0 : nil }
        if percent >= 100 { return .limitReached(resetsAt: resetsAt) }
        // The service leaves out the reset time when no window has started, such as between 5-hour sessions.
        if resetsAt == nil && percent < 1 { return .noUsageYet(resetsAt: nil) }
        guard let resetsAt else { return .unavailable }

        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = kind.windowLength - remaining
        if elapsed < minimumElapsed(for: kind) { return .tooEarly(resetsAt: resetsAt) }
        if percent < 1 { return .noUsageYet(resetsAt: resetsAt) }

        var basis = ForecastBasis.windowSoFar
        var rate = percent / (elapsed / 3600)
        if kind != .fiveHour, let dayAgo = dayOldReading(kind, resetsAt: resetsAt, samples: samples, now: now) {
            basis = .lastDay
            rate = max(0, percent - dayAgo.value) / (now.timeIntervalSince(dayAgo.at) / 3600)
        }

        let hoursLeft = remaining / 3600
        var runsOutAt: Date?
        if rate > 0 {
            let date = now.addingTimeInterval((100 - percent) / rate * 3600)
            if date < resetsAt { runsOutAt = date }
        }
        let pointsLeft = max(0, 100 - percent)
        let isWeekly = kind != .fiveHour
        return .forecast(LimitForecast(
            kind: kind, percent: percent, resetsAt: resetsAt, basis: basis, pointsPerHour: rate,
            projectedAtReset: percent + rate * hoursLeft, runsOutAt: runsOutAt, pointsLeft: pointsLeft,
            dailyBudget: isWeekly && hoursLeft >= 24 ? pointsLeft / (hoursLeft / 24) : nil,
            recentPointsPerDay: isWeekly ? rate * 24 : nil))
    }

    /// The newest reading from this window that is 20 to 28 hours old.
    private static func dayOldReading(_ kind: LimitKind, resetsAt: Date, samples: [UsageSample], now: Date) -> (at: Date, value: Double)? {
        samples
            .filter { sample in
                let age = now.timeIntervalSince(sample.at)
                return age >= lastDayMinimumAge && age <= lastDayMaximumAge
                    && sample.value(for: kind) != nil
                    && !HistoryPolicy.windowChanged(sample.reset(for: kind), resetsAt)
            }
            .max { $0.at < $1.at }
            .flatMap { sample in sample.value(for: kind).map { (sample.at, $0) } }
    }
}

extension UsageSample {
    func value(for kind: LimitKind) -> Double? {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        case .fableWeekly: return fable
        }
    }

    func reset(for kind: LimitKind) -> Date? {
        switch kind {
        case .fiveHour: return fiveHourReset
        case .weekly: return weeklyReset
        case .fableWeekly: return fableReset
        }
    }
}

// MARK: - Chart projection

extension LimitForecast {
    /// The dashed line for the "this week" chart: from now to when it reaches 100%, or to the reset.
    /// Empty when this limit's window isn't the chart's week or the chart has already ended; clipped to the chart's end.
    func projection(now: Date, within week: WeekSeries) -> [SeriesPoint] {
        guard !HistoryPolicy.windowChanged(resetsAt, week.end), now < week.end else { return [] }
        var end = runsOutAt.map { SeriesPoint(at: $0, value: 100) } ?? SeriesPoint(at: resetsAt, value: min(projectedAtReset, 100))
        if end.at > week.end {
            let fraction = week.end.timeIntervalSince(now) / end.at.timeIntervalSince(now)
            end = SeriesPoint(at: week.end, value: percent + (end.value - percent) * fraction)
        }
        return [SeriesPoint(at: now, value: percent), end]
    }
}

// MARK: - One row of the forecast card

/// The chip shown next to each limit.
enum ForecastStatus: Equatable, Sendable {
    case runsOut
    case cuttingItClose
    case shouldLast
    case limitReached
    case tooEarly
    case noUsageYet
    case unavailable

    /// Below this projected percentage a limit should last comfortably.
    static let closeCallThreshold = 90.0

    init(_ outcome: ForecastOutcome) {
        switch outcome {
        case .forecast(let forecast):
            if forecast.runsOutAt != nil {
                self = .runsOut
            } else {
                self = forecast.projectedAtReset < Self.closeCallThreshold ? .shouldLast : .cuttingItClose
            }
        case .limitReached: self = .limitReached
        case .noUsageYet: self = .noUsageYet
        case .tooEarly: self = .tooEarly
        case .unavailable: self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .runsOut: return "Runs out before reset"
        case .cuttingItClose: return "Cutting it close"
        case .shouldLast: return "Should last"
        case .limitReached: return "Limit reached"
        case .tooEarly: return "Too early to tell"
        case .noUsageYet: return "No usage yet"
        case .unavailable: return "Not available"
        }
    }
}

/// The text for one limit in the dashboard's forecast card.
struct ForecastRow: Equatable, Sendable {
    let kind: LimitKind
    let status: ForecastStatus
    /// Such as "Reaches 100% around Wed 9:40 PM, 1d 5h before it resets".
    let headline: String
    /// The budget line for weekly limits, or when the limit resets.
    let detail: String?
    /// Which readings the forecast is based on.
    let basis: String?

    /// The whole row as one sentence for VoiceOver.
    var accessibilityLabel: String {
        var parts = ["\(kind.title), \(Self.lowercasingFirst(status.title)). \(headline)"]
        if let detail { parts.append(Self.lowercasingFirst(detail.replacingOccurrences(of: " · ", with: ", "))) }
        if let basis { parts.append(Self.lowercasingFirst(basis)) }
        return parts.joined(separator: ", ") + "."
    }

    static func make(_ outcome: ForecastOutcome, kind: LimitKind, now: Date,
                     calendar: Calendar = .current, locale: Locale = .current) -> ForecastRow {
        let status = ForecastStatus(outcome)

        /// "9:40 PM" today, "Wed 9:40 PM" within the next few days, or "Mon, Sep 21 at 9:40 PM" about a week away,
        /// where the weekday alone could be mistaken for this week's.
        func moment(_ date: Date) -> String {
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
            if !calendar.isDate(date, inSameDayAs: now) { style = style.weekday(.abbreviated) }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
            if abs(days) >= 6 { style = style.month(.abbreviated).day() }
            return date.formatted(style)
        }
        /// "at 9:40 PM" today, otherwise "Wed 9:40 PM".
        func resetMoment(_ date: Date) -> String {
            calendar.isDate(date, inSameDayAs: now) ? "at \(moment(date))" : moment(date)
        }

        switch outcome {
        case .forecast(let forecast):
            let headline: String
            if let runsOutAt = forecast.runsOutAt {
                let gap = shortDuration(until: forecast.resetsAt, from: runsOutAt)
                headline = "Reaches 100% around \(moment(runsOutAt)), \(gap) before it resets"
            } else {
                headline = "About \(Int(forecast.projectedAtReset.rounded()))% used when it resets \(resetMoment(forecast.resetsAt))"
            }
            return ForecastRow(kind: kind, status: status, headline: headline,
                               detail: budgetLine(forecast, now: now), basis: forecast.basis.text)
        case .limitReached(let resetsAt):
            return ForecastRow(kind: kind, status: status, headline: "All of this limit is used",
                               detail: resetsAt.map { "Resets \(resetMoment($0))" }, basis: nil)
        case .tooEarly(let resetsAt):
            let starts = resetsAt.addingTimeInterval(-kind.windowLength + UsageForecast.minimumElapsed(for: kind))
            return ForecastRow(kind: kind, status: status, headline: "A forecast starts around \(moment(starts))",
                               detail: "Resets \(resetMoment(resetsAt))", basis: nil)
        case .noUsageYet(let resetsAt):
            // With no reset time, the 5-hour window hasn't started yet.
            let headline = resetsAt == nil && kind == .fiveHour
                ? "Nothing used yet · a session starts with your next message" : "Nothing used yet in this window"
            return ForecastRow(kind: kind, status: status, headline: headline,
                               detail: resetsAt.map { "Resets \(resetMoment($0))" }, basis: nil)
        case .unavailable:
            return ForecastRow(kind: kind, status: status, headline: "Needs a current reading with a reset time",
                               detail: nil, basis: nil)
        }
    }

    /// "Budget: about 3 pts a day for the next 2.2 days · lately about 12 pts a day", or "6 pts left for the next 14h".
    private static func budgetLine(_ forecast: LimitForecast, now: Date) -> String? {
        guard forecast.kind != .fiveHour else { return nil }
        // Rounding up matches the rounded-down percentage on the limit cards: 94.8% shows as 94%, so 6 pts left.
        let left = Int(forecast.pointsLeft.rounded(.up))
        guard let budget = forecast.dailyBudget else {
            return "\(pointsText(left)) left for the next \(shortDuration(until: forecast.resetsAt, from: now))"
        }
        let days = String(format: "%.1f", forecast.resetsAt.timeIntervalSince(now) / 86_400)
        var line = "Budget: \(perDayText(budget)) for the next \(days) days"
        if let pace = forecast.recentPointsPerDay {
            let when = forecast.basis == .lastDay ? "lately" : "so far"
            line += pace == 0 ? " · none used \(when)" : " · \(when) \(perDayText(pace))"
        }
        return line
    }

    /// "about 3 pts a day", "about 1 pt a day", or "less than 1 pt a day".
    private static func perDayText(_ points: Double) -> String {
        points < 1 ? "less than 1 pt a day" : "about \(pointsText(Int(points.rounded()))) a day"
    }

    private static func pointsText(_ points: Int) -> String {
        points == 1 ? "1 pt" : "\(points) pts"
    }

    /// Like the reset countdown, but without a trailing zero: "1d 5h", "14h", "1h 30m", "45m".
    private static func shortDuration(until end: Date, from start: Date) -> String {
        let text = UsageFormatting.resetText(until: end, now: start) ?? ""
        for zero in [" 0m", " 0h"] where text.hasSuffix(zero) {
            return String(text.dropLast(zero.count))
        }
        return text
    }

    private static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
