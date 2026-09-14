import XCTest
@testable import UsageCore

/// Only ever touches a temporary directory. Never reads ~/.claude.
final class LegacyConfigFileTests: XCTestCase {
    var directory: URL!
    var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("claude-usage-widget.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }

    func testDefaultLocationIsTheAccountHomeNotASandboxContainer() {
        let path = LegacyConfigFile.url.path
        XCTAssertTrue(path.hasSuffix("/.claude/claude-usage-widget.json"), path)
        XCTAssertFalse(path.contains("/Library/Containers/"), path)
    }

    func testInspectReportsAbsentFile() {
        XCTAssertEqual(LegacyConfigFile.inspect(at: file), .absent)
    }

    func testInspectReportsUnreadableContent() throws {
        for text in ["null", "not json", "[1]"] {
            try write(text)
            XCTAssertEqual(LegacyConfigFile.inspect(at: file), .unreadable, text)
        }
    }

    func testInspectReportsEmptyWhenThereIsNoCredential() throws {
        for text in ["{\n\n}", #"{"organizationId":"x"}"#, #"{"oauthToken":"   "}"#] {
            try write(text)
            XCTAssertEqual(LegacyConfigFile.inspect(at: file), .empty, text)
        }
    }

    func testInspectReturnsCredentials() throws {
        try write(#"{"oauthToken":"tok"}"#)
        XCTAssertEqual(LegacyConfigFile.inspect(at: file), .credentials(WidgetConfig(oauthToken: "tok")))
    }

    func testRemoveDeletesTheFileAndIsIdempotent() throws {
        try write("{}")
        try LegacyConfigFile.remove(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNoThrow(try LegacyConfigFile.remove(at: file))
    }
}
