import Combine
import Foundation
import os

/// Logs outcomes only.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "updates")

/// Checks, at most once a day, whether the GitHub repository this copy was built from has published a newer version.
/// It sends one request for the latest release, with no account details, cookies, or usage numbers.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var problem: String?
    @Published private(set) var isEnabled: Bool

    let repository: SourceRepository?
    let currentVersion: String
    private var loop: Task<Void, Never>?

    private static let enabledKey = "checkForUpdates"
    private static let lastCheckedKey = "updateLastChecked"
    private static let latestVersionKey = "updateLatestVersion"
    private static let latestPageKey = "updateLatestPage"

    /// Uses the running app's own build details unless others are given.
    init(build: BuildInfo? = nil) {
        let build = build ?? AppVersion.current
        repository = build.sourceRepository
        currentVersion = build.version
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        if let version = defaults.string(forKey: Self.latestVersionKey) {
            let page = defaults.string(forKey: Self.latestPageKey).flatMap(URL.init(string:))
            latest = ReleaseInfo(version: version, title: nil, page: page, publishedAt: nil)
        }
        startLoop()
    }

    /// The newer version, when one is published.
    var available: ReleaseInfo? {
        guard let latest, UpdateCheck.isNewer(latest.version, than: currentVersion) else { return nil }
        return latest
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        startLoop()
    }

    /// Wakes every few hours and checks once a day has passed since the last check.
    private func startLoop() {
        loop?.cancel()
        guard isEnabled, repository != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let checker = self, UpdateCheck.isDue(lastChecked: checker.lastChecked, now: Date()) {
                    await checker.checkNow()
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func checkNow() async {
        guard let repository, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: repository.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageWidget", forHTTPHeaderField: "User-Agent")
        let result: (Data, URLResponse)
        do {
            result = try await Self.session.data(for: request)
        } catch {
            problem = "Couldn't reach GitHub. It will try again later."
            logger.error("Update check couldn't reach GitHub")
            return
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        record(checkedAt: Date())
        switch status {
        case 200:
            guard let release = try? UpdateCheck.parseRelease(result.0) else {
                problem = "The latest release on GitHub doesn't have a version number."
                return
            }
            remember(release)
            problem = nil
            logger.notice("Latest release is \(release.version, privacy: .public)")
        case 404:
            // No release has been published yet.
            remember(nil)
            problem = nil
        default:
            problem = "GitHub answered with status \(status). It will try again later."
            logger.error("Update check got status \(status, privacy: .public)")
        }
    }

    private func record(checkedAt date: Date) {
        lastChecked = date
        UserDefaults.standard.set(date, forKey: Self.lastCheckedKey)
    }

    private func remember(_ release: ReleaseInfo?) {
        latest = release
        let defaults = UserDefaults.standard
        defaults.set(release?.version, forKey: Self.latestVersionKey)
        defaults.set(release?.page?.absoluteString, forKey: Self.latestPageKey)
    }

    /// No cookies, cache, or stored credentials, like the usage requests.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
