import AppKit
import SwiftUI

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One monitor feeds the menu bar, the dashboard, and Settings.
    @StateObject private var monitor = UsageMonitor()
    @StateObject private var loginItem = LoginItemController()

    var body: some Scene {
        // The first window is the one macOS reopens when you open the app while it's already running.
        Window("Claude Usage", id: AppWindow.dashboard) {
            Dashboard(monitor: monitor)
        }
        .defaultSize(width: 940, height: 960)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(AppLaunch.showsSettingsAtLaunch ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window("Settings", id: AppWindow.settings) {
            SettingsView(monitor: monitor, loginItem: loginItem)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS marks the launch event when an app starts as a login item.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starting at login stays quiet: just the menu bar item, no dashboard window.
        guard launchedAsLoginItem else { return }
        DispatchQueue.main.async {
            NSApplication.shared.windows.filter { $0.isVisible && $0.canBecomeMain }.forEach { $0.close() }
        }
    }
}
