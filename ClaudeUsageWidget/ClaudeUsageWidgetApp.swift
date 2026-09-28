import AppKit
import SwiftUI

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One monitor feeds the menu bar, the dashboard, and Settings.
    @StateObject private var monitor = UsageMonitor()
    @StateObject private var loginItem = LoginItemController()
    /// Watches GitHub for a newer version of this copy.
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        // The first window is the one macOS reopens when you open the app while it's already running.
        Window("Claude Usage", id: AppWindow.dashboard) {
            Dashboard(monitor: monitor)
        }
        .defaultSize(width: 940, height: 960)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(AppLaunch.needsSetup ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window("Settings", id: AppWindow.settings) {
            SettingsView(monitor: monitor, loginItem: loginItem, updates: updates)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Set Up Claude Usage", id: AppWindow.setup) {
            SetupAssistant(monitor: monitor, loginItem: loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppLaunch.needsSetup ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            UsageMenu(monitor: monitor, updates: updates)
        } label: {
            // monitor.clock ticks every 30 seconds, so staleness and reset state here stay current between fetches.
            let _ = monitor.clock
            let headline = monitor.headline
            MenuBarLabel(headline: headline,
                         isStale: monitor.isStale,
                         problem: monitor.snapshot == nil ? monitor.error.map { ProblemCause($0) } : nil,
                         appearance: monitor.appearance,
                         display: headline.limit.map {
                             LimitDisplay.make($0, snapshot: monitor.snapshot, now: monitor.clock, isStale: monitor.isStale,
                                               appearance: monitor.appearance)
                         },
                         now: monitor.clock)
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
