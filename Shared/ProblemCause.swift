import Foundation

/// The kind of problem behind a message, so every place that shows a problem can give it the same icon and title.
/// The raw values are shared with the widget, so keep them stable.
enum ProblemCause: String, Codable, Sendable, CaseIterable {
    /// A credential was confirmed wrong or expired.
    case signIn
    /// Credentials are missing or malformed.
    case setup
    /// The usage service asked for a pause.
    case rateLimited
    /// The network couldn't be reached.
    case offline
    /// A bot check answered instead of the usage service.
    case botCheck
    /// The usage service answered, but not with usage.
    case serviceError
    /// The keychain couldn't be read or written.
    case keychain
    /// Nothing is wrong yet; there just isn't a reading.
    case waiting

    /// The symbol to use when there is a problem but no known cause.
    static let fallbackSymbol = "exclamationmark.triangle"

    init(_ error: UsageError) {
        switch error {
        case .tokenRejected, .sessionKeyRejected:
            self = .signIn
        case .noCredentials, .invalidOrganizationId, .invalidCredentials:
            self = .setup
        case .tokenCannotReadUsage:
            // The token works but can't read usage, so signing in again won't help. It needs a session key instead.
            self = .setup
        case .rateLimited:
            self = .rateLimited
        case .network:
            self = .offline
        case .blockedByCloudflare:
            self = .botCheck
        case .accessDenied, .http, .invalidResponse, .redirected, .requestBlocked:
            self = .serviceError
        case .keychain:
            self = .keychain
        case .fallbackFailed(_, let session):
            // The token is already known to be unusable, but the session key may still work once its problem clears.
            self = ProblemCause(session)
        }
    }

    /// The SF Symbol for this cause.
    var symbol: String {
        switch self {
        case .signIn: return "person.crop.circle.badge.exclamationmark"
        case .setup: return "gearshape"
        case .rateLimited: return "hourglass"
        case .offline: return "wifi.slash"
        case .botCheck: return "hand.raised"
        case .serviceError: return "exclamationmark.icloud"
        case .keychain: return "lock.trianglebadge.exclamationmark"
        case .waiting: return "clock.arrow.circlepath"
        }
    }

    /// A short title shown above the message, such as "Sign in again".
    var title: String {
        switch self {
        case .signIn: return "Sign in again"
        case .setup: return "Finish setup"
        case .rateLimited: return "Rate limited"
        case .offline: return "Offline"
        case .botCheck: return "Bot check"
        case .serviceError: return "Service problem"
        case .keychain: return "Keychain problem"
        case .waiting: return "Waiting for data"
        }
    }

    /// True when only the user can fix this in the app. Everything else clears up by waiting.
    /// This matches RefreshPolicy: the problems that clear the last numbers are the ones that need action.
    var needsAction: Bool {
        switch self {
        case .signIn, .setup: return true
        case .rateLimited, .offline, .botCheck, .serviceError, .keychain, .waiting: return false
        }
    }
}
