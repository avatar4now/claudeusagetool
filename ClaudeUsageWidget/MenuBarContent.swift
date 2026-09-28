import SwiftUI

// Pure views with no live state, so they can be rendered and checked in isolation.

/// The picture and text shown in the menu bar, such as a gauge and "F 94%", or a colored ring and "5h 22% ⚠︎F".
struct MenuBarLabel: View {
    let headline: Headline
    let isStale: Bool
    /// Why there are no numbers to show, or nil when there are numbers (or nothing is wrong).
    let problem: ProblemCause?
    var appearance: Appearance = .standard
    /// The shown limit, drawn with the chosen look. The ring uses its fill and color.
    var display: LimitDisplay? = nil
    var now: Date = Date()

    enum Icon: Equatable {
        case symbol(String)
        case ring
        case none
    }

    /// Problems, old data, and a passed reset always show their own symbol, whatever style is chosen, so they're
    /// never hidden. The menu bar draws only the first image in a label, so a nearly full limit that isn't shown is
    /// flagged in the text instead.
    var icon: Icon {
        if let problem { return .symbol(problem.symbol) }
        if isStale { return .symbol("clock.badge.exclamationmark") }
        if headline.awaitingReset { return .symbol("arrow.clockwise") }
        let used = headline.percent ?? 0
        switch appearance.menuBarIcon {
        case .status: return .symbol("gauge.with.dots.needle.33percent")
        case .gauge: return .symbol(MenuBarSymbols.gauge(percentUsed: used))
        case .battery: return .symbol(MenuBarSymbols.battery(percentUsed: used))
        case .ring: return display?.percent == nil ? .symbol("gauge.with.dots.needle.33percent") : .ring
        case .none: return .none
        }
    }

    var text: String { headline.menuBarText(appearance, now: now) }

    var accessibilityText: String {
        var parts = ["Claude usage"]
        if let limit = headline.limit {
            parts.append("\(limit.title), \(appearance.percentText(UsageFormatting.wholePercent(headline.percent)))"
                         + (appearance.numbers == .used ? " used" : ""))
        }
        if let warning = headline.hiddenWarningSummary { parts.append(warning) }
        if headline.awaitingReset { parts.append("waiting to confirm the reset") }
        if isStale { parts.append("data is out of date") }
        if let problem { parts.append(problem.title) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 4) {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
            case .ring:
                Image(nsImage: MenuBarRing.image(fraction: display?.barFraction ?? 0, tint: display?.tint))
            case .none:
                EmptyView()
            }
            if !text.isEmpty {
                Text(text)
                    .monospacedDigit()
            }
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
    var appearance: Appearance = .standard
    /// True when no account is connected yet.
    var needsSetup = false
    var onSetUp: () -> Void = {}
    /// A newer version published on GitHub, if there is one.
    var updateVersion: String? = nil
    var onShowUpdate: () -> Void = {}
    var onChangeRefreshInterval: (Int) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onOpenDashboard: () -> Void = {}
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
            }
            // A newer problem (for example after a manual retry during a long wait) is shown alongside the cooldown.
            if let error, !needsSetup, !(activeCooldown != nil && error.isRateLimited) {
                Label(error.message, systemImage: ProblemCause(error).symbol)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if needsSetup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your Claude account to see your limits here.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up…", action: onSetUp)
                        .buttonStyle(.borderedProminent)
                }
            } else if snapshot != nil {
                ForEach(visibleLimits, id: \.self) { kind in
                    MenuUsageRow(display: LimitDisplay.make(kind, snapshot: snapshot, now: now, isStale: isStale,
                                                            appearance: appearance),
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

            HStack(spacing: 6) {
                Button("Refresh", action: onRefresh)
                    .disabled(isRefreshing)
                    .keyboardShortcut("r")
                Button("Dashboard", action: onOpenDashboard)
                    .keyboardShortcut("d")
                Button("Settings…", action: onOpenSettings)
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q")
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                Text(version)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let updateVersion {
                    Spacer()
                    Button(action: onShowUpdate) {
                        Label("Version \(updateVersion) is available", systemImage: "arrow.down.circle.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.link)
                }
            }
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
                    .contentTransition(.numericText(value: Double(display.percent ?? 0)))
                    .animation(.snappy, value: display.percent)
            }
            UsageProgressBar(display: display, height: 6)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed || display.awaitingReset ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.kind.title), \(display.percent == nil ? "not reported" : display.percentText.replacingOccurrences(of: "%", with: " percent") + (display.appearance.numbers == .used ? " used" : ""))"
                            + (detail.isEmpty ? "" : ", \(detail)"))
    }
}
