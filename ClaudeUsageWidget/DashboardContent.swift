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

enum DashboardPalette {
    static let allModels = Color(red: 0.36, green: 0.56, blue: 0.96)
    static let fable = Color(red: 0.96, green: 0.55, blue: 0.24)
    static let fiveHour = Color(red: 0.30, green: 0.75, blue: 0.62)
}

/// The app's main window: current limits, then charts built from the saved history.
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
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Off only for image previews, which can't draw scroll views.
    var scrolls = true

    private var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: lastSuccessAt, refreshSeconds: refreshSeconds, now: now)
    }

    private var days: [DailyUsage] {
        UsageHistoryAnalysis.daily(samples, days: range.days, endingOn: now, calendar: calendar)
    }

    private var hasFable: Bool {
        snapshot?.fableWeeklyPercent != nil || samples.contains { $0.fable != nil }
    }

    /// The limits with a card: the 5-hour and weekly limits, plus Fable when the service reports it.
    private var visibleLimits: [LimitKind] {
        LimitKind.allCases.filter { $0 != .fableWeekly || snapshot?.fableWeeklyPercent != nil }
    }

    /// Where each visible limit is heading, from the same numbers the limit cards use.
    private var forecasts: [LimitKind: ForecastOutcome] {
        Dictionary(uniqueKeysWithValues: visibleLimits.map {
            ($0, UsageForecast.make($0, snapshot: snapshot, samples: samples, now: now, isStale: isStale))
        })
    }

    var body: some View {
        if scrolls {
            ScrollView { page }
        } else {
            page
        }
    }

    private var page: some View {
        // Worked out once per redraw and shared by the forecast card and the week chart.
        let outcomes = forecasts
        return VStack(alignment: .leading, spacing: 18) {
            header
            currentLimits
            ForecastCard(rows: visibleLimits.map { kind in
                ForecastRow.make(outcomes[kind] ?? .unavailable, kind: kind, now: now, calendar: calendar)
            })
            dailyCard
            HStack(alignment: .top, spacing: 18) {
                thisWeekCard(forecasts: outcomes)
                fiveHourCard
            }
            footer
        }
        .padding(24)
    }

    // MARK: Header and current limits

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
            Button(action: onRefresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(isRefreshing)
                .keyboardShortcut("r")
            Button(action: onOpenSettings) { Label("Settings", systemImage: "gearshape") }
                .keyboardShortcut(",")
        }
    }

    @ViewBuilder
    private var currentLimits: some View {
        if let cooldown, cooldown.until > now {
            Label("Rate limited. Next try at \(cooldown.until.formatted(date: .omitted, time: .shortened)).", systemImage: "hourglass")
                .foregroundStyle(.orange)
        }
        if let error, !(cooldown.map { $0.until > now } ?? false && error.isRateLimited) {
            Label(error.message, systemImage: ProblemCause(error).symbol)
                .foregroundStyle(.orange)
        }
        HStack(spacing: 14) {
            ForEach(visibleLimits, id: \.self) { kind in
                DashboardLimitCard(display: LimitDisplay.make(kind, snapshot: snapshot, now: now, isStale: isStale), dimmed: isStale)
            }
        }
    }

    // MARK: Used per day

    private var dailyCard: some View {
        DashboardCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly limit used per day")
                        .font(.headline)
                    Text("Percentage points of your weekly limits used each day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                DailyUsageChart(days: days, showFable: hasFable, calendar: calendar)
                    .frame(height: 220)
                DailyStats(days: days, showFable: hasFable, firstReading: samples.first?.at, rangeStart: days.first?.day)
            }
        }
    }

    // MARK: This week and the five-hour session

    private func thisWeekCard(forecasts: [LimitKind: ForecastOutcome]) -> some View {
        DashboardCard {
            Text("This week")
                .font(.headline)
            if let week = UsageHistoryAnalysis.currentWeek(samples, now: now), !week.points.isEmpty {
                Text("Resets \(week.end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                WeekChart(week: week, showFable: hasFable, now: now,
                          weeklyProjection: projection(forecasts[.weekly], within: week),
                          fableProjection: projection(forecasts[.fableWeekly], within: week))
                    .frame(height: 200)
            } else {
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 200)
            }
        }
    }

    /// The dashed forecast line for one limit, or nothing when there is no forecast.
    private func projection(_ outcome: ForecastOutcome?, within week: WeekSeries) -> [SeriesPoint] {
        guard case .forecast(let forecast) = outcome else { return [] }
        return forecast.projection(now: now, within: week)
    }

    private var fiveHourCard: some View {
        DashboardCard {
            Text("5-hour session · last 24 hours")
                .font(.headline)
            let series = UsageHistoryAnalysis.recentFiveHour(samples, now: now)
            if series.isEmpty {
                EmptyHistory(isHistoryEnabled: isHistoryEnabled)
                    .frame(height: 200)
            } else {
                Text("Peak \(Int((series.map(\.value).max() ?? 0).rounded(.down)))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FiveHourChart(series: series, now: now)
                    .frame(height: 200)
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
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

struct DashboardLimitCard: View {
    let display: LimitDisplay
    let dimmed: Bool

    private var detail: String {
        [display.resetText, display.pace?.status.label].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display.percentText)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(display.color)
            }
            UsageProgressBar(utilization: display.percent ?? 0, height: 10,
                             paceFraction: display.pace?.elapsedFraction, isUnknown: display.percent == nil)
            Text(detail.isEmpty ? " " : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .opacity(dimmed || display.awaitingReset ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.kind.title), \(display.percent.map { "\($0) percent used" } ?? "not reported")"
                            + (detail.isEmpty ? "" : ", \(detail)"))
    }
}

/// "If you keep using Claude at the same pace": one row per limit with a status chip, when it runs out, and a budget.
struct ForecastCard: View {
    let rows: [ForecastRow]

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 2) {
                Text("Forecast")
                    .font(.headline)
                Text("If you keep using Claude at the same pace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.kind) { index, row in
                if index > 0 { Divider() }
                ForecastRowView(row: row)
            }
        }
    }
}

struct ForecastRowView: View {
    let row: ForecastRow

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForecastChip(status: row.status)
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

/// A small colored label: red when the limit runs out or is used up, orange when close, green when it should last.
struct ForecastChip: View {
    let status: ForecastStatus

    private var color: Color {
        switch status {
        case .runsOut, .limitReached: return .red
        case .cuttingItClose: return .orange
        case .shouldLast: return .green
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
            Text(isHistoryEnabled ? "History starts with the next reading." : "Usage history is turned off in Settings.")
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

struct DailyUsageChart: View {
    let days: [DailyUsage]
    let showFable: Bool
    let calendar: Calendar

    private var labelStride: Int { days.count > 30 ? 14 : (days.count > 14 ? 5 : 2) }

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Points", day.weeklyPoints))
                    .foregroundStyle(by: .value("Limit", "All models"))
                    .position(by: .value("Limit", "All models"))
                if showFable {
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Points", day.fablePoints))
                        .foregroundStyle(by: .value("Limit", "Fable"))
                        .position(by: .value("Limit", "Fable"))
                }
            }
        }
        .chartForegroundStyleScale(showFable
            ? ["All models": DashboardPalette.allModels, "Fable": DashboardPalette.fable]
            : ["All models": DashboardPalette.allModels])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let points = value.as(Double.self) { Text("\(Int(points))") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: labelStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .accessibilityLabel("Weekly limit percentage points used per day")
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

struct WeekChart: View {
    let week: WeekSeries
    let showFable: Bool
    let now: Date
    /// Dashed lines from now to where each limit is heading, already clipped to the week.
    var weeklyProjection: [SeriesPoint] = []
    var fableProjection: [SeriesPoint] = []

    private var hasProjection: Bool {
        !weeklyProjection.isEmpty || (showFable && !fableProjection.isEmpty)
    }

    var body: some View {
        Chart {
            LineMark(x: .value("Time", week.start), y: .value("Percent", 0), series: .value("Line", "Even pace"))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            LineMark(x: .value("Time", week.end), y: .value("Percent", 100), series: .value("Line", "Even pace"))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(week.points.filter { $0.weekly != nil }) { point in
                LineMark(x: .value("Time", point.at), y: .value("Percent", point.weekly ?? 0), series: .value("Line", "All models"))
                    .foregroundStyle(DashboardPalette.allModels)
                    .interpolationMethod(.monotone)
            }
            if showFable {
                ForEach(week.points.filter { $0.fable != nil }) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Percent", point.fable ?? 0), series: .value("Line", "Fable"))
                        .foregroundStyle(DashboardPalette.fable)
                        .interpolationMethod(.monotone)
                }
            }

            ForEach(weeklyProjection) { point in
                LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "All models forecast"))
                    .foregroundStyle(DashboardPalette.allModels.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if showFable {
                ForEach(fableProjection) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "Fable forecast"))
                        .foregroundStyle(DashboardPalette.fable.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.primary.opacity(0.35))
                .annotation(position: .top, alignment: .leading) {
                    Text("now").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: week.start...week.end)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .accessibilityLabel("Weekly and Fable percentages this week compared with an even pace"
                            + (hasProjection ? ", with dashed lines showing where they're heading" : ""))
    }
}

struct FiveHourChart: View {
    let series: [SeriesPoint]
    let now: Date

    private struct Segmented: Identifiable {
        let point: SeriesPoint
        let segment: Int
        var id: Date { point.at }
    }

    /// The line breaks where readings stop for more than 20 minutes or a session resets, so gaps aren't drawn as usage.
    private var segmented: [Segmented] {
        var segment = 0
        var previous: SeriesPoint?
        return series.map { point in
            if let previous, point.at.timeIntervalSince(previous.at) > 20 * 60 || point.value < previous.value - 15 {
                segment += 1
            }
            previous = point
            return Segmented(point: point, segment: segment)
        }
    }

    var body: some View {
        Chart {
            ForEach(segmented) { item in
                LineMark(x: .value("Time", item.point.at), y: .value("Percent", item.point.value),
                         series: .value("Session", item.segment))
                    .foregroundStyle(DashboardPalette.fiveHour)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Warning", 90))
                .foregroundStyle(Color.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("90%").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: now.addingTimeInterval(-86_400)...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .accessibilityLabel("Five-hour session percentage over the last 24 hours")
    }
}
