import AppKit
import SwiftUI

/// Connects the menu bar panel to the live monitor and the app's windows.
struct UsageMenu: View {
    @ObservedObject var monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Redraw every 30 seconds so countdowns, pace ticks, and stale labels stay current between fetches.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            UsageMenuContent(
                snapshot: monitor.snapshot,
                lastSuccessAt: monitor.lastSuccessAt,
                error: monitor.error,
                cooldown: monitor.cooldown,
                isRefreshing: monitor.isRefreshing,
                refreshSeconds: monitor.refreshSeconds,
                version: AppVersion.display,
                now: context.date,
                onChangeRefreshInterval: { monitor.setRefreshInterval($0) },
                onRefresh: { Task { await monitor.refresh(trigger: .manual) } },
                onOpenSettings: {
                    openWindow(id: AppWindow.settings)
                    NSApplication.shared.activate()
                },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        }
    }
}
