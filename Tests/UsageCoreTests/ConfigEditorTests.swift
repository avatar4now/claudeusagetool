import XCTest
@testable import UsageCore

/// A stand-in for the keychain so Save logic can be tested without touching it.
final class InMemoryStore: CredentialStoring {
    var stored: WidgetConfig?
    var failSaves = false

    init(_ stored: WidgetConfig? = nil) { self.stored = stored }

    func load() throws -> WidgetConfig? { stored }
    func save(_ config: WidgetConfig) throws {
        if failSaves { throw UsageError.keychain(-25293) }
        stored = config
    }
    func delete() throws { stored = nil }
}

final class ConfigEditorTests: XCTestCase {
    func testSaveStoresValidatedCredentialsWithANewGeneration() throws {
        let store = InMemoryStore()
        let outcome = try ConfigEditor.save(oauthToken: " tok ", sessionKey: "", organizationId: "", store: store,
                                            makeGeneration: { "gen-1" })
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "tok", generation: "gen-1"))
    }

    func testEverySaveStartsANewGeneration() throws {
        let store = InMemoryStore()
        _ = try ConfigEditor.save(oauthToken: "tok", sessionKey: "", organizationId: "", store: store)
        let first = store.stored?.generation
        _ = try ConfigEditor.save(oauthToken: "tok", sessionKey: "", organizationId: "", store: store)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, store.stored?.generation, "cached numbers from the old credentials must not be reused")
    }

    func testSavingBlankFieldsClearsTheStore() throws {
        let store = InMemoryStore(WidgetConfig(oauthToken: "tok"))
        let outcome = try ConfigEditor.save(oauthToken: "", sessionKey: " ", organizationId: "", store: store)
        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(store.stored)
    }

    func testInvalidFieldsChangeNothing() {
        let store = InMemoryStore(WidgetConfig(oauthToken: "keep"))
        XCTAssertThrowsError(try ConfigEditor.save(oauthToken: "", sessionKey: "sk", organizationId: "nope", store: store))
        XCTAssertEqual(store.stored, WidgetConfig(oauthToken: "keep"))
    }
}
