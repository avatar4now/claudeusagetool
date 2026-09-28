import Charts
import SwiftUI

// Pure views with no live state, so they can be rendered and checked in isolation.

enum HistoryRange: String, CaseIterable, Identifiable {
    case twoWeeks
    case month
    case quarter

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .twoWeeks: return 14
        case .month: return 30
        case .quarter: return 90
        }
    }
    var title: String {
        switch self {
        case .twoWeeks: return "2 weeks"
        case .month: return "30 days"
        case .quarter: return "90 days"
        }
    }
}

/// The app's main window: current limits, a forecast, then charts built from the saved history.
struct DashboardContent: View {
    let snapshot: UsageSnapshot?
    let lastSuccessAt: Date?
    let error: UsageError?
    let cooldown: Cooldown?
    let isRefreshing: Bool
    let refreshSeconds: Int
    let samples: [UsageSample]
    let isHistoryEnabled: Bool
    let now: Date
    var calendar: Calendar = .current
    @Binding var range: HistoryRange
    var appearance: Appearance = .standard
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onCustomize: () -> Void = {}
    /// Off only for image previews, which can't draw scroll views.
    var scrolls = true

    private var palette: Palette { appearance.palette }

    private var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: lastSuccessAt, refreshSeconds: refreshSeconds, now: now)
    }

    private var hasFable: Bool {
        snapshot?.fableWeeklyPercent != nil || samples.contains { $0.fable != nil }
    }

    /// The limits with a card: the 5-hour and weekly limits, plus Fable when the service reports it.
    private var visibleLimits: [LimitKind] {
        LimitKind.allCases.filter { $0 != .fableWeekly || snapshot?.fableWeeklyPercent != nil }
    }

    var body: some View {
        if scrolls {
            ScrollView { page }
        } else {
            page
        }
    }

    private var page: some View {
        // Worked out once per redraw and shared by the cards and charts below.
        let displays = Dictionary(uniqueKeysWithValues: visibleLimits.map {
            ($0, LimitDisplay.make($0, snapshot: snapshot, now: now, isStale: isStale, appearance: appearance, calendar: calendar))
        })
        let outcomes = Dictionary(uniqueKeysWithValues: visibleLimits.map {
            ($0, UsageForecast.make($0, snapshot: snapshot, samples: samples, now: now, isStale: isStale))
        })
        let days = UsageHistoryAnalysis.daily(samples, days: range.days, endingOn: now, calendar: calendar)
        return VStack(alignment: .leading, spacing: 18) {
            header
            problems
            HStack(alignment: .top, spacing: 14) {
                ForEach(visibleLimits, id: \.self) { kind in
                    if let display = displays[kind] {
                        DashboardLimitCard(display: display, dimmed: isStale,
                                           trend: UsageHistoryAnalysis.currentWindow(samples, kind: kind,
                                                                                     resetsAt: snapshot?.resetsAt(for: kind), now: now),
                                           seriesColor: palette.series(for: kind).color)
                    }
                }
            }
            ForecastCard(rows: visibleLimits.map { kind in
                ForecastRow.make(outcomes[kind] ?? .unavailable, kind: kind, now: now, calendar: calendar)
            }, palette: palette)
            dailyCard(days: days)
            HStack(alignment: .top, spacing: 18) {
                thisWeekCard(forecasts: outcomes)
                fiveHourCard
            }
            rhythmCard
            footer
        }
        .padding(24)
    }

    // MARK: Header and problems

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Claude Usage")
                .font(.largeTitle.bold())
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else if let lastSuccessAt {
                Text("\(isStale ? "Data from" : "Updated") \(lastSuccessAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(isStale ? Color.orange : Color.secondary)
            }
            Spacer()
            Button(action: onCustomize) { Label("Customize", systemImage: "paintpalette") }
                .help("Change colors, numbers, the menu bar, and charts")
            Button(action: onRefresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(isRefreshing)
                .keyboardShortcut("r")
            Button(action: onOpenSettings) { Label("Settings", systemImage: "gearshape") }
                .keyboardShortcut(",")
        }
    }

    @ViewBuilder
    private var problems: some View {
        if let cooldown, cooldown.until > now {
            Label("Rate limited. Next try at \(cooldown.until.formatted(date: .omitted, time: .shortened)).", systemImage: "hourglass")
                .foregroundStyle(.orange)
        }
        if let error, !(cooldown.map { $0.until > now } ?? false && error.isRateLimited) {
            Label(error.message, systemImage: ProblemCause(error).symbol)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Used per day

    private func dailyCard(days: [DailyUsage]) -> some View {
        DashboardCard {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Weekly limit used per day", systemImage: "chart.bar.fill",
                          caption: "Percentage points of your weekly limits used each day. Hover for details.")
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if samples.isEmpty {
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 220)
            } else {
                DailyUsageChart(days: days, showFable: hasFable, calendar: calendar, palette: palette,
                                resets: UsageHistoryAnalysis.weeklyResets(samples, from: days.first?.day ?? now, to: now))
                    .frame(height: 230)
                DailyStats(days: days, showFable: hasFable, firstReading: samples.first?.at, rangeStart: days.first?.day)
            }
        }
    }

    // MARK: This week and the five-hour session

    private func thisWeekCard(forecasts: [LimitKind: ForecastOutcome]) -> some View {
        DashboardCard {
            if let week = UsageHistoryAnalysis.currentWeek(samples, now: now), !week.points.isEmpty {
                CardTitle("This week", systemImage: "calendar",
                          caption: "Resets \(week.end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                WeekChart(week: week, showFable: hasFable, now: now, appearance: appearance,
                          weeklyProjection: projection(forecasts[.weekly], within: week),
                          fableProjection: projection(forecasts[.fableWeekly], within: week))
                    .frame(height: 210)
            } else {
                CardTitle("This week", systemImage: "calendar", caption: nil)
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 210)
            }
        }
    }

    /// The dashed forecast line for one limit, or nothing when there is no forecast or forecast lines are off.
    private func projection(_ outcome: ForecastOutcome?, within week: WeekSeries) -> [SeriesPoint] {
        guard appearance.showForecastLines, case .forecast(let forecast) = outcome else { return [] }
        return forecast.projection(now: now, within: week)
    }

    private var fiveHourCard: some View {
        DashboardCard {
            let series = UsageHistoryAnalysis.recentFiveHour(samples, now: now)
            if series.isEmpty {
                CardTitle("5-hour session · last 24 hours", systemImage: "timer", caption: nil)
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 210)
            } else {
                CardTitle("5-hour session · last 24 hours", systemImage: "timer",
                          caption: "Peak \(Int((series.map(\.value).max() ?? 0).rounded(.down)))%")
                FiveHourChart(series: series, now: now, appearance: appearance)
                    .frame(height: 210)
            }
        }
    }

    // MARK: When you use Claude

    private var rhythmCard: some View {
        let cells = UsageHistoryAnalysis.hourlyRhythm(samples, days: range.days, endingOn: now, calendar: calendar)
        return DashboardCard {
            CardTitle("When you use Claude", systemImage: "square.grid.3x3.fill",
                      caption: "Weekly limit points used in each hour, over the last \(range.title). Hover for details.")
            if cells.allSatisfy({ $0.points == 0 }) {
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 190)
            } else {
                RhythmChart(cells: cells, calendar: calendar, color: palette.allModels.color)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let first = samples.first {
                Text("\(samples.count) readings since \(first.at.formatted(date: .abbreviated, time: .shortened)), saved only on this Mac.")
            } else {
                Text(isHistoryEnabled ? "History is saved only on this Mac." : "Usage history is turned off in Settings.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Pieces

struct DashboardCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

/// A card's title with a small symbol, and an optional caption underneath.
struct CardTitle: View {
    let title: String
    let systemImage: String
    let caption: String?

    init(_ title: String, systemImage: String, caption: String?) {
        self.title = title
        self.systemImage = systemImage
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .labelStyle(TitleWithTintedIcon())
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TitleWithTintedIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(.secondary)
                .imageScale(.small)
            configuration.title
        }
    }
}

/// One current limit: a ring with the number inside, when it resets, the pace, and a trend line for this window.
struct DashboardLimitCard: View {
    let display: LimitDisplay
    let dimmed: Bool
    var trend: [SeriesPoint] = []
    /// The limit's color in the charts below, shown as a small dot so the two are easy to match.
    var seriesColor: Color = .secondary

    private var windowStart: Date? {
        display.resetsAt.map { $0.addingTimeInterval(-display.kind.windowLength) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                UsageRingTrack(display: display, lineWidth: 9)
                VStack(spacing: -1) {
                    Text(display.numberText)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(display.color)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: Double(display.percent ?? 0)))
                        .animation(.snappy, value: display.percent)
                    Text(display.percent == nil ? " " : "% \(display.appearance.numberCaption)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(seriesColor)
                        .frame(width: 7, height: 7)
                    Text(display.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(display.resetText ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(display.pace?.status.label ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let windowStart, let end = display.resetsAt, trend.count > 1 {
                    Sparkline(points: trend, start: windowStart, end: end, color: display.color,
                              showsLeft: display.appearance.numbers == .left, shaded: display.appearance.shadeCharts)
                        .frame(height: 26)
                        .padding(.top, 2)
                } else {
                    Spacer(minLength: 0)
                        .frame(height: 28)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .opacity(dimmed || display.awaitingReset ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [display.kind.title]
        if display.percent == nil {
            parts.append("not reported")
        } else {
            parts.append(display.percentText.replacingOccurrences(of: "%", with: " percent")
                         + (display.appearance.numbers == .used ? " used" : ""))
        }
        if let reset = display.resetText { parts.append(reset) }
        if let pace = display.pace { parts.append(pace.status.label) }
        return parts.joined(separator: ", ")
    }
}

/// "If you keep using Claude at the same pace": one row per limit with a status chip, when it runs out, and a budget.
struct ForecastCard: View {
    let rows: [ForecastRow]
    var palette: Palette = ColorTheme.classic.palette

    var body: some View {
        DashboardCard {
            CardTitle("Forecast", systemImage: "chart.line.uptrend.xyaxis",
                      caption: "If you keep using Claude at the same pace")
            ForEach(Array(rows.enumerated()), id: \.element.kind) { index, row in
                if index > 0 { Divider() }
                ForecastRowView(row: row, palette: palette)
            }
        }
    }
}

struct ForecastRowView: View {
    let row: ForecastRow
    var palette: Palette = ColorTheme.classic.palette

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForecastChip(status: row.status, palette: palette)
            }
            .frame(width: 180, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.headline)
                    .font(.body.weight(.medium))
                if let detail = row.detail {
                    Text(detail)
                        .font(.callout)
                }
                if let basis = row.basis {
                    Text(basis)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// A small colored label in the theme's colors: alert when the limit runs out or is used up, caution when close,
/// calm when it should last.
struct ForecastChip: View {
    let status: ForecastStatus
    var palette: Palette = ColorTheme.classic.palette

    private var color: Color {
        switch status {
        case .runsOut, .limitReached: return palette.alert.color
        case .cuttingItClose: return palette.caution.color
        case .shouldLast: return palette.calm.color
        case .tooEarly, .noUsageYet, .unavailable: return .secondary
        }
    }

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct EmptyHistory: View {
    let isHistoryEnabled: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(isHistoryEnabled ? "This fills in as readings come in." : "Usage history is turned off in Settings.")
                .foregroundStyle(.secondary)
            if isHistoryEnabled {
                Text("The app saves a reading every few minutes while it runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct DailyStats: View {
    let days: [DailyUsage]
    let showFable: Bool
    let firstReading: Date?
    let rangeStart: Date?

    var body: some View {
        let tracked = days.filter(\.hasReadings)
        let busiest = tracked.filter { $0.weeklyPoints > 0 }.max { $0.weeklyPoints < $1.weeklyPoints }
        let averageWeekly = tracked.isEmpty ? 0 : tracked.map(\.weeklyPoints).reduce(0, +) / Double(tracked.count)
        let sessions = days.map(\.fiveHourSessionsOverNinety).reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 28) {
                Stat(title: "Days with readings", value: "\(tracked.count)")
                Stat(title: "Average per day", value: String(format: "%.0f pts", averageWeekly))
                Stat(title: "Busiest day", value: busiest.map { "\($0.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(Int($0.weeklyPoints)) pts" } ?? "—")
                if showFable {
                    Stat(title: "Fable used", value: String(format: "%.0f pts", days.map(\.fablePoints).reduce(0, +)))
                }
                Stat(title: "5-hour sessions at 90%+", value: "\(sessions)")
            }
            if let firstReading, let rangeStart, firstReading > rangeStart {
                Text("History started \(firstReading.formatted(date: .abbreviated, time: .omitted)); earlier days have no readings. Usage from while the app was closed counts on the next day it ran.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
