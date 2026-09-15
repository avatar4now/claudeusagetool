import WidgetKit
import SwiftUI
import Security
import os

/// Logs outcomes only, never credential values. To read the log:
/// /usr/bin/log show --last 10m --predicate 'subsystem == "dev.huan.ClaudeUsageWidget"'
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "widget")

// MARK: - Entry

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    /// When the numbers were fetched, which is not when the widget was drawn.
    let fetchedAt: Date?
    let refreshSeconds: Int
    /// A problem to show: on its own when there are no numbers, or under numbers that are being kept as stale.
    let notice: String?
    /// When the next request may be sent, while a rate limit is in force.
    let nextAttempt: Date?

    var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: fetchedAt, refreshSeconds: refreshSeconds, now: date)
    }

    func display(_ kind: LimitKind) -> LimitDisplay {
        LimitDisplay.make(kind, snapshot: snapshot, now: date, isStale: isStale)
    }

    /// The same data, drawn at a later moment (a reset time, or when it goes stale).
    func at(_ later: Date) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: later, snapshot: snapshot, fetchedAt: fetchedAt, refreshSeconds: refreshSeconds,
                         notice: notice, nextAttempt: nextAttempt)
    }

    static func problem(_ error: UsageError, refreshSeconds: Int, now: Date, nextAttempt: Date? = nil) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: now, snapshot: nil, fetchedAt: nil, refreshSeconds: refreshSeconds,
                         notice: error.message, nextAttempt: nextAttempt)
    }

    static var placeholder: ClaudeUsageEntry {
        let now = Date()
        return ClaudeUsageEntry(
            date: now,
            snapshot: UsageSnapshot(fiveHourPercent: 42, fiveHourResetsAt: now.addingTimeInterval(3 * 3600),
                                    weeklyPercent: 28, weeklyResetsAt: now.addingTimeInterval(3 * 86400),
                                    fableWeeklyPercent: 61, fableWeeklyResetsAt: now.addingTimeInterval(3 * 86400)),
            fetchedAt: now, refreshSeconds: RefreshSchedule.defaultSeconds, notice: nil, nextAttempt: nil)
    }
}

// MARK: - Widget's own rate-limit memory

/// The widget remembers its own cooldown in its sandbox container. The app can't see it, and the widget never
/// writes into the app's shared keychain item.
enum WidgetCooldown {
    private static let untilKey = "rateLimitUntil"
    private static let fromServerKey = "rateLimitFromServer"
    private static let reviewKey = "rateLimitNeedsReview"
    private static let countKey = "rateLimitCount"

    static func load() -> Cooldown? {
        let defaults = UserDefaults.standard
        guard let until = defaults.object(forKey: untilKey) as? Date else { return nil }
        return Cooldown(until: until, fromServer: defaults.bool(forKey: fromServerKey),
                        needsReview: defaults.bool(forKey: reviewKey))
    }

    static func record(retryAfter: TimeInterval?, refreshSeconds: Int, now: Date) -> Cooldown {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: countKey) + 1
        let cooldown = BackoffPolicy.cooldown(afterRateLimit: count, retryAfter: retryAfter, refreshSeconds: refreshSeconds,
                                              now: now, jitter: Double.random(in: 0...1))
        defaults.set(count, forKey: countKey)
        defaults.set(cooldown.until, forKey: untilKey)
        defaults.set(cooldown.fromServer, forKey: fromServerKey)
        defaults.set(cooldown.needsReview, forKey: reviewKey)
        return cooldown
    }

    static func clear() {
        let defaults = UserDefaults.standard
        [untilKey, fromServerKey, reviewKey, countKey].forEach { defaults.removeObject(forKey: $0) }
    }
}

// MARK: - Fetching

struct ClaudeAPIFetcher {
    /// Shows the app's latest numbers when they're fresh and belong to the saved credentials. Otherwise it fetches,
    /// unless a rate limit says to wait, and keeps the last good numbers (marked stale) through unclear failures.
    static func currentEntry(now: Date = Date()) async -> ClaudeUsageEntry {
        // The widget runs in the background, so a keychain problem must become a message, never a dialog.
        KeychainCredentialStore.preventKeychainDialogs()
        let state = KeychainUsageStateStore().load()
        let refreshSeconds = RefreshSchedule.sanitized(state?.refreshSeconds)

        let config: WidgetConfig
        do {
            guard let stored = try KeychainCredentialStore().load(), !stored.isEmpty else {
                logger.notice("No credentials in the keychain")
                return .problem(.noCredentials, refreshSeconds: refreshSeconds, now: now)
            }
            config = stored
        } catch {
            let usageError = error as? UsageError ?? .keychain(errSecInternalComponent)
            logger.error("Keychain read failed: \(usageError.message, privacy: .public)")
            return .problem(usageError, refreshSeconds: refreshSeconds, now: now)
        }

        if let fresh = RefreshSchedule.freshSnapshot(in: state, generation: config.generation, now: now) {
            logger.notice("Showing usage shared by the app")
            return ClaudeUsageEntry(date: now, snapshot: fresh, fetchedAt: state?.fetchedAt, refreshSeconds: refreshSeconds,
                                    notice: nil, nextAttempt: nil)
        }
        let cached = RefreshSchedule.cachedSnapshot(in: state, generation: config.generation)

        let blocking = [state?.cooldown, WidgetCooldown.load()]
            .compactMap { $0 }
            .filter { $0.blocks(at: now, manual: false) }
            .max { $0.until < $1.until }
        if let blocking {
            logger.notice("Waiting out a rate limit before fetching")
            return ClaudeUsageEntry(date: now, snapshot: cached?.snapshot, fetchedAt: cached?.fetchedAt,
                                    refreshSeconds: refreshSeconds,
                                    notice: UsageError.rateLimited(retryAfter: nil).message, nextAttempt: blocking.until)
        }

        var fetcher = UsageFetcher.live
        fetcher.now = { now }
        switch await fetcher.fetch(config: config) {
        case .success(let report):
            WidgetCooldown.clear()
            logger.notice("Usage fetched via \(report.route.rawValue, privacy: .public)")
            return ClaudeUsageEntry(date: now, snapshot: report.snapshot, fetchedAt: now, refreshSeconds: refreshSeconds,
                                    notice: nil, nextAttempt: nil)
        case .failure(let error):
            logger.error("Usage fetch failed: \(error.message, privacy: .public)")
            var nextAttempt: Date?
            if case .rateLimited(let retryAfter) = error {
                nextAttempt = WidgetCooldown.record(retryAfter: retryAfter, refreshSeconds: refreshSeconds, now: now).until
            }
            if RefreshPolicy.keepsLastReport(after: error), let cached {
                return ClaudeUsageEntry(date: now, snapshot: cached.snapshot, fetchedAt: cached.fetchedAt,
                                        refreshSeconds: refreshSeconds, notice: error.message, nextAttempt: nextAttempt)
            }
            return .problem(error, refreshSeconds: refreshSeconds, now: now, nextAttempt: nextAttempt)
        }
    }
}

// MARK: - Timeline Provider

struct ClaudeUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task {
            completion(await ClaudeAPIFetcher.currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        Task {
            let now = Date()
            let entry = await ClaudeAPIFetcher.currentEntry(now: now)
            let cooldown = entry.nextAttempt.map { Cooldown(until: $0, fromServer: false, needsReview: false) }
            // While the app runs it also pushes a redraw after every refresh, so this is the fallback schedule.
            let next = RefreshSchedule.nextRefresh(after: now, refreshSeconds: entry.refreshSeconds,
                                                   snapshot: entry.snapshot, cooldown: cooldown)
            // Extra entries redraw the same data when a limit's reset time passes and when the reading goes stale,
            // even if WidgetKit delays the next reload.
            var dates = ResetBoundary.entryDates(for: entry.snapshot, now: now, before: .distantFuture)
            if entry.snapshot != nil, let fetchedAt = entry.fetchedAt {
                let staleAt = Freshness.staleAt(fetchedAt: fetchedAt, refreshSeconds: entry.refreshSeconds).addingTimeInterval(1)
                if staleAt > now { dates.append(staleAt) }
            }
            let entries = [entry] + Set(dates).sorted().map { entry.at($0) }
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

// MARK: - Subviews

// Color.usageColor, UsageProgressBar, and LimitDisplay's text and color live in Shared/, so the menu bar matches.

/// The bottom line: a problem, a stale warning, or (when all is well) the given text.
struct StatusLine: View {
    let entry: ClaudeUsageEntry
    let normalText: String?
    var size: CGFloat = 10

    var body: some View {
        if let notice = entry.notice {
            Text(notice)
                .font(.system(size: size - 1))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        } else if entry.isStale, let fetchedAt = entry.fetchedAt {
            Text("Data from \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(.orange)
        } else if let normalText {
            Text(normalText)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Shown when there are no numbers at all.
struct ProblemView: View {
    let message: String
    let style: Style

    enum Style { case small, medium, large }

    var body: some View {
        switch style {
        case .small:
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
        case .medium:
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding()
        case .large:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Open the Claude Usage Widget app to fix this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }
}

// MARK: - Small Widget View

struct ClaudeUsageSmallView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if entry.snapshot == nil {
            ProblemView(message: entry.notice ?? "No usage yet.", style: .small)
        } else {
            let fiveHour = entry.display(.fiveHour)
            let weekly = entry.display(.weekly)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Claude")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(fiveHour.percentText)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(fiveHour.color)
                }

                SmallBar(title: "5h Session", display: fiveHour, height: 6)
                SmallBar(title: "Weekly", display: weekly, height: 5)

                Spacer(minLength: 0)
                StatusLine(entry: entry, normalText: fiveHour.resetText)
            }
            .opacity(entry.isStale ? 0.75 : 1)
            .padding(12)
        }
    }
}

struct SmallBar: View {
    let title: String
    let display: LimitDisplay
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            UsageProgressBar(utilization: display.percent ?? 0, height: height,
                             paceFraction: display.pace?.elapsedFraction, isUnknown: display.percent == nil)
        }
        .opacity(display.awaitingReset ? 0.6 : 1)
    }
}

// MARK: - Medium Widget View

struct ClaudeUsageMediumView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if entry.snapshot == nil {
            ProblemView(message: entry.notice ?? "No usage yet.", style: .medium)
        } else {
            let fiveHour = entry.display(.fiveHour)
            let weekly = entry.display(.weekly)
            let fable = entry.display(.fableWeekly)
            HStack(spacing: 16) {
                // Left: 5-hour gauge
                VStack(spacing: 6) {
                    UsageRing(display: fiveHour)
                        .frame(width: 70, height: 70)
                    Text("5h Session")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Right: details
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Claude Usage")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        if entry.isStale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }

                    MiniMetric(title: "Weekly", display: weekly)
                    if fable.percent != nil {
                        MiniMetric(title: "Fable weekly", display: fable)
                    }

                    Text("5h: " + ([fiveHour.resetText, fiveHour.pace?.status.label].compactMap { $0 }.joined(separator: " · ")))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    StatusLine(entry: entry, normalText: weekly.resetText.map { "Weekly: " + $0 })

                    Spacer(minLength: 0)
                }
            }
            .opacity(entry.isStale ? 0.8 : 1)
            .padding(14)
        }
    }
}

/// The medium widget's five-hour ring, with a tick where an even pace would be.
struct UsageRing: View {
    let display: LimitDisplay

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 6)
            if let percent = display.percent {
                Circle()
                    .trim(from: 0, to: CGFloat(min(percent, 100)) / 100.0)
                    .stroke(Color.usageColor(for: percent), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let pace = display.pace {
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 2, height: 10)
                    .offset(y: -35)
                    .rotationEffect(.degrees(360 * pace.elapsedFraction))
            }
            VStack(spacing: 0) {
                Text(display.percent.map(String.init) ?? "—")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(display.color)
                Text("%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(display.awaitingReset ? 0.6 : 1)
    }
}

// MARK: - Large Widget View

struct ClaudeUsageLargeView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if entry.snapshot == nil {
            ProblemView(message: entry.notice ?? "No usage yet.", style: .large)
        } else {
            let fiveHour = entry.display(.fiveHour)
            let weekly = entry.display(.weekly)
            let fable = entry.display(.fableWeekly)
            VStack(spacing: 0) {
                // Title bar
                HStack {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fiveHour.color)
                            .frame(width: 4, height: 18)
                        Text("Claude Usage Monitor")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Spacer()
                    if let fetchedAt = entry.fetchedAt {
                        Text("\(entry.isStale ? "Data from" : "Updated") \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(entry.isStale ? Color.orange : Color.secondary)
                    }
                }
                .padding(.bottom, 14)

                UsageCard(title: "5-Hour Session", display: fiveHour, barHeight: 10)
                    .padding(.bottom, 12)
                UsageCard(title: "Weekly Usage", display: weekly, barHeight: 8)
                    .padding(.bottom, 12)
                // Fable weekly card, shown when the account has a Fable limit
                if fable.percent != nil {
                    UsageCard(title: "Fable Weekly", display: fable, barHeight: 8)
                        .padding(.bottom, 12)
                }

                Spacer(minLength: 0)
                if let notice = entry.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 0) {
                        StatBox(label: "5h", value: fiveHour.percentText, color: fiveHour.color)
                        Divider().frame(height: 30).padding(.horizontal, 8)
                        StatBox(label: "Weekly", value: weekly.percentText, color: weekly.color)
                        Divider().frame(height: 30).padding(.horizontal, 8)
                        StatBox(label: "Status", value: fiveHour.percent.map(statusText) ?? "—", color: fiveHour.color)
                    }
                }
            }
            .opacity(entry.isStale ? 0.85 : 1)
            .padding(16)
        }
    }

    func statusText(for util: Int) -> String {
        switch util {
        case 0..<30: return "Low"
        case 30..<60: return "Normal"
        case 60..<80: return "High"
        case 80..<95: return "Heavy"
        default: return "Limit!"
        }
    }
}

struct UsageCard: View {
    let title: String
    let display: LimitDisplay
    let barHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display.percentText)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(display.color)
            }
            UsageProgressBar(utilization: display.percent ?? 0, height: barHeight,
                             paceFraction: display.pace?.elapsedFraction, isUnknown: display.percent == nil)
            let detail = [display.resetText, display.pace?.status.label].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
        .opacity(display.awaitingReset ? 0.6 : 1)
    }
}

/// A compact labeled bar for the medium widget.
struct MiniMetric: View {
    let title: String
    let display: LimitDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display.percentText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(display.color)
            }
            UsageProgressBar(utilization: display.percent ?? 0, height: 5,
                             paceFraction: display.pace?.elapsedFraction, isUnknown: display.percent == nil)
        }
        .opacity(display.awaitingReset ? 0.6 : 1)
    }
}

struct StatBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Widget View Dispatcher

struct ClaudeUsageWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ClaudeUsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                ClaudeUsageSmallView(entry: entry)
            case .systemMedium:
                ClaudeUsageMediumView(entry: entry)
            case .systemLarge:
                ClaudeUsageLargeView(entry: entry)
            default:
                ClaudeUsageLargeView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Definition

struct ClaudeUsageWidget: Widget {
    // Keep this string stable: changing it removes widgets already placed on the desktop.
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeUsageProvider()) { entry in
            ClaudeUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Monitor your Claude AI usage limits and reset times.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview("Large", as: .systemLarge) {
    ClaudeUsageWidget()
} timeline: {
    ClaudeUsageEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    ClaudeUsageEntry.placeholder
}

#Preview("Small", as: .systemSmall) {
    ClaudeUsageWidget()
} timeline: {
    ClaudeUsageEntry.placeholder
}
