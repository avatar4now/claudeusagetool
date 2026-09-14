import Combine
import Foundation
import Security
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "menubar")

/// Fetches usage on the chosen interval while the app runs, and hands every result to the widget.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var report: UsageReport?
    @Published private(set) var error: UsageError?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshSeconds: Int

    let store: KeychainCredentialStore
    private let sharedState: KeychainUsageStateStore
    private var lastSuccessAt: Date?
    private var lastPublished: SharedUsageState?
    private var refreshesInFlight = 0
    private var loop: Task<Void, Never>?

    private static let refreshDefaultsKey = "refreshSeconds"

    init() {
        store = .forThisApp
        sharedState = .forThisApp
        refreshSeconds = RefreshSchedule.sanitized(UserDefaults.standard.object(forKey: Self.refreshDefaultsKey) as? Int)
        // A fresh launch may be a new build, so ask WidgetKit to redraw the widget with it.
        WidgetCenter.shared.reloadAllTimelines()
        startLoop(refreshFirst: true)
    }

    /// Changes how often both the menu bar and the widget refresh.
    func setRefreshInterval(_ seconds: Int) {
        let value = RefreshSchedule.sanitized(seconds)
        guard value != refreshSeconds else { return }
        refreshSeconds = value
        UserDefaults.standard.set(value, forKey: Self.refreshDefaultsKey)
        logger.notice("Refresh interval set to \(value, privacy: .public) seconds")
        publishToWidget(snapshot: report?.snapshot, fetchedAt: lastSuccessAt)
        startLoop(refreshFirst: false)
    }

    /// Loads credentials from the keychain, fetches usage, and publishes the result.
    @discardableResult
    func refresh() async -> Result<UsageReport, UsageError> {
        refreshesInFlight += 1
        isRefreshing = true
        let result = await loadAndFetch()
        refreshesInFlight -= 1
        isRefreshing = refreshesInFlight > 0
        lastUpdated = Date()

        switch result {
        case .success(let newReport):
            report = newReport
            error = nil
            lastSuccessAt = Date()
            logger.notice("Refresh succeeded via \(String(describing: newReport.route), privacy: .public)")
            publishToWidget(snapshot: newReport.snapshot, fetchedAt: lastSuccessAt)
        case .failure(let failure):
            if !RefreshPolicy.keepsLastReport(after: failure) {
                report = nil
                lastSuccessAt = nil
                publishToWidget(snapshot: nil, fetchedAt: nil)
            }
            error = failure
            logger.error("Refresh failed: \(failure.message, privacy: .public)")
        }
        return result
    }

    private func loadAndFetch() async -> Result<UsageReport, UsageError> {
        let config: WidgetConfig
        do {
            guard let stored = try store.load(), !stored.isEmpty else { return .failure(.noCredentials) }
            config = stored
        } catch let failure {
            return .failure(failure as? UsageError ?? .keychain(errSecInternalComponent))
        }
        return await UsageFetcher.live.fetch(config: config)
    }

    private func startLoop(refreshFirst: Bool) {
        loop?.cancel()
        let interval = Duration.seconds(refreshSeconds)
        loop = Task { [weak self] in
            if !refreshFirst { try? await Task.sleep(for: interval) }
            while !Task.isCancelled {
                guard let monitor = self else { return }
                await monitor.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Shares the latest numbers with the widget, then asks it to redraw. Skips the write when nothing changed.
    private func publishToWidget(snapshot: UsageSnapshot?, fetchedAt: Date?) {
        let state = SharedUsageState(refreshSeconds: refreshSeconds, snapshot: snapshot, fetchedAt: fetchedAt)
        guard state != lastPublished else { return }
        do {
            try sharedState.save(state)
            lastPublished = state
            WidgetCenter.shared.reloadAllTimelines()
        } catch let failure {
            let message = (failure as? UsageError)?.message ?? "unknown error"
            logger.error("Couldn't share usage with the widget: \(message, privacy: .public)")
        }
    }
}

enum AppBundle {
    /// The widget extension embedded in this app. It is the only other program allowed to read the keychain items.
    static var widgetExtensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/ClaudeUsageWidgetExtension.appex")
    }
}

extension KeychainCredentialStore {
    static var forThisApp: KeychainCredentialStore {
        KeychainCredentialStore(trustedBundleURLs: [AppBundle.widgetExtensionURL])
    }
}

extension KeychainUsageStateStore {
    static var forThisApp: KeychainUsageStateStore {
        KeychainUsageStateStore(trustedBundleURLs: [AppBundle.widgetExtensionURL])
    }
}

enum AppWindow {
    static let settings = "settings"
}

enum AppVersion {
    /// Like "Version 1.2 (2)", read from the built app so it always matches what is running.
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
