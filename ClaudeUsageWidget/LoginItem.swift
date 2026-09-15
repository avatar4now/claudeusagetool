import Combine
import Darwin
import Foundation
import ServiceManagement

/// The "Open at login" setting, backed by macOS's own login items list.
@MainActor
final class LoginItemController: ObservableObject {
    enum State: Equatable {
        case on
        case needsApproval
        case off
        case unavailable
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    /// Login items remember the app's location, so only the copy installed by scripts/update-app.sh should register.
    var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        var homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if let passwd = getpwuid(getuid()) {
            homePath = String(cString: passwd.pointee.pw_dir)
        }
        return path.hasPrefix("/Applications/") || path.hasPrefix(homePath + "/Applications/")
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notRegistered: state = .off
        case .notFound: state = .unavailable
        @unknown default: state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
