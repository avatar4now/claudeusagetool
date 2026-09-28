import AppKit
import KeyboardShortcuts
import SwiftUI
import os

/// Logs outcomes only.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "hotkeys")

extension KeyboardShortcuts.Name {
    /// Opens the dashboard from any app. There's no default; people choose their own in Settings → General.
    static let showDashboard = Self("showDashboard")
}

/// Listens for the global shortcut while the app runs, and opens the dashboard when it's pressed.
/// KeyboardShortcuts registers only the chosen key combination with macOS; it doesn't watch other typing.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    /// The ability to open windows, borrowed from the first view that appears.
    fileprivate var openWindow: OpenWindowAction?

    private init() {
        KeyboardShortcuts.onKeyUp(for: .showDashboard) { [weak self] in
            self?.showDashboard()
        }
    }

    /// Called once at launch, so the shortcut works before any window has opened.
    func start() {}

    func showDashboard() {
        NSApplication.shared.activate()
        if let openWindow {
            openWindow(id: AppWindow.dashboard)
        } else if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == AppWindow.dashboard }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            logger.error("The dashboard shortcut was pressed before any view could open windows")
        }
    }
}

extension View {
    /// Lets the global shortcut open the dashboard, using this view's ability to open windows.
    func enablesDashboardShortcut() -> some View {
        modifier(DashboardShortcutAnchor())
    }
}

private struct DashboardShortcutAnchor: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            if Hotkeys.shared.openWindow == nil { logger.notice("Dashboard shortcut is ready") }
            Hotkeys.shared.openWindow = openWindow
        }
    }
}
