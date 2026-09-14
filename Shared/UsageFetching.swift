import Foundation

/// Everything that can go wrong while showing usage.
/// Messages are fixed text, so the widget can never display part of a credential.
enum UsageError: Error, Equatable, Sendable {
    case noCredentials
    case invalidOrganizationId
    case http(Int)
    case network
    case invalidResponse
    case keychain(OSStatus)

    var message: String {
        switch self {
        case .noCredentials: return "Add credentials in the Claude Usage Widget app."
        case .invalidOrganizationId: return "Organization ID must be a UUID. Fix it in the app."
        case .http(401): return "Credentials rejected (401). Update them in the app."
        case .http(403): return "Access denied (403). This credential can't read usage."
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

/// The only two places the widget ever sends a credential.
enum ClaudeEndpoints {
    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func oauthRequest(token: String) -> URLRequest {
        var request = baseRequest(oauthUsageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// The URL is rebuilt from a parsed UUID, never from the raw text, so nothing else can reach the path.
    static func sessionKeyRequest(sessionKey: String, organizationId: String) -> URLRequest? {
        guard let uuid = UUID(uuidString: organizationId),
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

struct UsageSnapshot: Equatable, Sendable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
}

enum UsageParser {
    /// Reads the usage response. Percentages may be whole or decimal; a missing value stays unknown rather than 0.
    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        let fiveHour = json["five_hour"] as? [String: Any]
        let weekly = json["seven_day"] as? [String: Any]
        let snapshot = UsageSnapshot(fiveHourPercent: number(fiveHour?["utilization"]),
                                     fiveHourResetsAt: date(fiveHour?["resets_at"]),
                                     weeklyPercent: number(weekly?["utilization"]),
                                     weeklyResetsAt: date(weekly?["resets_at"]))
        guard snapshot.fiveHourPercent != nil || snapshot.weeklyPercent != nil else {
            throw UsageError.invalidResponse
        }
        return snapshot
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

    func fetch(config: WidgetConfig) async -> Result<UsageSnapshot, UsageError> {
        var oauthFailure: UsageError?

        if let token = config.oauthToken {
            switch await attempt(ClaudeEndpoints.oauthRequest(token: token)) {
            case .success(let snapshot):
                return .success(snapshot)
            case .failure(let error):
                guard config.sessionKey != nil, FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: error) else {
                    return .failure(error)
                }
                oauthFailure = error
            }
        }

        guard let sessionKey = config.sessionKey else { return .failure(oauthFailure ?? .noCredentials) }
        guard let organizationId = config.validatedOrganizationId,
              let request = ClaudeEndpoints.sessionKeyRequest(sessionKey: sessionKey, organizationId: organizationId)
        else { return .failure(oauthFailure ?? .invalidOrganizationId) }

        switch await attempt(request) {
        case .success(let snapshot): return .success(snapshot)
        case .failure(let error): return .failure(oauthFailure ?? error)
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
