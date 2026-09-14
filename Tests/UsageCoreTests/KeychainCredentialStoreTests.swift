import XCTest
@testable import UsageCore

/// Integration tests against the real login keychain, using a throwaway service name per test.
/// Every item is deleted in tearDown. Dialogs are disabled so nothing can pop up on screen.
final class KeychainCredentialStoreTests: XCTestCase {
    var store: KeychainCredentialStore!

    override func setUpWithError() throws {
        KeychainCredentialStore.preventKeychainDialogs()
        store = KeychainCredentialStore(service: "dev.huan.ClaudeUsageWidget.tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? store.delete()
    }

    func testLoadReturnsNilWhenNothingIsStored() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let config = WidgetConfig(oauthToken: "dummy-token-for-tests")
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }

    func testSaveReplacesTheExistingItem() throws {
        try store.save(WidgetConfig(oauthToken: "first"))
        try store.save(WidgetConfig(oauthToken: "second"))
        XCTAssertEqual(try store.load(), WidgetConfig(oauthToken: "second"))
    }

    func testDeleteRemovesTheItemAndIsIdempotent() throws {
        try store.save(WidgetConfig(oauthToken: "dummy"))
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete())
    }

    func testFailedSaveLeavesThePreviousItemIntact() throws {
        try store.save(WidgetConfig(oauthToken: "keep"))
        var broken = store!
        broken.trustedBundleURLs = [URL(fileURLWithPath: "/nonexistent/Missing.appex")]
        XCTAssertThrowsError(try broken.save(WidgetConfig(oauthToken: "replace")))
        XCTAssertEqual(try store.load(), WidgetConfig(oauthToken: "keep"))
    }
}
