import SwiftUI

@main
struct ClaudeUsageWidgetApp: App {
    /// One monitor feeds both the menu bar and the settings window.
    @StateObject private var monitor = UsageMonitor()
    @StateObject private var loginItem = LoginItemController()

    var body: some Scene {
        Window("Claude Usage Widget", id: AppWindow.settings) {
            ContentView(monitor: monitor, loginItem: loginItem)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(AppLaunch.showsSettingsAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            UsageMenu(monitor: monitor)
        } label: {
            // monitor.clock ticks every 30 seconds, so staleness and reset state here stay current between fetches.
            let _ = monitor.clock
            MenuBarLabel(headline: monitor.headline,
                         isStale: monitor.isStale,
                         hasProblem: monitor.snapshot == nil && monitor.error != nil)
        }
        .menuBarExtraStyle(.window)
    }
}
