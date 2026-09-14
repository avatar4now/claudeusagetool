import SwiftUI

// Pure views with no live state, so they can be rendered and checked in isolation.

/// The icon and five-hour percent shown in the menu bar.
struct MenuBarLabel: View {
    let snapshot: UsageSnapshot?
    let error: UsageError?

    var body: some View {
        let symbol = (snapshot == nil && error != nil) ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent"
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(UsageFormatting.menuBarTitle(for: snapshot))
                .monospacedDigit()
        }
    }
}

/// The panel that opens when you click the menu bar item.
struct UsageMenuContent: View {
    let report: UsageReport?
    let error: UsageError?
    let lastUpdated: Date?
    let isRefreshing: Bool
    let refreshSeconds: Int
    let version: String
    var onChangeRefreshInterval: (Int) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if let lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = report?.snapshot {
                MenuUsageRow(title: "5-hour session", percent: snapshot.fiveHourPercent,
                             resetsAt: snapshot.fiveHourResetsAt)
                MenuUsageRow(title: "Weekly · all models", percent: snapshot.weeklyPercent,
                             resetsAt: snapshot.weeklyResetsAt)
                if snapshot.fableWeeklyPercent != nil {
                    MenuUsageRow(title: "Weekly · Fable", percent: snapshot.fableWeeklyPercent,
                                 resetsAt: snapshot.fableWeeklyResetsAt)
                }
            } else if error == nil {
                Text("Loading usage…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Refresh every", selection: Binding(get: { refreshSeconds }, set: onChangeRefreshInterval)) {
                ForEach(RefreshSchedule.choices, id: \.self) { seconds in
                    Text(RefreshSchedule.label(for: seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)

            Divider()

            HStack {
                Button("Refresh", action: onRefresh)
                    .disabled(isRefreshing)
                Button("Settings…", action: onOpenSettings)
                Spacer()
                Button("Quit", action: onQuit)
            }

            Text(version)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 290)
    }
}

struct MenuUsageRow: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        let whole = UsageFormatting.wholePercent(percent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(UsageFormatting.percentText(percent))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(whole.map { Color.usageColor(for: $0) } ?? Color.secondary)
            }
            UsageProgressBar(utilization: whole ?? 0, height: 6)
            if let reset = UsageFormatting.resetText(until: resetsAt) {
                Text(reset == "now" ? "Resetting now" : "Resets in \(reset)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
