import Foundation

/// One claude.ai organization the signed-in account belongs to.
struct ClaudeOrganization: Equatable, Hashable, Sendable, Identifiable {
    /// The organization ID in lowercase, the way the usage address uses it.
    let id: String
    let name: String
    /// True for organizations that use Claude chat, false for API-only ones, nil when claude.ai didn't say.
    let canChat: Bool?
}

/// Reads claude.ai's list of organizations, so setup can fill in the organization ID by itself.
enum OrganizationParser {
    static func parse(_ data: Data) throws -> [ClaudeOrganization] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw UsageError.invalidResponse
        }
        let organizations = list.compactMap { item -> ClaudeOrganization? in
            guard let text = item["uuid"] as? String, let uuid = UUID(uuidString: text) else { return nil }
            let rawName = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let capabilities = item["capabilities"] as? [String]
            return ClaudeOrganization(id: uuid.uuidString.lowercased(),
                                      name: rawName.isEmpty ? "Unnamed organization" : rawName,
                                      canChat: capabilities.map { $0.contains("chat") })
        }
        // Organizations that use Claude chat come first; otherwise claude.ai's order is kept.
        return organizations.filter { $0.canChat == true } + organizations.filter { $0.canChat != true }
    }

    /// The organization to use without asking: the only one, or the only one that uses Claude chat.
    static func bestGuess(_ organizations: [ClaudeOrganization]) -> ClaudeOrganization? {
        if organizations.count == 1 { return organizations[0] }
        let chat = organizations.filter { $0.canChat == true }
        return chat.count == 1 ? chat[0] : nil
    }
}

/// Tidies what people paste into the session key field.
enum SessionKeyInput {
    /// Spaces, surrounding quotes, and a whole "sessionKey=…; Path=/" cookie are reduced to just the key.
    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("sessionKey=") { value = String(value.dropFirst("sessionKey=".count)) }
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines))
    }

    /// Session keys start with "sk-ant-sid". OAuth tokens and other text don't count.
    static func looksLikeSessionKey(_ text: String) -> Bool {
        text.hasPrefix("sk-ant-sid") && text.count > 20 && WidgetConfig.isSafeSessionKey(text)
    }
}

extension UsageFetcher {
    /// Lists the organizations the session key's account belongs to. The key goes only to claude.ai.
    func organizations(sessionKey: String) async -> Result<[ClaudeOrganization], UsageError> {
        guard let request = ClaudeEndpoints.organizationsRequest(sessionKey: sessionKey) else {
            return .failure(.invalidCredentials)
        }
        switch await send(request) {
        case .ok(let data):
            do { return .success(try OrganizationParser.parse(data)) } catch { return .failure(.invalidResponse) }
        case .http(let failure):
            return .failure(ResponseClassifier.classify(failure, route: .sessionKey, now: now()))
        case .redirected:
            return .failure(.redirected)
        case .refused:
            return .failure(.requestBlocked)
        case .network:
            return .failure(.network)
        }
    }
}

/// What setup says when something goes wrong. Setup never retries by itself, so it never promises to.
enum SetupMessages {
    static func text(for error: UsageError) -> String {
        switch error {
        case .sessionKeyRejected, .tokenRejected:
            return "claude.ai didn't accept this key. Sign in to claude.ai again, then copy the new sessionKey."
        case .invalidCredentials:
            return "That doesn't look like a complete session key. Copy the whole value of sessionKey and paste it again."
        case .invalidOrganizationId, .noCredentials:
            return "That organization ID didn't work. Choose another organization, or check the ID you entered."
        case .rateLimited:
            return "claude.ai asked the app to slow down. Wait a minute and try again, or save now and let the app check later."
        case .network:
            return "Couldn't reach claude.ai. Check your internet connection, then try again."
        case .blockedByCloudflare:
            return "claude.ai showed a bot check. Open claude.ai in your browser, then try again."
        case .keychain:
            return "Couldn't save to your keychain. Try again, or restart your Mac if it keeps happening."
        case .fallbackFailed(_, let session):
            return text(for: session)
        case .tokenCannotReadUsage, .accessDenied, .http, .invalidResponse, .redirected, .requestBlocked:
            return "claude.ai answered in an unexpected way. Try again in a minute."
        }
    }

    /// Temporary problems can be saved anyway and checked later. A rejected key, a wrong organization, or a keychain
    /// failure can't.
    static func canSaveAnyway(after error: UsageError) -> Bool {
        RefreshPolicy.keepsLastReport(after: error) && ProblemCause(error) != .keychain
            && error != .redirected && error != .requestBlocked
    }
}
