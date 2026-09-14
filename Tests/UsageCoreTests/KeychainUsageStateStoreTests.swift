import XCTest
@testable import UsageCore

/// Integration tests against the real login keychain, using a throwaway service name per test.
final class KeychainUsageStateStoreTests: XCTestCase {
    var store: KeychainUsageStateStore!
    let state = SharedUsageState(refreshSeconds: 120, snapshot: UsageSnapshot(fiveHourPercent: 42),
                                 fetchedAt: Date(timeIntervalSince1970: 1_789_416_000))

    override func setUpWithError() throws {
        KeychainCredentialStore.preventKeychainDialogs()
        store = KeychainUsageStateStore(service: "dev.huan.ClaudeUsageWidget.tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? store.delete()
    }

    func testLoadReturnsNilWhenNothingIsStored() {
        XCTAssertNil(store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        try store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testSavingAgainUpdatesTheItemInPlace() throws {
        try store.save(state)
        var newer = state
        newer.snapshot = UsageSnapshot(fiveHourPercent: 43)
        try store.save(newer)
        XCTAssertEqual(store.load(), newer)
    }

    func testDeleteRemovesTheItemAndIsIdempotent() throws {
        try store.save(state)
        try store.delete()
        XCTAssertNil(store.load())
        XCTAssertNoThrow(try store.delete())
    }

    func testCredentialsAndUsageStateAreSeparateItems() throws {
        let service = "dev.huan.ClaudeUsageWidget.tests-\(UUID().uuidString)"
        let credentials = KeychainCredentialStore(service: service)
        let usage = KeychainUsageStateStore(service: service)
        defer { try? credentials.delete(); try? usage.delete() }
        try credentials.save(WidgetConfig(oauthToken: "dummy"))
        try usage.save(state)
        XCTAssertEqual(try credentials.load(), WidgetConfig(oauthToken: "dummy"))
        XCTAssertEqual(usage.load(), state)
    }
}
