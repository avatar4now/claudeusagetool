import Foundation

/// The credentials the widget needs. The app stores them together as one small JSON value in the login keychain.
struct WidgetConfig: Codable, Equatable, Sendable {
    var oauthToken: String?
    var sessionKey: String?
    var organizationId: String?

    init(oauthToken: String? = nil, sessionKey: String? = nil, organizationId: String? = nil) {
        self.oauthToken = oauthToken
        self.sessionKey = sessionKey
        self.organizationId = organizationId
    }

    /// True when there is nothing to sign in with. An organization ID on its own is not a credential.
    var isEmpty: Bool { oauthToken == nil && sessionKey == nil }

    /// The organization ID in claude.ai's lowercase form, or nil unless it really is a UUID.
    var validatedOrganizationId: String? {
        organizationId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    /// Builds a config from the app's text fields: trims whitespace, turns blanks into nil, and validates.
    static func fromFields(oauthToken: String?, sessionKey: String?, organizationId: String?) throws -> WidgetConfig {
        try WidgetConfig(oauthToken: oauthToken?.trimmedNonEmpty,
                         sessionKey: sessionKey?.trimmedNonEmpty,
                         organizationId: organizationId?.trimmedNonEmpty).validated()
    }

    /// Applies the Save rules to a config from anywhere (text fields, the old file, the keychain).
    /// Returns it with the organization ID lowercased.
    func validated() throws -> WidgetConfig {
        if let oauthToken, !Self.isSafeToken(oauthToken) { throw ConfigValidationError.invalidToken }
        if let sessionKey, !Self.isSafeSessionKey(sessionKey) { throw ConfigValidationError.invalidSessionKey }
        if let organizationId, UUID(uuidString: organizationId) == nil { throw ConfigValidationError.invalidOrganizationId }
        if sessionKey != nil, organizationId == nil { throw ConfigValidationError.missingOrganizationId }
        return WidgetConfig(oauthToken: oauthToken, sessionKey: sessionKey, organizationId: organizationId?.lowercased())
    }

    /// A token must be visible ASCII only, so it can't split or extend the Authorization header.
    static func isSafeToken(_ token: String) -> Bool { token.isHeaderSafe }

    /// A session key has the same rule, and also can't contain ';', which would start a second cookie.
    static func isSafeSessionKey(_ key: String) -> Bool { key.isHeaderSafe && !key.contains(";") }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a stored config. Unknown keys are ignored and blank values count as missing.
    static func decode(_ data: Data) throws -> WidgetConfig {
        let raw = try JSONDecoder().decode(WidgetConfig.self, from: data)
        return WidgetConfig(oauthToken: raw.oauthToken?.trimmedNonEmpty,
                            sessionKey: raw.sessionKey?.trimmedNonEmpty,
                            organizationId: raw.organizationId?.trimmedNonEmpty)
    }
}

enum ConfigValidationError: Error, Equatable {
    case invalidToken
    case invalidSessionKey
    case invalidOrganizationId
    case missingOrganizationId

    var message: String {
        switch self {
        case .invalidToken: return "The OAuth token has spaces or unusual characters. Paste only the token."
        case .invalidSessionKey: return "The session key has spaces or unusual characters. Paste only the key."
        case .invalidOrganizationId: return "Organization ID must be a UUID, like 123e4567-e89b-12d3-a456-426614174000."
        case .missingOrganizationId: return "A session key also needs your organization ID."
        }
    }
}

extension String {
    /// The text without surrounding whitespace, or nil when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when every character is visible ASCII, so the value can't split or extend an HTTP header.
    var isHeaderSafe: Bool {
        unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
