import SwiftUI

@main
struct ClaudeUsageWidgetApp: App {
    /// One monitor feeds both the menu bar and the settings window.
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        Window("Claude Usage Widget", id: AppWindow.settings) {
            ContentView(monitor: monitor)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            UsageMenu(monitor: monitor)
        } label: {
            MenuBarLabel(snapshot: monitor.report?.snapshot, error: monitor.error)
        }
        .menuBarExtraStyle(.window)
    }
}
