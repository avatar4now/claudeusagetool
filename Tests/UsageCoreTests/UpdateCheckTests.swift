import XCTest
@testable import UsageCore

final class UpdateCheckTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Which repository this copy came from

    func testReadsGitHubRemotesInBothForms() {
        XCTAssertEqual(SourceRepository(remote: "https://github.com/someone/claudeusagetool.git")?.path, "someone/claudeusagetool")
        XCTAssertEqual(SourceRepository(remote: "https://github.com/someone/claudeusagetool")?.path, "someone/claudeusagetool")
        XCTAssertEqual(SourceRepository(remote: "git@github.com:some-one/claude.usage_tool.git")?.path, "some-one/claude.usage_tool")
        XCTAssertEqual(SourceRepository(remote: "someone/claudeusagetool")?.path, "someone/claudeusagetool", "the form Info.plist stores")
    }

    func testNeverKeepsCredentialsOrOtherHosts() {
        XCTAssertEqual(SourceRepository(remote: "https://x-access-token:abc123@github.com/someone/tool.git")?.path, "someone/tool",
                       "a token in the remote is dropped")
        XCTAssertNil(SourceRepository(remote: "https://gitlab.com/someone/tool.git"))
        XCTAssertNil(SourceRepository(remote: "https://github.com/someone"))
        XCTAssertNil(SourceRepository(remote: "https://github.com/someone/tool/extra"))
        XCTAssertNil(SourceRepository(remote: "https://github.com/some one/tool"))
        XCTAssertNil(SourceRepository(remote: ""))
        XCTAssertNil(SourceRepository(remote: "$(CUW_SOURCE_REPO)"))
    }

    func testAddressesPointAtThatRepository() throws {
        let repository = try XCTUnwrap(SourceRepository(remote: "someone/tool"))
        XCTAssertEqual(repository.latestReleaseURL.absoluteString, "https://api.github.com/repos/someone/tool/releases/latest")
        XCTAssertEqual(repository.releasesPage.absoluteString, "https://github.com/someone/tool/releases")
    }

    // MARK: Reading a release

    func testParsesTheLatestRelease() throws {
        let json = #"{"tag_name":"v1.7","name":"Better charts","html_url":"https://github.com/someone/tool/releases/tag/v1.7","published_at":"2026-10-01T12:00:00Z","body":"notes"}"#
        let release = try UpdateCheck.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, "1.7")
        XCTAssertEqual(release.title, "Better charts")
        XCTAssertEqual(release.page?.absoluteString, "https://github.com/someone/tool/releases/tag/v1.7")
        XCTAssertNotNil(release.publishedAt)
    }

    func testIgnoresReleasePagesOffGitHub() throws {
        let json = #"{"tag_name":"1.7","html_url":"https://evil.example/download"}"#
        let release = try UpdateCheck.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, "1.7")
        XCTAssertNil(release.page, "only github.com pages are opened")
    }

    func testRejectsRepliesWithoutAVersion() {
        XCTAssertThrowsError(try UpdateCheck.parseRelease(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertThrowsError(try UpdateCheck.parseRelease(Data(#"{"tag_name":"latest-build"}"#.utf8)))
        XCTAssertThrowsError(try UpdateCheck.parseRelease(Data("nope".utf8)))
    }

    // MARK: Comparing versions

    func testComparesVersionsNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer("1.7", than: "1.6"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10", than: "1.9"), "not alphabetical")
        XCTAssertTrue(UpdateCheck.isNewer("2.0", than: "1.99.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.6.1", than: "1.6"))
        XCTAssertFalse(UpdateCheck.isNewer("1.6", than: "1.6.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.6", than: "1.6"))
        XCTAssertFalse(UpdateCheck.isNewer("1.5", than: "1.6"))
        XCTAssertFalse(UpdateCheck.isNewer("1.7", than: "?"), "an unknown current version never shows an update")
    }

    func testVersionTextAcceptsATagPrefix() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v1.7"), "1.7")
        XCTAssertEqual(UpdateCheck.version(fromTag: "V2.0.1"), "2.0.1")
        XCTAssertEqual(UpdateCheck.version(fromTag: "1.7"), "1.7")
        XCTAssertNil(UpdateCheck.version(fromTag: "release"))
        XCTAssertNil(UpdateCheck.version(fromTag: "v1..7"))
    }

    // MARK: How often

    func testChecksAtMostOnceADay() {
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-86_401), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(86_400 * 3), now: now), "a clock set back doesn't block checks")
    }
}
