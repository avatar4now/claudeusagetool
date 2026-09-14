import WidgetKit
import SwiftUI
import Security
import os

// MARK: - Data Models

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let fiveHourUtil: Int?
    let fiveHourResetsAt: Date?
    let weeklyUtil: Int?
    let weeklyResetsAt: Date?
    let fableUtil: Int?
    let fableResetsAt: Date?
    let error: String?

    static var placeholder: ClaudeUsageEntry {
        ClaudeUsageEntry(
            date: Date(),
            fiveHourUtil: 42,
            fiveHourResetsAt: Date().addingTimeInterval(3 * 3600),
            weeklyUtil: 28,
            weeklyResetsAt: Date().addingTimeInterval(3 * 86400),
            fableUtil: 61,
            fableResetsAt: Date().addingTimeInterval(3 * 86400),
            error: nil
        )
    }

    /// Percentages are rounded down, matching Claude Code's /usage screen.
    static func from(_ snapshot: UsageSnapshot) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(),
                         fiveHourUtil: UsageFormatting.wholePercent(snapshot.fiveHourPercent),
                         fiveHourResetsAt: snapshot.fiveHourResetsAt,
                         weeklyUtil: UsageFormatting.wholePercent(snapshot.weeklyPercent),
                         weeklyResetsAt: snapshot.weeklyResetsAt,
                         fableUtil: UsageFormatting.wholePercent(snapshot.fableWeeklyPercent),
                         fableResetsAt: snapshot.fableWeeklyResetsAt,
                         error: nil)
    }

    static func failure(_ error: UsageError) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(), fiveHourUtil: nil, fiveHourResetsAt: nil, weeklyUtil: nil,
                         weeklyResetsAt: nil, fableUtil: nil, fableResetsAt: nil, error: error.message)
    }
}

// MARK: - API Fetcher

/// Logs outcomes only, never credential values. To read the log:
/// log show --last 10m --predicate 'subsystem == "dev.huan.ClaudeUsageWidget"'
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "widget")

struct ClaudeAPIFetcher {
    /// Shows the numbers the app fetched moments ago when they're fresh, and fetches directly otherwise
    /// (for example when the app isn't running). Also returns the refresh interval chosen in the app.
    static func currentEntry() async -> (entry: ClaudeUsageEntry, refreshSeconds: Int) {
        KeychainCredentialStore.preventKeychainDialogs()
        let state = KeychainUsageStateStore().load()
        let refreshSeconds = RefreshSchedule.sanitized(state?.refreshSeconds)
        if let snapshot = RefreshSchedule.freshSnapshot(in: state) {
            logger.notice("Showing usage shared by the app")
            return (.from(snapshot), refreshSeconds)
        }
        return (await fetchUsage(), refreshSeconds)
    }

    static func fetchUsage() async -> ClaudeUsageEntry {
        // The widget runs in the background, so a keychain problem must become a message, never a dialog.
        KeychainCredentialStore.preventKeychainDialogs()

        let config: WidgetConfig
        do {
            guard let stored = try KeychainCredentialStore().load(), !stored.isEmpty else {
                logger.notice("No credentials in the keychain")
                return .failure(.noCredentials)
            }
            config = stored
        } catch {
            let usageError = error as? UsageError ?? .keychain(errSecInternalComponent)
            logger.error("Keychain read failed: \(usageError.message, privacy: .public)")
            return .failure(usageError)
        }
        logger.notice("Credentials loaded: oauth=\(config.oauthToken != nil, privacy: .public) sessionKey=\(config.sessionKey != nil, privacy: .public)")

        switch await UsageFetcher.live.fetch(config: config) {
        case .success(let report):
            logger.notice("Usage fetched via \(String(describing: report.route), privacy: .public)")
            return .from(report.snapshot)
        case .failure(let error):
            logger.error("Usage fetch failed: \(error.message, privacy: .public)")
            return .failure(error)
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
            completion(await ClaudeAPIFetcher.currentEntry().entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        Task {
            let (entry, refreshSeconds) = await ClaudeAPIFetcher.currentEntry()
            // While the app runs it also pushes a redraw after every refresh, so this is the fallback schedule.
            let next = Date().addingTimeInterval(TimeInterval(refreshSeconds))
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Subviews

// Color.usageColor and UsageProgressBar live in Shared/UsageStyle.swift, so the menu bar uses the same look.

struct CountdownText: View {
    let resetsAt: Date?
    let label: String

    var body: some View {
        if let text = UsageFormatting.resetText(until: resetsAt) {
            Text("\(label) \(text)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small Widget View

struct ClaudeUsageSmallView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if let error = entry.error {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 4) {
                    Text("Claude")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if let util = entry.fiveHourUtil {
                        Text("\(util)%")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.usageColor(for: util))
                    }
                }

                // 5h bar
                if let util = entry.fiveHourUtil {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("5h Session")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        UsageProgressBar(utilization: util, height: 6)
                    }
                }

                // Weekly bar
                if let weekly = entry.weeklyUtil {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Weekly")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        UsageProgressBar(utilization: weekly, height: 5)
                    }
                }

                Spacer(minLength: 0)
                CountdownText(resetsAt: entry.fiveHourResetsAt, label: "Reset:")
            }
            .padding(12)
        }
    }
}

// MARK: - Medium Widget View

struct ClaudeUsageMediumView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if let error = entry.error {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            HStack(spacing: 16) {
                // Left: 5-hour gauge
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(entry.fiveHourUtil ?? 0) / 100.0)
                            .stroke(
                                Color.usageColor(for: entry.fiveHourUtil ?? 0),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(entry.fiveHourUtil ?? 0)")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.usageColor(for: entry.fiveHourUtil ?? 0))
                            Text("%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 70, height: 70)

                    Text("5h Session")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Right: details
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Claude Usage")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                    }

                    MiniMetric(title: "Weekly", utilization: entry.weeklyUtil ?? 0)
                    if let fable = entry.fableUtil {
                        MiniMetric(title: "Fable weekly", utilization: fable)
                    }

                    // Reset times
                    CountdownText(resetsAt: entry.fiveHourResetsAt, label: "5h reset:")
                    CountdownText(resetsAt: entry.weeklyResetsAt, label: "Weekly reset:")

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Large Widget View

struct ClaudeUsageLargeView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if let error = entry.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Open the Claude Usage Widget app to fix this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding()
        } else {
            VStack(spacing: 0) {
                // Title bar
                HStack {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.usageColor(for: entry.fiveHourUtil ?? 0))
                            .frame(width: 4, height: 18)
                        Text("Claude Usage Monitor")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 14)

                // 5-hour session card
                UsageCard(
                    title: "5-Hour Session",
                    utilization: entry.fiveHourUtil ?? 0,
                    resetsAt: entry.fiveHourResetsAt,
                    barHeight: 10
                )
                .padding(.bottom, 12)

                // Weekly card
                UsageCard(
                    title: "Weekly Usage",
                    utilization: entry.weeklyUtil ?? 0,
                    resetsAt: entry.weeklyResetsAt,
                    barHeight: 8
                )
                .padding(.bottom, 12)

                // Fable weekly card, shown when the account has a Fable limit
                if let fable = entry.fableUtil {
                    UsageCard(
                        title: "Fable Weekly",
                        utilization: fable,
                        resetsAt: entry.fableResetsAt,
                        barHeight: 8
                    )
                    .padding(.bottom, 12)
                }

                // Bottom stats
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    StatBox(label: "5h", value: "\(entry.fiveHourUtil ?? 0)%",
                            color: Color.usageColor(for: entry.fiveHourUtil ?? 0))
                    Divider().frame(height: 30).padding(.horizontal, 8)
                    StatBox(label: "Weekly", value: "\(entry.weeklyUtil ?? 0)%",
                            color: Color.usageColor(for: entry.weeklyUtil ?? 0))
                    Divider().frame(height: 30).padding(.horizontal, 8)
                    StatBox(label: "Status", value: statusText(for: entry.fiveHourUtil ?? 0),
                            color: Color.usageColor(for: entry.fiveHourUtil ?? 0))
                }
            }
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
    let utilization: Int
    let resetsAt: Date?
    let barHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(utilization)%")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.usageColor(for: utilization))
            }
            UsageProgressBar(utilization: utilization, height: barHeight)
            CountdownText(resetsAt: resetsAt, label: "Resets in")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}

/// A compact labeled bar for the medium widget.
struct MiniMetric: View {
    let title: String
    let utilization: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(utilization)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.usageColor(for: utilization))
            }
            UsageProgressBar(utilization: utilization, height: 5)
        }
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
