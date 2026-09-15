import AppKit
import SwiftUI

/// Connects the dashboard to the live monitor and loads the saved history.
struct Dashboard: View {
    @ObservedObject var monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dashboardRange") private var rangeRaw = HistoryRange.twoWeeks.rawValue
    @State private var samples: [UsageSample] = []

    var body: some View {
        // Redraw every minute so "now", countdowns, and pace move between fetches.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            DashboardContent(
                snapshot: monitor.snapshot,
                lastSuccessAt: monitor.lastSuccessAt,
                error: monitor.error,
                cooldown: monitor.cooldown,
                isRefreshing: monitor.isRefreshing,
                refreshSeconds: monitor.refreshSeconds,
                samples: samples,
                isHistoryEnabled: monitor.isHistoryEnabled,
                now: context.date,
                range: Binding(get: { HistoryRange(rawValue: rangeRaw) ?? .twoWeeks }, set: { rangeRaw = $0.rawValue }),
                onRefresh: { Task { await monitor.refresh(trigger: .manual) } },
                onOpenSettings: { openWindow(id: AppWindow.settings) }
            )
        }
        .frame(minWidth: 860, minHeight: 640, idealHeight: 860)
        .task(id: monitor.historyRevision) {
            samples = monitor.history.load(now: Date())
        }
        .onAppear { WindowPresence.opened() }
        .onDisappear { WindowPresence.closed() }
    }
}
