import Foundation

/// Text shared by the widget, the menu bar, and the settings window, so all three show the same numbers.
enum UsageFormatting {
    /// Whole percent, rounded down to match Claude Code's /usage screen. Never negative.
    static func wholePercent(_ percent: Double?) -> Int? {
        percent.map { max(0, Int($0.rounded(.down))) }
    }

    static func percentText(_ percent: Double?) -> String {
        wholePercent(percent).map { "\($0)%" } ?? "—"
    }

    /// Time left until a reset, like "45m", "2h 5m", or "3d 4h".
    static func resetText(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    /// "9:40 PM" today, "Wed 9:40 PM" within the next few days, or "Mon, Sep 21 at 9:40 PM" about a week away,
    /// where the weekday alone could be mistaken for this week's.
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        if !calendar.isDate(date, inSameDayAs: now) { style = style.weekday(.abbreviated) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if abs(days) >= 6 { style = style.month(.abbreviated).day() }
        return date.formatted(style)
    }

    /// "at 9:40 PM" today, otherwise the same as `moment`, such as "Wed 9:40 PM".
    static func resetMoment(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let text = moment(date, now: now, calendar: calendar, locale: locale)
        return calendar.isDate(date, inSameDayAs: now) ? "at \(text)" : text
    }

    /// A reset time in the chosen style: "Resets in 2h 10m", "Resets at 6:10 PM", or "Resets at 6:10 PM, in 2h 10m".
    static func resetPhrase(until date: Date?, now: Date, style: ResetStyle,
                            calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        guard date > now, let countdown = resetText(until: date, now: now) else { return "Resets now" }
        let clock = resetMoment(date, now: now, calendar: calendar, locale: locale)
        switch style {
        case .countdown: return "Resets in \(countdown)"
        case .clockTime: return "Resets \(clock)"
        case .both: return "Resets \(clock), in \(countdown)"
        }
    }
}

/// The one-line result shown in the settings window after Save or Test Connection.
enum ConnectionSummary {
    struct Line: Equatable {
        var text: String
        var isSuccess: Bool
    }

    static func message(for result: Result<UsageReport, UsageError>) -> Line {
        switch result {
        case .failure(let error):
            return Line(text: error.message, isSuccess: false)
        case .success(let report):
            let metrics = metricsLine(report.snapshot)
            guard let tokenFailure = report.tokenFailure else {
                return Line(text: "Connected. \(metrics).", isSuccess: true)
            }
            let tokenHint = tokenFailure == .tokenCannotReadUsage
                ? "Your OAuth token can't read usage, so you can clear it."
                : "Your OAuth token didn't work, so you can clear it."
            return Line(text: "Connected with your session key. \(metrics). \(tokenHint)", isSuccess: true)
        }
    }

    /// Known values only, like "5-hour 42% · weekly 7% · Fable 12%".
    static func metricsLine(_ snapshot: UsageSnapshot) -> String {
        [("5-hour", snapshot.fiveHourPercent), ("weekly", snapshot.weeklyPercent), ("Fable", snapshot.fableWeeklyPercent)]
            .compactMap { name, percent in percent.map { _ in "\(name) \(UsageFormatting.percentText(percent))" } }
            .joined(separator: " · ")
    }
}
