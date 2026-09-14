import Foundation

/// Everything that can go wrong while showing usage.
/// Messages are fixed text, so the widget and menu bar can never display part of a credential.
enum UsageError: Error, Equatable, Sendable {
    case noCredentials
    case invalidOrganizationId
    case invalidCredentials
    /// The Anthropic API refused the OAuth token (401): it is wrong, revoked, or expired.
    case tokenRejected
    /// The OAuth token is valid but may not read usage (403). Tokens from `claude setup-token` land here.
    case tokenCannotReadUsage
    /// claude.ai refused the session key (401 or 403): it expired, or that browser signed out.
    case sessionKeyRejected
    case http(Int)
    case network
    case invalidResponse
    case keychain(OSStatus)

    var message: String {
        switch self {
        case .noCredentials: return "Add credentials in the Claude Usage Widget app."
        case .invalidOrganizationId: return "Organization ID must be a UUID. Fix it in the app."
        case .invalidCredentials: return "Stored credentials are malformed. Save them again in the app."
        case .tokenRejected: return "OAuth token rejected (401). Paste a new one in the app."
        case .tokenCannotReadUsage: return "This OAuth token can't read usage. Use a session key instead."
        case .sessionKeyRejected: return "Session key expired or signed out. Paste a new session key."
        case .http(429): return "Rate limited (429). Retrying on the next refresh."
        case .http(let code): return "Usage service returned HTTP \(code)."
        case .network: return "Network unavailable. Retrying on the next refresh."
        case .invalidResponse: return "Unexpected response from the usage service."
        case .keychain(let status): return "Keychain error \(status). Open the app and save again."
        }
    }
}

/// Decides whether to retry with the claude.ai session key after the OAuth route fails.
///
/// The session key is a full claude.ai login, so it is only used when the OAuth token itself was refused.
/// Being offline, rate limited, or hitting a server error would affect both routes alike.
enum FallbackPolicy {
    static func shouldTrySessionKey(afterOAuthFailure error: UsageError) -> Bool {
        switch error {
        case .http(401), .http(403): return true
        default: return false
        }
    }
}

/// Decides whether the menu bar keeps showing the last good numbers after a failed refresh.
/// Temporary problems keep them; credential problems clear them so stale numbers don't look current.
enum RefreshPolicy {
    static func keepsLastReport(after error: UsageError) -> Bool {
        switch error {
        case .network, .http: return true
        default: return false
        }
    }
}

/// The only two places the app and widget ever send a credential.
enum ClaudeEndpoints {
    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Returns nil for a token that could break the Authorization header.
    static func oauthRequest(token: String) -> URLRequest? {
        guard WidgetConfig.isSafeToken(token) else { return nil }
        var request = baseRequest(oauthUsageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// The URL is rebuilt from a parsed UUID, never from the raw text, so nothing else can reach the path.
    /// Returns nil for an invalid organization ID or a session key that could break the Cookie header.
    static func sessionKeyRequest(sessionKey: String, organizationId: String) -> URLRequest? {
        guard WidgetConfig.isSafeSessionKey(sessionKey),
              let uuid = UUID(uuidString: organizationId),
              let url = URL(string: "https://claude.ai/api/organizations/\(uuid.uuidString.lowercased())/usage")
        else { return nil }
        var request = baseRequest(url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func baseRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var fableWeeklyPercent: Double?
    var fableWeeklyResetsAt: Date?
}

enum CredentialRoute: Equatable, Sendable {
    case oauthToken
    case sessionKey
}

/// A successful fetch, plus which credential worked.
struct UsageReport: Equatable, Sendable {
    var snapshot: UsageSnapshot
    var route: CredentialRoute
    /// Why the OAuth token was skipped, when the session key had to be used instead.
    var tokenFailure: UsageError? = nil
}

enum UsageParser {
    /// Reads the usage response the same way Claude Code's /usage screen does.
    /// A missing value stays unknown rather than becoming 0.
    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        let fiveHour = json["five_hour"] as? [String: Any]
        let weekly = json["seven_day"] as? [String: Any]
        let fable = fableWeeklyLimit(in: json["limits"])
        let snapshot = UsageSnapshot(fiveHourPercent: number(fiveHour?["utilization"]),
                                     fiveHourResetsAt: date(fiveHour?["resets_at"]),
                                     weeklyPercent: number(weekly?["utilization"]),
                                     weeklyResetsAt: date(weekly?["resets_at"]),
                                     fableWeeklyPercent: number(fable?["percent"]),
                                     fableWeeklyResetsAt: date(fable?["resets_at"]))
        guard snapshot.fiveHourPercent != nil || snapshot.weeklyPercent != nil || snapshot.fableWeeklyPercent != nil else {
            throw UsageError.invalidResponse
        }
        return snapshot
    }

    /// Model-specific weekly limits arrive in a `limits` list as `{"kind":"weekly_scoped","percent":…,
    /// "resets_at":…,"scope":{"model":{"display_name":"Fable"}}}`.
    private static func fableWeeklyLimit(in limits: Any?) -> [String: Any]? {
        (limits as? [[String: Any]])?.first { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String else { return false }
            return name.localizedCaseInsensitiveContains("fable")
        }
    }

    /// A finite JSON number. JSON true/false also arrive as NSNumber, so they are excluded.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    /// Accepts ISO 8601 text with or without fractional seconds, or seconds since 1970.
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Fetches usage over the OAuth route first, and over the session key only when FallbackPolicy allows it.
struct UsageFetcher {
    /// Sends one request and returns the body of a 200 response. Tests swap in a fake.
    var send: (URLRequest) async -> Result<Data, UsageError>

    func fetch(config: WidgetConfig) async -> Result<UsageReport, UsageError> {
        var tokenFailure: UsageError?

        // Stored values were validated when saved; these checks are a tripwire in case the keychain item was altered.
        if let token = config.oauthToken {
            guard let request = ClaudeEndpoints.oauthRequest(token: token) else { return .failure(.invalidCredentials) }
            switch await attempt(request) {
            case .success(let snapshot):
                return .success(UsageReport(snapshot: snapshot, route: .oauthToken))
            case .failure(let error):
                guard config.sessionKey != nil, FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: error) else {
                    return .failure(Self.named(tokenError: error))
                }
                tokenFailure = Self.named(tokenError: error)
            }
        }

        // Past this point the token is absent or known not to work, so the session key's result is the one to report.
        guard let sessionKey = config.sessionKey else { return .failure(.noCredentials) }
        guard WidgetConfig.isSafeSessionKey(sessionKey) else { return .failure(.invalidCredentials) }
        guard let organizationId = config.validatedOrganizationId,
              let request = ClaudeEndpoints.sessionKeyRequest(sessionKey: sessionKey, organizationId: organizationId)
        else { return .failure(.invalidOrganizationId) }

        switch await attempt(request) {
        case .success(let snapshot):
            return .success(UsageReport(snapshot: snapshot, route: .sessionKey, tokenFailure: tokenFailure))
        case .failure(let error):
            return .failure(Self.named(sessionKeyError: error))
        }
    }

    private func attempt(_ request: URLRequest) async -> Result<UsageSnapshot, UsageError> {
        switch await send(request) {
        case .success(let data):
            do { return .success(try UsageParser.parse(data)) } catch { return .failure(.invalidResponse) }
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Turns the OAuth route's 401 and 403 into errors that say what to do.
    static func named(tokenError error: UsageError) -> UsageError {
        switch error {
        case .http(401): return .tokenRejected
        case .http(403): return .tokenCannotReadUsage
        default: return error
        }
    }

    /// claude.ai answers an expired or signed-out session with 403 (sometimes 401).
    static func named(sessionKeyError error: UsageError) -> UsageError {
        switch error {
        case .http(401), .http(403): return .sessionKeyRejected
        default: return error
        }
    }
}

extension UsageFetcher {
    /// The real network. The session is ephemeral, so no cookies, cache, or credentials are written to disk.
    static var live: UsageFetcher {
        UsageFetcher { request in
            do {
                let (data, response) = try await LiveSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
                guard http.statusCode == 200 else { return .failure(.http(http.statusCode)) }
                return .success(data)
            } catch {
                return .failure(.network)
            }
        }
    }
}

private enum LiveSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
