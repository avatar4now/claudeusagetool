import SwiftUI
import AppKit

/// Connects the menu bar panel to the live monitor and the app's windows.
struct UsageMenu: View {
    @ObservedObject var monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        UsageMenuContent(
            report: monitor.report,
            error: monitor.error,
            lastUpdated: monitor.lastUpdated,
            isRefreshing: monitor.isRefreshing,
            refreshSeconds: monitor.refreshSeconds,
            version: AppVersion.display,
            onChangeRefreshInterval: { monitor.setRefreshInterval($0) },
            onRefresh: { Task { await monitor.refresh() } },
            onOpenSettings: {
                openWindow(id: AppWindow.settings)
                NSApplication.shared.activate()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }
}
