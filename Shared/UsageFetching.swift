import Foundation

/// Everything that can go wrong while showing usage.
/// Messages are fixed text, so the widget and menu bar can never display part of a credential.
enum UsageError: Error, Equatable, Sendable {
    case noCredentials
    case invalidOrganizationId
    case invalidCredentials
    /// The Anthropic API refused the OAuth token (401): it is wrong, revoked, or expired.
    case tokenRejected
    /// The OAuth token is valid but may not read usage (403 "scope requirement"). Tokens from `claude setup-token` land here.
    case tokenCannotReadUsage
    /// claude.ai confirmed the session is invalid (account_session_invalid): the key expired or that browser signed out.
    case sessionKeyRejected
    /// A Cloudflare bot check answered instead of claude.ai. The key may be fine.
    case blockedByCloudflare
    /// A 401 or 403 without evidence of the cause. The last good numbers stay, marked stale.
    case accessDenied(Int)
    /// 429 Too Many Requests, with the server's requested wait if it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// The service answered with a redirect, which the app refuses to follow with credentials attached.
    case redirected
    /// The app's own destination rules stopped the request before it was sent.
    case requestBlocked
    case http(Int)
    case network
    case invalidResponse
    case keychain(OSStatus)
    /// The token is confirmed unusable and the session-key fallback failed too. Both problems are kept.
    indirect case fallbackFailed(token: UsageError, session: UsageError)

    var message: String {
        switch self {
        case .noCredentials: return "Add credentials in the Claude Usage Widget app."
        case .invalidOrganizationId: return "Organization ID must be a UUID. Fix it in the app."
        case .invalidCredentials: return "Stored credentials are malformed. Save them again in the app."
        case .tokenRejected: return "OAuth token rejected (401). Paste a new one in the app."
        case .tokenCannotReadUsage: return "This OAuth token can't read usage. Use a session key instead."
        case .sessionKeyRejected: return "Session key expired or signed out. Paste a new session key."
        case .blockedByCloudflare: return "The usage service showed a bot check. Retrying later; your key may be fine."
        case .accessDenied(let code): return "Access denied (\(code)) for an unclear reason. Retrying later."
        case .rateLimited: return "Rate limited by the usage service. Waiting before trying again."
        case .redirected: return "The usage service redirected the request, so it was stopped."
        case .requestBlocked: return "The request was blocked by the app's safety rules."
        case .http(let code): return "Usage service returned HTTP \(code)."
        case .network: return "Network unavailable. Retrying on the next refresh."
        case .invalidResponse: return "Unexpected response from the usage service."
        case .keychain(let status): return "Keychain error \(status). Open the app and save again."
        case .fallbackFailed(let token, let session): return "\(token.tokenPart); \(session.sessionPart)."
        }
    }

    private var tokenPart: String {
        switch self {
        case .tokenCannotReadUsage: return "OAuth token can't read usage"
        default: return "OAuth token rejected"
        }
    }

    private var sessionPart: String {
        switch self {
        case .sessionKeyRejected: return "session key expired"
        case .blockedByCloudflare: return "session key hit a bot check"
        case .accessDenied(let code): return "session key denied (\(code))"
        case .rateLimited: return "session key rate limited"
        case .network: return "session key couldn't connect"
        case .http(let code): return "session key got HTTP \(code)"
        case .invalidResponse: return "session key got an unexpected reply"
        case .redirected: return "session key request was redirected"
        case .requestBlocked: return "session key request was blocked"
        case .invalidOrganizationId: return "session key needs a valid org ID"
        case .invalidCredentials: return "session key is malformed"
        default: return "session key failed"
        }
    }
}

/// The parts of a failed response needed to classify it. The body is capped and never logged or stored.
struct HTTPFailure: Equatable, Sendable {
    static let bodyLimit = 4096

    let status: Int
    let contentType: String?
    let cfMitigated: String?
    let retryAfter: String?
    let bodyPrefix: Data
}

/// What happened to one request.
enum TransportResult: Sendable {
    case ok(Data)
    case http(HTTPFailure)
    case redirected
    /// Stopped by ClaudeEndpoints.isAllowed before sending.
    case refused
    case network
}

/// Turns a failed response into a UsageError, using explicit evidence rather than the status code alone.
enum ResponseClassifier {
    static func classify(_ failure: HTTPFailure, route: CredentialRoute, now: Date) -> UsageError {
        let status = failure.status
        if (300..<400).contains(status) { return .redirected }
        if status == 429 { return .rateLimited(retryAfter: RetryAfter.parse(failure.retryAfter, now: now)) }
        guard status == 401 || status == 403 else { return .http(status) }

        if isCloudflareChallenge(failure) { return .blockedByCloudflare }
        let error = errorObject(failure.bodyPrefix)

        switch route {
        case .oauthToken:
            if status == 401, error?.type == "authentication_error" { return .tokenRejected }
            if let message = error?.message, message.localizedCaseInsensitiveContains("scope requirement") {
                return .tokenCannotReadUsage
            }
        case .sessionKey:
            if error?.errorCode == "account_session_invalid" { return .sessionKeyRejected }
            if status == 401, error?.type == "authentication_error" { return .sessionKeyRejected }
        }
        return .accessDenied(status)
    }

    /// Cloudflare marks challenges with a cf-mitigated header. Its challenge pages also carry recognizable markers:
    /// the "Just a moment..." title near the top, the challenge options object, and the challenge-platform script.
    private static func isCloudflareChallenge(_ failure: HTTPFailure) -> Bool {
        if failure.cfMitigated?.localizedCaseInsensitiveContains("challenge") == true { return true }
        guard failure.contentType?.localizedCaseInsensitiveContains("text/html") == true else { return false }
        let page = String(decoding: failure.bodyPrefix, as: UTF8.self)
        return ["<title>Just a moment...</title>", "window._cf_chl_opt", "/cdn-cgi/challenge-platform"].contains { page.contains($0) }
    }

    private struct ErrorFields {
        let type: String?
        let message: String?
        let errorCode: String?
    }

    /// Reads {"error":{"type","message","details":{"error_code"}}} from a JSON body, if present.
    private static func errorObject(_ body: Data) -> ErrorFields? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        let details = error["details"] as? [String: Any]
        return ErrorFields(type: error["type"] as? String, message: error["message"] as? String,
                           errorCode: details?["error_code"] as? String)
    }
}

/// Decides whether to retry with the claude.ai session key after the OAuth route fails.
///
/// The session key is a full claude.ai login, so it is only used when the token itself is confirmed unusable.
/// An unclear 403, a bot check, a rate limit, or a network problem would not be fixed by switching credentials.
enum FallbackPolicy {
    static func shouldTrySessionKey(afterTokenFailure error: UsageError) -> Bool {
        switch error {
        case .tokenRejected, .tokenCannotReadUsage: return true
        default: return false
        }
    }
}

/// Decides whether the last good numbers stay on screen (marked stale) after a failed refresh.
/// Confirmed credential problems clear them; anything unclear or temporary keeps them.
enum RefreshPolicy {
    static func keepsLastReport(after error: UsageError) -> Bool {
        switch error {
        case .network, .http, .rateLimited, .blockedByCloudflare, .accessDenied, .invalidResponse, .redirected, .requestBlocked,
             .keychain:
            return true
        case .noCredentials, .invalidOrganizationId, .invalidCredentials, .tokenRejected, .tokenCannotReadUsage,
             .sessionKeyRejected:
            return false
        case .fallbackFailed(_, let session):
            return keepsLastReport(after: session)
        }
    }
}

/// The only places the app and widget ever send a credential: the two usage addresses, plus claude.ai's list of
/// organizations, which setup reads to fill in the organization ID.
enum ClaudeEndpoints {
    static let oauthHost = "api.anthropic.com"
    static let oauthPath = "/api/oauth/usage"
    static let sessionHost = "claude.ai"
    static let organizationsPath = "/api/organizations"
    static let oauthUsageURL = URL(string: "https://\(oauthHost)\(oauthPath)")!

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
              let url = URL(string: "https://\(sessionHost)/api/organizations/\(uuid.uuidString.lowercased())/usage")
        else { return nil }
        var request = baseRequest(url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return request
    }

    /// The account's organizations. Returns nil for a session key that could break the Cookie header.
    static func organizationsRequest(sessionKey: String) -> URLRequest? {
        guard WidgetConfig.isSafeSessionKey(sessionKey),
              let url = URL(string: "https://\(sessionHost)\(organizationsPath)") else { return nil }
        var request = baseRequest(url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return request
    }

    /// The final check before anything is sent: HTTPS to an exact approved address, with the session cookie
    /// only going to claude.ai and the OAuth token only going to api.anthropic.com.
    static func isAllowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.port == nil,
              url.query == nil, url.fragment == nil, let host = url.host else { return false }
        let hasCookie = request.value(forHTTPHeaderField: "Cookie") != nil
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") != nil
        switch host {
        case oauthHost:
            return url.path == oauthPath && !hasCookie
        case sessionHost:
            if url.path(percentEncoded: true) == organizationsPath { return !hasBearer }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "organizations",
                  parts[4] == "usage", let uuid = UUID(uuidString: String(parts[3])),
                  uuid.uuidString.lowercased() == parts[3] else { return false }
            return !hasBearer
        default:
            return false
        }
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

enum CredentialRoute: String, Codable, Equatable, Sendable {
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
    /// Reads the usage response the same way Claude Code's /usage screen does, then sanity-checks it.
    /// Missing or impossible values stay unknown rather than becoming 0 or being clamped into range.
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        let fiveHour = json["five_hour"] as? [String: Any]
        let weekly = json["seven_day"] as? [String: Any]
        let fable = fableWeeklyLimit(in: json["limits"])
        let snapshot = UsageSnapshot(fiveHourPercent: percent(fiveHour?["utilization"]),
                                     fiveHourResetsAt: resetDate(fiveHour?["resets_at"], now: now),
                                     weeklyPercent: percent(weekly?["utilization"]),
                                     weeklyResetsAt: resetDate(weekly?["resets_at"], now: now),
                                     fableWeeklyPercent: percent(fable?["percent"]),
                                     fableWeeklyResetsAt: resetDate(fable?["resets_at"], now: now))
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

    /// A percentage from 0 to 100. Anything else is unknown, so a scale change can't masquerade as a real reading.
    static func percent(_ value: Any?) -> Double? {
        guard let number = number(value), (0...100).contains(number) else { return nil }
        return number
    }

    /// A reset time no more than a day in the past and no more than eight days ahead.
    static func resetDate(_ value: Any?, now: Date) -> Date? {
        guard let date = date(value),
              date >= now.addingTimeInterval(-86_400),
              date <= now.addingTimeInterval(8 * 86_400) else { return nil }
        return date
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
    /// Sends one request. Tests swap in a fake.
    var send: (URLRequest) async -> TransportResult
    var now: () -> Date = Date.init

    init(send: @escaping (URLRequest) async -> TransportResult) {
        self.send = send
    }

    func fetch(config: WidgetConfig) async -> Result<UsageReport, UsageError> {
        var tokenFailure: UsageError?

        // Stored values were validated when saved; these checks are a tripwire in case the keychain item was altered.
        if let token = config.oauthToken {
            guard let request = ClaudeEndpoints.oauthRequest(token: token) else { return .failure(.invalidCredentials) }
            switch await attempt(request, route: .oauthToken) {
            case .success(let snapshot):
                return .success(UsageReport(snapshot: snapshot, route: .oauthToken))
            case .failure(let error):
                guard config.sessionKey != nil, FallbackPolicy.shouldTrySessionKey(afterTokenFailure: error) else {
                    return .failure(error)
                }
                tokenFailure = error
            }
        }

        // Past this point the token is absent or confirmed unusable, so the session key's result is the one to report.
        func failed(_ sessionError: UsageError) -> Result<UsageReport, UsageError> {
            .failure(tokenFailure.map { .fallbackFailed(token: $0, session: sessionError) } ?? sessionError)
        }
        guard let sessionKey = config.sessionKey else { return .failure(.noCredentials) }
        guard WidgetConfig.isSafeSessionKey(sessionKey) else { return failed(.invalidCredentials) }
        guard let organizationId = config.validatedOrganizationId,
              let request = ClaudeEndpoints.sessionKeyRequest(sessionKey: sessionKey, organizationId: organizationId)
        else { return failed(.invalidOrganizationId) }

        switch await attempt(request, route: .sessionKey) {
        case .success(let snapshot):
            return .success(UsageReport(snapshot: snapshot, route: .sessionKey, tokenFailure: tokenFailure))
        case .failure(let error):
            return failed(error)
        }
    }

    private func attempt(_ request: URLRequest, route: CredentialRoute) async -> Result<UsageSnapshot, UsageError> {
        switch await send(request) {
        case .ok(let data):
            do { return .success(try UsageParser.parse(data, now: now())) } catch { return .failure(.invalidResponse) }
        case .http(let failure):
            return .failure(ResponseClassifier.classify(failure, route: route, now: now()))
        case .redirected:
            return .failure(.redirected)
        case .refused:
            return .failure(.requestBlocked)
        case .network:
            return .failure(.network)
        }
    }
}

extension UsageFetcher {
    /// The real network. The session is ephemeral (no cookies, cache, or credentials written to disk) and refuses redirects.
    static var live: UsageFetcher {
        UsageFetcher(send: LiveTransport.send)
    }
}

enum LiveTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async -> TransportResult {
        guard ClaudeEndpoints.isAllowed(request) else { return .refused }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network }
            if (300..<400).contains(http.statusCode) { return .redirected }
            guard http.statusCode == 200 else {
                return .http(HTTPFailure(status: http.statusCode,
                                         contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                         cfMitigated: http.value(forHTTPHeaderField: "cf-mitigated"),
                                         retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                         bodyPrefix: Data(data.prefix(HTTPFailure.bodyLimit))))
            }
            return .ok(data)
        } catch {
            return .network
        }
    }
}

/// Stops every redirect, so a credential can't follow a request to a login page or another host.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension UsageError {
    /// True when this error, or the session-key half of a failed fallback, is a 429.
    var isRateLimited: Bool {
        switch self {
        case .rateLimited: return true
        case .fallbackFailed(_, let session): return session.isRateLimited
        default: return false
        }
    }

    /// The server's requested wait inside a rate-limit error, if it sent one.
    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter): return retryAfter
        case .fallbackFailed(_, let session): return session.retryAfter
        default: return nil
        }
    }
}
