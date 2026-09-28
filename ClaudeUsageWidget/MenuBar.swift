import AppKit
import SwiftUI

/// Connects the menu bar panel to the live monitor and the app's windows.
struct UsageMenu: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.account.rawValue

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
                version: AppVersion.current.shortText,
                now: context.date,
                appearance: monitor.appearance,
                needsSetup: !monitor.hasCredentials,
                onSetUp: {
                    openWindow(id: AppWindow.setup)
                    NSApplication.shared.activate()
                },
                updateVersion: updates.available?.version,
                onShowUpdate: {
                    settingsTab = SettingsTab.about.rawValue
                    openWindow(id: AppWindow.settings)
                    NSApplication.shared.activate()
                },
                onChangeRefreshInterval: { monitor.setRefreshInterval($0) },
                onRefresh: { Task { await monitor.refresh(trigger: .manual) } },
                onOpenDashboard: {
                    openWindow(id: AppWindow.dashboard)
                    NSApplication.shared.activate()
                },
                onOpenSettings: {
                    openWindow(id: AppWindow.settings)
                    NSApplication.shared.activate()
                },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        }
    }
}
