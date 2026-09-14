import Foundation
import Security

/// Where the widget's credentials live. The app and widget use the keychain; tests use an in-memory stand-in.
protocol CredentialStoring {
    func load() throws -> WidgetConfig?
    func save(_ config: WidgetConfig) throws
    func delete() throws
}

/// Keeps the credentials in one item in your login keychain.
///
/// Who can read it: the item's access list names exactly two programs, this app and its widget.
/// Any other program, even one running under your account, gets a macOS password prompt instead of the secret.
/// Trust is tied to each program's code signature (bundle ID plus signing certificate), so rebuilding
/// or moving the app keeps working.
///
/// Why the classic login keychain rather than the newer "data protection" keychain: sharing a
/// data-protection item between an app and its widget needs a provisioning profile, which a free
/// Personal Team can't provide (tested 2026-09-14, it fails with -34018 "missing entitlement").
/// The access-list functions below are marked deprecated by Apple but remain the only way to share
/// a classic keychain item between two programs without prompting.
struct KeychainCredentialStore: CredentialStoring {
    var service = "dev.huan.ClaudeUsageWidget"
    var account = "widget-config"
    /// Programs besides the caller that may read the item, such as the widget extension inside the app.
    var trustedBundleURLs: [URL] = []

    static let label = "Claude Usage Widget"

    /// Makes keychain calls fail with an error instead of showing a dialog.
    /// The widget runs in the background, where a dialog would be confusing or invisible.
    static func preventKeychainDialogs() {
        _ = SecKeychainSetUserInteractionAllowed(false)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> WidgetConfig? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw UsageError.keychain(status) }
        do {
            return try WidgetConfig.decode(data)
        } catch {
            throw UsageError.keychain(errSecDecode)
        }
    }

    func save(_ config: WidgetConfig) throws {
        let data = try config.encoded()
        // Build the access list first, so a problem there leaves the existing item untouched.
        let access = try makeAccess()
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccess as String] = access
        query[kSecAttrLabel as String] = Self.label
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw UsageError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.keychain(status) }
    }

    /// An access list that trusts the calling program plus every bundle in `trustedBundleURLs`.
    private func makeAccess() throws -> SecAccess {
        var applications: [SecTrustedApplication] = []
        var selfApplication: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &selfApplication)
        guard status == errSecSuccess, let selfApplication else { throw UsageError.keychain(status) }
        applications.append(selfApplication)

        for url in trustedBundleURLs {
            var application: SecTrustedApplication?
            status = SecTrustedApplicationCreateFromPath(url.path, &application)
            guard status == errSecSuccess, let application else { throw UsageError.keychain(status) }
            applications.append(application)
        }

        var access: SecAccess?
        status = SecAccessCreate(Self.label as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else { throw UsageError.keychain(status) }
        return access
    }
}
