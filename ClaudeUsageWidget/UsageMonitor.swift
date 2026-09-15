import Combine
import Foundation
import Security
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "menubar")

enum RefreshTrigger: String {
    case automatic
    case manual
    case connectionTest
}

/// Fetches usage while the app runs, hands every result to the widget, and decides when the next request may go out.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// When the numbers on screen were fetched. A failed attempt never moves this.
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var error: UsageError?
    @Published private(set) var cooldown: Cooldown?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshSeconds: Int
    @Published private(set) var menuBarMetric: MenuBarMetric

    let store: KeychainCredentialStore
    private let sharedState: KeychainUsageStateStore
    private var generation: String?
    private var consecutiveRateLimits = 0
    private var lastPublished: SharedUsageState?
    private var refreshesInFlight = 0
    private var nextRefreshTask: Task<Void, Never>?

    private static let refreshKey = "refreshSeconds"
    private static let metricKey = "menuBarMetric"

    init() {
        store = .forThisApp
        sharedState = .forThisApp
        let defaults = UserDefaults.standard
        refreshSeconds = RefreshSchedule.sanitized(defaults.object(forKey: Self.refreshKey) as? Int)
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Self.metricKey) ?? "") ?? .auto

        // Show the last reading right away if it came from the credentials saved now, and keep any cooldown.
        generation = (try? store.load())?.generation
        let state = sharedState.load()
        if let cached = RefreshSchedule.cachedSnapshot(in: state, generation: generation) {
            snapshot = cached.snapshot
            lastSuccessAt = cached.fetchedAt
        }
        if let saved = state?.cooldown, saved.until > Date() {
            cooldown = saved
        }
        lastPublished = state
        logger.notice("Launched: cached reading \(self.snapshot != nil, privacy: .public), cooldown \(self.cooldown != nil, privacy: .public)")

        // A fresh launch may be a new build, so ask WidgetKit to redraw the widget with it.
        WidgetCenter.shared.reloadAllTimelines()
        scheduleNextRefresh()
    }

    var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: lastSuccessAt, refreshSeconds: refreshSeconds, now: Date())
    }

    var headline: Headline {
        Headline.make(for: snapshot, metric: menuBarMetric)
    }

    /// Changes how often both the menu bar and the widget refresh.
    func setRefreshInterval(_ seconds: Int) {
        let value = RefreshSchedule.sanitized(seconds)
        guard value != refreshSeconds else { return }
        refreshSeconds = value
        UserDefaults.standard.set(value, forKey: Self.refreshKey)
        logger.notice("Refresh interval set to \(value, privacy: .public) seconds")
        publishToWidget()
        scheduleNextRefresh()
    }

    func setMenuBarMetric(_ metric: MenuBarMetric) {
        menuBarMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Self.metricKey)
    }

    /// Call after credentials are saved or removed. Numbers fetched with the old credentials are no longer shown.
    /// A server cooldown stays in force: new credentials don't earn an early retry.
    func credentialsChanged() {
        generation = (try? store.load())?.generation
        snapshot = nil
        lastSuccessAt = nil
        error = nil
        publishToWidget()
    }

    /// Loads credentials from the keychain, fetches usage, and publishes the result.
    @discardableResult
    func refresh(trigger: RefreshTrigger) async -> Result<UsageReport, UsageError> {
        let started = Date()
        if let cooldown, cooldown.blocks(at: started, manual: trigger != .automatic) {
            logger.notice("Refresh (\(trigger.rawValue, privacy: .public)) held until the cooldown ends")
            if trigger == .automatic { scheduleNextRefresh() }
            return .failure(.rateLimited(retryAfter: cooldown.until.timeIntervalSince(started)))
        }

        refreshesInFlight += 1
        isRefreshing = true
        lastAttemptAt = started
        let (result, usedGeneration) = await loadAndFetch()
        refreshesInFlight -= 1
        isRefreshing = refreshesInFlight > 0

        if let usedGeneration, let current = generation, usedGeneration != current {
            logger.notice("Discarded a result fetched with credentials that have since changed")
            scheduleNextRefresh()
            return result
        }

        switch result {
        case .success(let report):
            generation = usedGeneration
            snapshot = report.snapshot
            lastSuccessAt = Date()
            error = nil
            consecutiveRateLimits = 0
            cooldown = nil
            logger.notice("Refresh (\(trigger.rawValue, privacy: .public)) succeeded via \(report.route.rawValue, privacy: .public)")
        case .failure(let failure):
            error = failure
            if failure == .noCredentials { generation = nil }
            if case .rateLimited(let retryAfter) = failure {
                consecutiveRateLimits += 1
                cooldown = BackoffPolicy.cooldown(afterRateLimit: consecutiveRateLimits, retryAfter: retryAfter,
                                                  refreshSeconds: refreshSeconds, now: Date(),
                                                  jitter: Double.random(in: 0...1))
            }
            if !RefreshPolicy.keepsLastReport(after: failure) {
                snapshot = nil
                lastSuccessAt = nil
            }
            logger.error("Refresh (\(trigger.rawValue, privacy: .public)) failed: \(failure.message, privacy: .public)")
        }
        publishToWidget()
        scheduleNextRefresh()
        return result
    }

    private func loadAndFetch() async -> (Result<UsageReport, UsageError>, String?) {
        let config: WidgetConfig
        do {
            guard let stored = try store.load(), !stored.isEmpty else { return (.failure(.noCredentials), nil) }
            config = stored
        } catch let failure {
            return (.failure(failure as? UsageError ?? .keychain(errSecInternalComponent)), nil)
        }
        return (await UsageFetcher.live.fetch(config: config), config.generation)
    }

    /// One pending wake-up at a time: right after launch it waits for the cached reading to age, then one interval
    /// after each attempt, sooner just after a reset, and never before a cooldown ends.
    private func scheduleNextRefresh() {
        nextRefreshTask?.cancel()
        let wake: Date
        if let lastAttemptAt {
            wake = RefreshSchedule.nextRefresh(after: lastAttemptAt, refreshSeconds: refreshSeconds,
                                               snapshot: snapshot, cooldown: cooldown)
        } else {
            wake = RefreshSchedule.firstRefresh(now: Date(), refreshSeconds: refreshSeconds,
                                                lastSuccessAt: lastSuccessAt, cooldown: cooldown)
        }
        nextRefreshTask = Task { [weak self] in
            let delay = wake.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let monitor = self else { return }
            await monitor.refresh(trigger: .automatic)
        }
    }

    /// Shares the current numbers, cooldown, and credential generation with the widget, then asks it to redraw.
    private func publishToWidget() {
        let state = SharedUsageState(refreshSeconds: refreshSeconds, snapshot: snapshot, fetchedAt: lastSuccessAt,
                                     cooldown: cooldown, credentialGeneration: generation)
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

enum AppLaunch {
    /// Settings opens by itself only when there's nothing to show yet; otherwise the app starts quietly in the menu bar.
    static var showsSettingsAtLaunch: Bool {
        let config = try? KeychainCredentialStore.forThisApp.load()
        return config?.isEmpty ?? true
    }
}

enum AppVersion {
    /// Like "Version 1.3 (3)", read from the built app so it always matches what is running.
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
