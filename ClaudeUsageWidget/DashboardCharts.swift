import Charts
import SwiftUI

// The dashboard's charts. Each keeps its own hover state, so moving the pointer redraws only that chart.

/// One line in a chart's hover box.
struct CalloutLine: Hashable {
    var color: Color?
    var text: String
}

/// The small box that explains the point under the pointer.
struct ChartCallout: View {
    let title: String
    let lines: [CalloutLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(lines, id: \.self) { line in
                HStack(spacing: 5) {
                    if let color = line.color {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                    Text(line.text)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        )
    }
}

/// A row of colored dots and names, for charts whose colors aren't explained elsewhere.
struct ChartKey: View {
    let items: [CalloutLine]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Circle().fill(item.color ?? .secondary).frame(width: 7, height: 7)
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A soft fill that fades toward the bottom, used under chart lines.
private func fade(_ color: Color) -> LinearGradient {
    LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
}

// MARK: - Weekly limit used per day

struct DailyUsageChart: View {
    let days: [DailyUsage]
    let showFable: Bool
    let calendar: Calendar
    var palette: Palette = ColorTheme.classic.palette
    /// When the weekly limit reset inside the range, drawn as thin dashed lines.
    var resets: [Date] = []
    @State private var selection: Date?

    private var labelStride: Int { days.count > 30 ? 14 : (days.count > 14 ? 5 : 2) }

    /// The average across days with readings, or nil when there's nothing to average.
    private var average: Double? {
        let tracked = days.filter(\.hasReadings)
        guard !tracked.isEmpty else { return nil }
        let value = tracked.map(\.weeklyPoints).reduce(0, +) / Double(tracked.count)
        return value > 0 ? value : nil
    }

    private var selectedDay: DailyUsage? {
        guard let selection else { return nil }
        return days.first { calendar.isDate($0.day, inSameDayAs: selection) }
    }

    var body: some View {
        let selected = selectedDay
        Chart {
            ForEach(days) { day in
                let faded = selected != nil && selected?.day != day.day
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Points", day.weeklyPoints))
                    .foregroundStyle(by: .value("Limit", "All models"))
                    .position(by: .value("Limit", "All models"))
                    .cornerRadius(3)
                    .opacity(faded ? 0.35 : 1)
                if showFable {
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Points", day.fablePoints))
                        .foregroundStyle(by: .value("Limit", "Fable"))
                        .position(by: .value("Limit", "Fable"))
                        .cornerRadius(3)
                        .opacity(faded ? 0.35 : 1)
                }
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("avg \(Int(average.rounded())) pts")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            ForEach(resets, id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("reset")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
            if let day = selected {
                RuleMark(x: .value("Day", day.day, unit: .day))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: day.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                     lines: calloutLines(for: day))
                    }
            }
        }
        .chartXSelection(value: $selection)
        .chartForegroundStyleScale(showFable
            ? ["All models": palette.allModels.color, "Fable": palette.fable.color]
            : ["All models": palette.allModels.color])
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

    private func calloutLines(for day: DailyUsage) -> [CalloutLine] {
        guard day.hasReadings else { return [CalloutLine(color: nil, text: "No readings")] }
        var lines = [CalloutLine(color: palette.allModels.color, text: "All models · \(Int(day.weeklyPoints.rounded())) pts")]
        if showFable {
            lines.append(CalloutLine(color: palette.fable.color, text: "Fable · \(Int(day.fablePoints.rounded())) pts"))
        }
        if let peak = day.peakFiveHour {
            lines.append(CalloutLine(color: palette.fiveHour.color, text: "5-hour peak · \(Int(peak.rounded(.down)))%"))
        }
        if day.includesTimeAppWasClosed {
            lines.append(CalloutLine(color: nil, text: "Includes time the app was closed"))
        }
        return lines
    }
}

// MARK: - This week

struct WeekChart: View {
    let week: WeekSeries
    let showFable: Bool
    let now: Date
    var appearance: Appearance = .standard
    /// Dashed lines from now to where each limit is heading, already clipped to the week.
    var weeklyProjection: [SeriesPoint] = []
    var fableProjection: [SeriesPoint] = []
    @State private var selection: Date?

    private var palette: Palette { appearance.palette }

    /// Each line without the readings in the middle of flat stretches: the same shape with far fewer marks.
    private var weeklySeries: [SeriesPoint] {
        UsageHistoryAnalysis.withoutFlatMiddles(week.points.compactMap { point in point.weekly.map { SeriesPoint(at: point.at, value: $0) } })
    }
    private var fableSeries: [SeriesPoint] {
        guard showFable else { return [] }
        return UsageHistoryAnalysis.withoutFlatMiddles(week.points.compactMap { point in point.fable.map { SeriesPoint(at: point.at, value: $0) } })
    }

    /// "used" is spelled out when the rest of the app shows what's left, so the two can't be confused.
    private var usedSuffix: String { appearance.numbers == .left ? " used" : "" }

    private var hasProjection: Bool {
        !weeklyProjection.isEmpty || (showFable && !fableProjection.isEmpty)
    }

    /// The reading closest to the pointer.
    private var selectedPoint: WeekPoint? {
        guard let selection else { return nil }
        return week.points.min { abs($0.at.timeIntervalSince(selection)) < abs($1.at.timeIntervalSince(selection)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartKey(items: [CalloutLine(color: palette.allModels.color, text: "All models")]
                     + (showFable ? [CalloutLine(color: palette.fable.color, text: "Fable")] : [])
                     + (appearance.showPaceGuides ? [CalloutLine(color: .secondary, text: "Even pace")] : []))
            chart
        }
    }

    private var chart: some View {
        let weeklyPoints = weeklySeries
        let fablePoints = fableSeries
        return Chart {
            if appearance.showPaceGuides {
                LineMark(x: .value("Time", week.start), y: .value("Percent", 0), series: .value("Line", "Even pace"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                LineMark(x: .value("Time", week.end), y: .value("Percent", 100), series: .value("Line", "Even pace"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            ForEach(weeklyPoints) { point in
                if appearance.shadeCharts {
                    AreaMark(x: .value("Time", point.at), y: .value("Percent", point.value),
                             series: .value("Area", "All models"), stacking: .unstacked)
                        .foregroundStyle(fade(palette.allModels.color))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "All models"))
                    .foregroundStyle(palette.allModels.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
            }
            ForEach(fablePoints) { point in
                if appearance.shadeCharts {
                    AreaMark(x: .value("Time", point.at), y: .value("Percent", point.value),
                             series: .value("Area", "Fable"), stacking: .unstacked)
                        .foregroundStyle(fade(palette.fable.color))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "Fable"))
                    .foregroundStyle(palette.fable.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
            }

            ForEach(weeklyProjection) { point in
                LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "All models forecast"))
                    .foregroundStyle(palette.allModels.color.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if showFable {
                ForEach(fableProjection) { point in
                    LineMark(x: .value("Time", point.at), y: .value("Percent", point.value), series: .value("Line", "Fable forecast"))
                        .foregroundStyle(palette.fable.color.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }

            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.primary.opacity(0.3))
                .annotation(position: .top, alignment: .leading) {
                    Text("now").font(.caption2).foregroundStyle(.secondary)
                }

            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.at))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: point.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                                     lines: calloutLines(for: point))
                    }
                if let weekly = point.weekly {
                    PointMark(x: .value("Time", point.at), y: .value("Percent", weekly))
                        .foregroundStyle(palette.allModels.color)
                        .symbolSize(40)
                }
                if showFable, let fable = point.fable {
                    PointMark(x: .value("Time", point.at), y: .value("Percent", fable))
                        .foregroundStyle(palette.fable.color)
                        .symbolSize(40)
                }
            }
        }
        .chartXSelection(value: $selection)
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
        .accessibilityLabel("Weekly and Fable percentages this week"
                            + (appearance.showPaceGuides ? " compared with an even pace" : "")
                            + (hasProjection ? ", with dashed lines showing where they're heading" : ""))
    }

    private func calloutLines(for point: WeekPoint) -> [CalloutLine] {
        var lines: [CalloutLine] = []
        if let weekly = point.weekly {
            lines.append(CalloutLine(color: palette.allModels.color, text: "All models · \(Int(weekly.rounded(.down)))%\(usedSuffix)"))
        }
        if showFable, let fable = point.fable {
            lines.append(CalloutLine(color: palette.fable.color, text: "Fable · \(Int(fable.rounded(.down)))%\(usedSuffix)"))
        }
        if appearance.showPaceGuides {
            let elapsed = point.at.timeIntervalSince(week.start) / week.end.timeIntervalSince(week.start)
            lines.append(CalloutLine(color: .secondary, text: "Even pace · \(Int((min(max(elapsed, 0), 1) * 100).rounded()))%"))
        }
        return lines
    }
}

// MARK: - The five-hour session

struct FiveHourChart: View {
    let series: [SeriesPoint]
    let now: Date
    var appearance: Appearance = .standard
    @State private var selection: Date?

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

    private var selectedPoint: SeriesPoint? {
        guard let selection else { return nil }
        return series.min { abs($0.at.timeIntervalSince(selection)) < abs($1.at.timeIntervalSince(selection)) }
    }

    var body: some View {
        let color = appearance.palette.fiveHour.color
        let warning = appearance.redAt
        Chart {
            ForEach(segmented) { item in
                if appearance.shadeCharts {
                    AreaMark(x: .value("Time", item.point.at), y: .value("Percent", item.point.value),
                             series: .value("Session", item.segment), stacking: .unstacked)
                        .foregroundStyle(fade(color))
                }
                LineMark(x: .value("Time", item.point.at), y: .value("Percent", item.point.value),
                         series: .value("Session", item.segment))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Warning", warning))
                .foregroundStyle(appearance.palette.alert.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("\(warning)%").font(.caption2).foregroundStyle(.secondary)
                }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.at))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: point.at.formatted(date: .omitted, time: .shortened),
                                     lines: [CalloutLine(color: color, text: "5-hour · \(Int(point.value.rounded(.down)))%"
                                                             + (appearance.numbers == .left ? " used" : ""))])
                    }
                PointMark(x: .value("Time", point.at), y: .value("Percent", point.value))
                    .foregroundStyle(color)
                    .symbolSize(40)
            }
        }
        .chartXSelection(value: $selection)
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

// MARK: - When you use Claude

/// A grid of weekdays by hours, stronger where more of the weekly limit was used. Hover a square for its total.
struct RhythmChart: View {
    let cells: [RhythmCell]
    let calendar: Calendar
    let color: Color
    /// Which square the pointer is over, by position, so a new reading in that hour doesn't lose the hover.
    @State private var hoveredID: Int?

    /// Weekdays in the order this Mac's calendar starts its week.
    private var weekdays: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    private func dayName(_ weekday: Int) -> String {
        calendar.shortWeekdaySymbols[weekday - 1]
    }

    private func hourName(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour())
    }

    private var busiest: RhythmCell? {
        cells.max { $0.points < $1.points }.flatMap { $0.points > 0 ? $0 : nil }
    }

    /// Empty hours are faint; used hours go from light to full color. The square root keeps small hours visible.
    private func fill(_ points: Double, most: Double) -> Color {
        points > 0 ? color.opacity(0.22 + 0.78 * (points / most).squareRoot()) : Color.primary.opacity(0.06)
    }

    var body: some View {
        let most = max(cells.map(\.points).max() ?? 0, 0.001)
        let lookup = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").font(.caption2).foregroundStyle(.tertiary)
                    ForEach([0, 0.1, 0.35, 0.65, 1.0], id: \.self) { share in
                        RoundedRectangle(cornerRadius: 2).fill(fill(share * most, most: most)).frame(width: 11, height: 11)
                    }
                    Text("More").font(.caption2).foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            }
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(weekdays, id: \.self) { weekday in
                    GridRow {
                        Text(dayName(weekday))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let cell = lookup[RhythmCell.key(weekday: weekday, hour: hour)]
                                ?? RhythmCell(weekday: weekday, hour: hour, points: 0)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(fill(cell.points, most: most))
                                .frame(maxWidth: .infinity)
                                .frame(height: 20)
                                .overlay {
                                    if hoveredID == cell.id {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
                                    }
                                }
                                .onHover { inside in
                                    if inside {
                                        hoveredID = cell.id
                                    } else if hoveredID == cell.id {
                                        hoveredID = nil
                                    }
                                }
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 36, height: 1)
                    ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
                        Text(hourName(hour))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridCellColumns(3)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(busiest.map { "Busiest hour: \(dayName($0.weekday)) \(hourName($0.hour))" } ?? "No usage recorded yet")
    }

    private var summary: String {
        if let hoveredID, let hovered = cells.first(where: { $0.id == hoveredID }) {
            return "\(dayName(hovered.weekday)) \(hourName(hovered.hour)) · \(Int(hovered.points.rounded())) pts"
        }
        if let busiest {
            return "Busiest hour: \(dayName(busiest.weekday)) \(hourName(busiest.hour)) · \(Int(busiest.points.rounded())) pts"
        }
        return " "
    }
}

// MARK: - Trend line for a limit card

/// A tiny line of one limit through its current window, from the window's start to its reset.
struct Sparkline: View {
    let points: [SeriesPoint]
    let start: Date
    let end: Date
    let color: Color
    /// Draw what's left instead of what's used, to match a card that shows "left".
    var showsLeft = false
    var shaded = true

    var body: some View {
        Chart(points) { point in
            let value = showsLeft ? max(0, 100 - point.value) : point.value
            if shaded {
                AreaMark(x: .value("Time", point.at), y: .value("Percent", value))
                    .foregroundStyle(fade(color))
                    .interpolationMethod(.monotone)
            }
            LineMark(x: .value("Time", point.at), y: .value("Percent", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}
