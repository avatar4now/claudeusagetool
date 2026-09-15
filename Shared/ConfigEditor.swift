import Foundation

/// What the app's Save button does.
enum ConfigEditor {
    enum Outcome: Equatable {
        case saved
        case cleared
    }

    /// Validates the fields, then stores them with a fresh credential generation, or clears the store when
    /// every field is blank. The generation lets the app and widget tell numbers fetched with these credentials
    /// apart from numbers fetched with earlier ones, without storing anything secret next to the numbers.
    static func save(oauthToken: String, sessionKey: String, organizationId: String,
                     store: CredentialStoring,
                     makeGeneration: () -> String = { UUID().uuidString }) throws -> Outcome {
        var config = try WidgetConfig.fromFields(oauthToken: oauthToken, sessionKey: sessionKey,
                                                 organizationId: organizationId)
        guard !config.isEmpty else {
            try store.delete()
            return .cleared
        }
        config.generation = makeGeneration()
        try store.save(config)
        return .saved
    }
}
