import SwiftUI

// Pure views with no live state, so they can be rendered and checked in isolation.

/// The symbol and headline shown in the menu bar, such as "F 94%".
struct MenuBarLabel: View {
    let headline: Headline
    let isStale: Bool
    /// True when there are no numbers to show because something is wrong.
    let hasProblem: Bool

    var symbol: String {
        if hasProblem { return "exclamationmark.triangle" }
        if headline.hiddenLimitWarning { return "exclamationmark.triangle.fill" }
        if isStale { return "clock.badge.exclamationmark" }
        return "gauge.with.dots.needle.33percent"
    }

    var accessibilityText: String {
        var parts = ["Claude usage"]
        if let limit = headline.limit {
            parts.append("\(limit.title), \(headline.text.split(separator: " ").last.map(String.init) ?? "")")
        }
        if headline.hiddenLimitWarning { parts.append("another limit is above 90 percent") }
        if isStale { parts.append("data is out of date") }
        if hasProblem { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(headline.text)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// The panel that opens when you click the menu bar item.
struct UsageMenuContent: View {
    let snapshot: UsageSnapshot?
    let lastSuccessAt: Date?
    let error: UsageError?
    let cooldown: Cooldown?
    let isRefreshing: Bool
    let refreshSeconds: Int
    let version: String
    let now: Date
    var onChangeRefreshInterval: (Int) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    private var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: lastSuccessAt, refreshSeconds: refreshSeconds, now: now)
    }

    private var activeCooldown: Cooldown? {
        guard let cooldown, cooldown.until > now else { return nil }
        return cooldown
    }

    private var visibleLimits: [LimitKind] {
        LimitKind.allCases.filter { $0 != .fableWeekly || snapshot?.fableWeeklyPercent != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if let lastSuccessAt {
                    Text("\(isStale ? "Data from" : "Updated") \(lastSuccessAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(isStale ? Color.orange : Color.secondary)
                }
            }

            if let activeCooldown {
                Label("Rate limited. Next try at \(activeCooldown.until.formatted(date: .omitted, time: .shortened)).",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if snapshot != nil {
                ForEach(visibleLimits, id: \.self) { kind in
                    MenuUsageRow(display: LimitDisplay.make(kind, snapshot: snapshot, now: now, isStale: isStale),
                                 dimmed: isStale)
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
                    .keyboardShortcut("r")
                Button("Settings…", action: onOpenSettings)
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q")
            }

            Text(version)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct MenuUsageRow: View {
    let display: LimitDisplay
    let dimmed: Bool

    private var detail: String {
        [display.resetText, display.pace?.status.label].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.kind.title)
                    .font(.callout)
                Spacer()
                Text(display.percentText)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(display.color)
            }
            UsageProgressBar(utilization: display.percent ?? 0, height: 6,
                             paceFraction: display.pace?.elapsedFraction, isUnknown: display.percent == nil)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed || display.awaitingReset ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.kind.title), \(display.percent.map { "\($0) percent used" } ?? "not reported")"
                            + (detail.isEmpty ? "" : ", \(detail)"))
    }
}
