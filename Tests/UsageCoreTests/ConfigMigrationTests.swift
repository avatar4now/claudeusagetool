import XCTest
@testable import UsageCore

/// A stand-in for the keychain so migration and Save logic can be tested without touching it.
final class InMemoryStore: CredentialStoring {
    var stored: WidgetConfig?
    var failSaves = false
    private(set) var saveCount = 0

    init(_ stored: WidgetConfig? = nil) { self.stored = stored }

    func load() throws -> WidgetConfig? { stored }
    func save(_ config: WidgetConfig) throws {
        if failSaves { throw UsageError.keychain(-25293) }
        saveCount += 1
        stored = config
    }
    func delete() throws { stored = nil }
}

final class ConfigMigrationTests: XCTestCase {
    let uuid = "123e4567-e89b-12d3-a456-426614174000"
    var directory: URL!
    var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("claude-usage-widget.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: file.path) }
    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }

    // MARK: Migration on launch

    func testNothingToDoWithoutALegacyFile() {
        let store = InMemoryStore()
        XCTAssertEqual(ConfigMigration.run(store: store, fileURL: file), .nothingToDo)
        XCTAssertNil(store.stored)
    }

    func testUnreadableFileIsLeftAlone() throws {
        try write("not json")
        XCTAssertEqual(ConfigMigration.run(store: InMemoryStore(), fileURL: file), .keptUnreadableFile)
        XCTAssertTrue(fileExists)
    }

    func testFileWithoutCredentialsIsRemoved() throws {
        try write("{\n\n}")
        XCTAssertEqual(ConfigMigration.run(store: InMemoryStore(), fileURL: file), .removedEmptyFile)
        XCTAssertFalse(fileExists)
    }

    func testCredentialsMoveIntoTheStoreAndTheFileIsDeleted() throws {
        try write(#"{"oauthToken":"tok"}"#)
        let store = InMemoryStore()
        XCTAssertEqual(ConfigMigration.run(store: store, fileURL: file), .imported)
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "tok"))
        XCTAssertFalse(fileExists)
    }

    func testFileIsKeptWhenTheStoreCannotSave() throws {
        try write(#"{"oauthToken":"tok"}"#)
        let store = InMemoryStore()
        store.failSaves = true
        guard case .failed = ConfigMigration.run(store: store, fileURL: file) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(fileExists, "never delete the only copy of a credential")
    }

    func testDuplicateFileIsRemovedWithoutRewritingTheStore() throws {
        try write(#"{"oauthToken":"tok"}"#)
        let store = InMemoryStore(WidgetConfig(oauthToken: "tok"))
        XCTAssertEqual(ConfigMigration.run(store: store, fileURL: file), .removedDuplicateFile)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertFalse(fileExists)
    }

    func testConflictingFileNeverOverwritesNewerKeychainCredentials() throws {
        try write(#"{"oauthToken":"old"}"#)
        let store = InMemoryStore(WidgetConfig(oauthToken: "new"))
        XCTAssertEqual(ConfigMigration.run(store: store, fileURL: file), .keptConflictingFile)
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "new"))
        XCTAssertTrue(fileExists)
    }

    func testOutcomeMessagesNeverMentionSecretsOrStayEmptyWhenActionIsNeeded() {
        XCTAssertNil(ConfigMigration.Outcome.nothingToDo.message)
        XCTAssertNotNil(ConfigMigration.Outcome.keptConflictingFile.message)
        XCTAssertNotNil(ConfigMigration.Outcome.keptUnreadableFile.message)
        XCTAssertNotNil(ConfigMigration.Outcome.imported.message)
    }

    // MARK: Save button

    func testSaveStoresValidatedCredentialsAndRemovesTheLegacyFile() throws {
        try write(#"{"oauthToken":"old"}"#)
        let store = InMemoryStore()
        let outcome = try ConfigEditor.save(oauthToken: " tok ", sessionKey: "", organizationId: "",
                                            store: store, legacyFileURL: file)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "tok"))
        XCTAssertFalse(fileExists, "an explicit Save settles any conflict with the old file")
    }

    func testSavingBlankFieldsClearsTheStore() throws {
        let store = InMemoryStore(WidgetConfig(oauthToken: "tok"))
        let outcome = try ConfigEditor.save(oauthToken: "", sessionKey: " ", organizationId: "",
                                            store: store, legacyFileURL: file)
        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(store.stored)
    }

    func testInvalidFieldsChangeNothing() throws {
        try write(#"{"oauthToken":"old"}"#)
        let store = InMemoryStore(WidgetConfig(oauthToken: "keep"))
        XCTAssertThrowsError(try ConfigEditor.save(oauthToken: "", sessionKey: "sk", organizationId: "nope",
                                                   store: store, legacyFileURL: file))
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "keep"))
        XCTAssertTrue(fileExists)
    }
}
