import AppKit
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
    /// Ticks every 30 seconds so the menu bar label re-evaluates staleness and reset times between fetches.
    @Published private(set) var clock = Date()
    /// Changes whenever a reading is added to (or cleared from) the history, so the dashboard reloads.
    @Published private(set) var historyRevision = 0
    @Published private(set) var isHistoryEnabled: Bool
    /// How the app, menu bar, and widget look.
    @Published private(set) var appearance: Appearance
    /// False only when the keychain is known to hold no credentials, so the app can offer setup. A keychain that
    /// can't be read counts as having credentials, so its real error is shown instead of a setup prompt.
    @Published private(set) var hasCredentials = true
    /// Changes whenever credentials are saved or removed, so an open Settings window can show the new ones.
    @Published private(set) var credentialsRevision = 0

    /// The dashboard's history file, inside this app's sandbox container.
    let history = UsageHistoryStore.appDefault
    private var lastRecorded: UsageSample?

    let store: KeychainCredentialStore
    private let sharedState: KeychainUsageStateStore
    private var generation: String?
    private var consecutiveRateLimits = 0
    private var lastPublished: SharedUsageState?
    private var refreshesInFlight = 0
    private var nextRefreshTask: Task<Void, Never>?
    private var nextWake: Date?
    private var clockTask: Task<Void, Never>?
    private var isTerminating = false

    private static let refreshKey = "refreshSeconds"
    private static let metricKey = "menuBarMetric"
    private static let historyKey = "keepHistory"
    private static let appearanceKey = "appearance"

    init() {
        store = .forThisApp
        sharedState = .forThisApp
        let defaults = UserDefaults.standard
        refreshSeconds = RefreshSchedule.sanitized(defaults.object(forKey: Self.refreshKey) as? Int)
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Self.metricKey) ?? "") ?? .auto
        isHistoryEnabled = defaults.object(forKey: Self.historyKey) as? Bool ?? true
        appearance = defaults.data(forKey: Self.appearanceKey).flatMap { try? JSONDecoder().decode(Appearance.self, from: $0) }
            ?? .standard

        // Credentials saved before version 1.3 have no generation. Give them one, so cached numbers can be matched
        // to them and the widget can reuse the app's readings instead of fetching again.
        if var legacy = try? store.load(), !legacy.isEmpty, legacy.generation == nil {
            legacy.generation = UUID().uuidString
            do {
                try store.save(legacy)
                logger.notice("Added a credential generation to credentials saved by an earlier version")
            } catch {
                logger.error("Couldn't add a credential generation to saved credentials")
            }
        }

        // Show the last reading right away if it came from the credentials saved now, and keep any cooldown.
        generation = (try? store.load())?.generation
        hasCredentials = Self.credentialsPresent(in: store)
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

        if isHistoryEnabled {
            try? history.compact(now: Date())
            lastRecorded = history.load(now: Date()).last
        }

        scheduleNextRefresh()
        // Publishing the heartbeat also asks WidgetKit to redraw, which picks up a new build of the widget.
        publishToWidget(force: true)
        startClock()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
    }

    /// Clears the heartbeat so the widget starts fetching for itself as soon as the app quits.
    private func appWillTerminate() {
        isTerminating = true
        nextRefreshTask?.cancel()
        publishToWidget()
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let monitor = self else { return }
                monitor.clock = Date()
            }
        }
    }

    var isStale: Bool {
        snapshot != nil && Freshness.isStale(fetchedAt: lastSuccessAt, refreshSeconds: refreshSeconds, now: Date())
    }

    /// True when there's nothing to show because no account is connected yet. A keychain problem is shown as
    /// itself instead.
    var needsSetup: Bool {
        !hasCredentials && (error == nil || error == .noCredentials)
    }

    var headline: Headline {
        Headline.make(for: snapshot, metric: menuBarMetric, warningAt: Double(appearance.redAt))
    }

    /// Saves a new look and hands it to the widget, which redraws with it.
    func setAppearance(_ newValue: Appearance) {
        let value = newValue.sanitized()
        guard value != appearance else { return }
        appearance = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.appearanceKey)
        }
        publishToWidget()
    }

    /// Changes how often both the menu bar and the widget refresh.
    func setRefreshInterval(_ seconds: Int) {
        let value = RefreshSchedule.sanitized(seconds)
        guard value != refreshSeconds else { return }
        refreshSeconds = value
        UserDefaults.standard.set(value, forKey: Self.refreshKey)
        logger.notice("Refresh interval set to \(value, privacy: .public) seconds")
        scheduleNextRefresh()
        publishToWidget()
    }

    /// Turns the usage history on or off. Turning it off keeps what's saved until Clear History is used.
    func setHistoryEnabled(_ enabled: Bool) {
        isHistoryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.historyKey)
    }

    func clearHistory() {
        do {
            try history.clear()
            lastRecorded = nil
            historyRevision += 1
            logger.notice("History cleared")
        } catch {
            logger.error("Couldn't clear the history file")
        }
    }

    /// Saves a reading for the dashboard when enough time has passed or something changed meaningfully.
    private func recordHistory(_ snapshot: UsageSnapshot, at date: Date) {
        guard isHistoryEnabled else { return }
        let sample = UsageSample(snapshot: snapshot, at: date)
        guard HistoryPolicy.shouldRecord(sample, after: lastRecorded) else { return }
        do {
            try history.append(sample)
            lastRecorded = sample
            historyRevision += 1
        } catch {
            logger.error("Couldn't save a history reading")
        }
    }

    func setMenuBarMetric(_ metric: MenuBarMetric) {
        menuBarMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: Self.metricKey)
    }

    /// Call after credentials are saved or removed. Numbers fetched with the old credentials are no longer shown.
    /// A server cooldown stays in force: new credentials don't earn an early retry.
    func credentialsChanged() {
        generation = (try? store.load())?.generation
        hasCredentials = Self.credentialsPresent(in: store)
        credentialsRevision += 1
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
        let outcome = await loadAndFetch()
        refreshesInFlight -= 1
        isRefreshing = refreshesInFlight > 0

        // A result fetched with credentials that have since changed must not be shown. A rate limit still counts,
        // because the wait belongs to the service, not to the credentials.
        if outcome.usedCredentials, outcome.generation != generation {
            logger.notice("Discarded a result fetched with credentials that have since changed")
            if case .failure(let failure) = outcome.result, failure.isRateLimited {
                recordRateLimit(retryAfter: failure.retryAfter)
            }
            scheduleNextRefresh()
            publishToWidget()
            return outcome.result
        }

        switch outcome.result {
        case .success(let report):
            show(report)
            logger.notice("Refresh (\(trigger.rawValue, privacy: .public)) succeeded via \(report.route.rawValue, privacy: .public)")
        case .failure(let failure):
            error = failure
            if !outcome.usedCredentials { generation = nil }
            if failure.isRateLimited {
                recordRateLimit(retryAfter: failure.retryAfter)
            }
            if !RefreshPolicy.keepsLastReport(after: failure) {
                snapshot = nil
                lastSuccessAt = nil
            }
            logger.error("Refresh (\(trigger.rawValue, privacy: .public)) failed: \(failure.message, privacy: .public)")
        }
        scheduleNextRefresh()
        publishToWidget()
        return outcome.result
    }

    private var lastRateLimitAt: Date?

    /// Shows a successful reading: the numbers, a history entry, and a clean slate for rate limits.
    private func show(_ report: UsageReport) {
        let fetchedAt = Date()
        snapshot = report.snapshot
        lastSuccessAt = fetchedAt
        error = nil
        recordHistory(report.snapshot, at: fetchedAt)
        consecutiveRateLimits = 0
        lastRateLimitAt = nil
        cooldown = nil
    }

    /// Takes a reading that setup already fetched and checked with the credentials it just saved, so connecting
    /// doesn't need a second request. Call right after credentialsChanged().
    func adopt(_ report: UsageReport) {
        lastAttemptAt = Date()
        show(report)
        logger.notice("Adopted the reading setup checked, via \(report.route.rawValue, privacy: .public)")
        scheduleNextRefresh()
        publishToWidget()
    }

    /// Whether the keychain holds credentials. A keychain that can't be read counts as yes: the problem is the
    /// keychain, not missing setup.
    private static func credentialsPresent(in store: KeychainCredentialStore) -> Bool {
        do {
            return !(try store.load()?.isEmpty ?? true)
        } catch {
            return true
        }
    }

    private func recordRateLimit(retryAfter: TimeInterval?) {
        let now = Date()
        consecutiveRateLimits = RateLimitStreak.next(previous: consecutiveRateLimits, lastRateLimitAt: lastRateLimitAt, now: now)
        lastRateLimitAt = now
        cooldown = BackoffPolicy.cooldown(afterRateLimit: consecutiveRateLimits, retryAfter: retryAfter,
                                          refreshSeconds: refreshSeconds, now: now, jitter: Double.random(in: 0...1))
    }

    private struct FetchOutcome {
        let result: Result<UsageReport, UsageError>
        let generation: String?
        /// False when there were no credentials to use, so no request was sent.
        let usedCredentials: Bool
    }

    private func loadAndFetch() async -> FetchOutcome {
        let config: WidgetConfig
        do {
            guard let stored = try store.load(), !stored.isEmpty else {
                hasCredentials = false
                return FetchOutcome(result: .failure(.noCredentials), generation: nil, usedCredentials: false)
            }
            hasCredentials = true
            config = stored
        } catch let failure {
            return FetchOutcome(result: .failure(failure as? UsageError ?? .keychain(errSecInternalComponent)),
                                generation: generation, usedCredentials: false)
        }
        return FetchOutcome(result: await UsageFetcher.live.fetch(config: config), generation: config.generation,
                            usedCredentials: true)
    }

    /// One pending wake-up at a time: right after launch it waits for the cached reading to age, then one interval
    /// after each attempt, sooner just after a reset, and never before a cooldown ends. The wake-up only sleeps;
    /// the refresh it starts runs in its own task, so rescheduling can't cancel a request already on the network.
    private func scheduleNextRefresh() {
        nextRefreshTask?.cancel()
        let wake: Date
        if let lastAttemptAt {
            wake = RefreshSchedule.nextRefresh(after: lastAttemptAt, refreshSeconds: refreshSeconds,
                                               snapshot: snapshot, cooldown: cooldown)
        } else {
            wake = RefreshSchedule.firstRefresh(now: Date(), refreshSeconds: refreshSeconds, lastSuccessAt: lastSuccessAt,
                                                snapshot: snapshot, cooldown: cooldown)
        }
        nextWake = wake
        nextRefreshTask = Task { [weak self] in
            // Sleep at most a day at a time; a longer wait simply re-checks when it wakes.
            let delay = min(wake.timeIntervalSinceNow, 86_400)
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let monitor = self else { return }
            monitor.startAutomaticRefresh()
        }
    }

    private func startAutomaticRefresh() {
        // A refresh that is already running schedules the next wake-up when it finishes.
        guard refreshesInFlight == 0 else { return }
        Task { await refresh(trigger: .automatic) }
    }

    /// Shares the current numbers, cooldown, credential generation, latest problem and its cause, the look, and a heartbeat with
    /// the widget, then asks it to redraw. The heartbeat runs a little past the next wake-up; while it lasts the widget
    /// waits for the app instead of sending its own request.
    private func publishToWidget(force: Bool = false) {
        let heartbeat = isTerminating ? nil : nextWake.map { max($0, Date()).addingTimeInterval(RefreshSchedule.grace + 30) }
        let state = SharedUsageState(refreshSeconds: refreshSeconds, snapshot: snapshot, fetchedAt: lastSuccessAt,
                                     cooldown: cooldown, credentialGeneration: generation,
                                     appHeartbeatUntil: heartbeat, appErrorMessage: error?.message,
                                     appProblemCause: error.map(ProblemCause.init), appearance: appearance)
        guard force || state != lastPublished else { return }
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
    static let dashboard = "dashboard"
    static let settings = "settings"
    static let setup = "setup"
}

/// The tabs of the Settings window. The selected tab is remembered, and other windows can pick one before opening it.
enum SettingsTab: String, CaseIterable {
    case account
    case appearance
    case general
    case about

    static let storageKey = "settingsTab"
}

/// Shows the app in the Dock and app switcher while any of its windows is open, and hides it again when they close.
@MainActor
enum WindowPresence {
    private static var openCount = 0

    static func opened() {
        openCount += 1
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    static func closed() {
        openCount = max(0, openCount - 1)
        if openCount == 0 { NSApplication.shared.setActivationPolicy(.accessory) }
    }
}

enum AppLaunch {
    /// The setup assistant opens by itself only when no account is connected yet. Worked out once, at launch,
    /// because it only decides which window opens first.
    static let needsSetup: Bool = {
        let config = try? KeychainCredentialStore.forThisApp.load()
        return config?.isEmpty ?? true
    }()
}

enum AppVersion {
    /// The running app's version and the code it was built from, read from its own Info.plist.
    static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)
}
