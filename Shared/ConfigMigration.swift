import Foundation
import Darwin

/// The plaintext file v1.0 used, ~/.claude/claude-usage-widget.json. Now it is only read once, to migrate away from it.
enum LegacyConfigFile {
    /// Uses the account's real home folder. Inside the sandbox, the usual home-folder API returns the app's container.
    static var url: URL {
        let home: URL
        if let passwd = getpwuid(getuid()) {
            home = URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".claude/claude-usage-widget.json", isDirectory: false)
    }

    enum State: Equatable {
        case absent
        case unreadable
        case empty
        case credentials(WidgetConfig)
    }

    static func inspect(at url: URL = url) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let config = try? WidgetConfig.decode(data) else {
            return .unreadable
        }
        guard !config.isEmpty else { return .empty }
        // Apply the same rules as Save, so a tampered file can't slip malformed values into the keychain.
        guard let valid = try? config.validated() else { return .unreadable }
        return .credentials(valid)
    }

    static func remove(at url: URL = url) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone, which is the goal.
        }
    }
}

/// Runs once when the app opens: moves credentials out of the v1.0 file and into the keychain.
enum ConfigMigration {
    enum Outcome: Equatable {
        case nothingToDo
        case removedEmptyFile
        case imported
        case removedDuplicateFile
        case keptConflictingFile
        case keptUnreadableFile
        case failed(String)

        /// Text for the app's status line, or nil when there is nothing worth saying.
        var message: String? {
            switch self {
            case .nothingToDo, .removedEmptyFile, .removedDuplicateFile:
                return nil
            case .imported:
                return "Moved your credentials from the old config file into the keychain and deleted the file."
            case .keptConflictingFile:
                return "An old config file has different credentials. Click Save to keep what's shown and delete it."
            case .keptUnreadableFile:
                return "The old config file was unreadable or had invalid values, so it was left in place."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// The file is deleted only after the store holds an identical copy, and existing keychain credentials are never overwritten.
    static func run(store: CredentialStoring, fileURL: URL = LegacyConfigFile.url) -> Outcome {
        switch LegacyConfigFile.inspect(at: fileURL) {
        case .absent:
            return .nothingToDo
        case .unreadable:
            return .keptUnreadableFile
        case .empty:
            return removing(fileURL, then: .removedEmptyFile)
        case .credentials(let fileConfig):
            do {
                if let existing = try store.load(), !existing.isEmpty {
                    return existing == fileConfig ? removing(fileURL, then: .removedDuplicateFile) : .keptConflictingFile
                }
                try store.save(fileConfig)
                guard try store.load() == fileConfig else {
                    return .failed("The keychain copy didn't match, so the old config file was kept.")
                }
                return removing(fileURL, then: .imported)
            } catch {
                return .failed("Couldn't move credentials into the keychain, so the old config file was kept.")
            }
        }
    }

    private static func removing(_ url: URL, then outcome: Outcome) -> Outcome {
        do {
            try LegacyConfigFile.remove(at: url)
            return outcome
        } catch {
            return .failed("Couldn't delete the old config file at ~/.claude/claude-usage-widget.json.")
        }
    }
}

/// What the app's Save button does.
enum ConfigEditor {
    enum Outcome: Equatable {
        case saved
        case cleared
    }

    /// Validates the fields, then stores them, or clears the store when every field is blank.
    /// A successful Save also deletes the v1.0 file, since the user just confirmed what the credentials should be.
    static func save(oauthToken: String, sessionKey: String, organizationId: String,
                     store: CredentialStoring, legacyFileURL: URL = LegacyConfigFile.url) throws -> Outcome {
        let config = try WidgetConfig.fromFields(oauthToken: oauthToken, sessionKey: sessionKey,
                                                 organizationId: organizationId)
        let outcome: Outcome
        if config.isEmpty {
            try store.delete()
            outcome = .cleared
        } else {
            try store.save(config)
            outcome = .saved
        }
        try LegacyConfigFile.remove(at: legacyFileURL)
        return outcome
    }
}
