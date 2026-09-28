import XCTest
@testable import UsageCore

final class BuildInfoTests: XCTestCase {
    /// What scripts/update-app.sh puts in the app's Info.plist.
    let scriptBuild: [String: Any] = [
        "CFBundleShortVersionString": "1.5",
        "CFBundleVersion": "5",
        "CUWBuildCommit": "0614b21",
        "CUWBuildBranch": "forecast-and-warnings",
        "CUWBuildDate": "2026-09-15T19:04:11Z"
    ]

    func testReadsEveryValueFromTheInfoDictionary() {
        let info = BuildInfo(infoDictionary: scriptBuild)
        XCTAssertEqual(info.version, "1.5")
        XCTAssertEqual(info.build, "5")
        XCTAssertEqual(info.commit, "0614b21")
        XCTAssertEqual(info.branch, "forecast-and-warnings")
        XCTAssertEqual(info.builtAt, Date(timeIntervalSince1970: 1_789_499_051))
    }

    func testAPlainXcodeBuildHasNoCommitBranchOrDate() {
        // Xcode expands the empty default build settings to empty strings.
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.5", "CFBundleVersion": "5",
            "CUWBuildCommit": "", "CUWBuildBranch": "", "CUWBuildDate": ""
        ])
        XCTAssertNil(info.commit)
        XCTAssertNil(info.branch)
        XCTAssertNil(info.builtAt)
    }

    func testWhitespaceAndUnexpandedSettingsCountAsMissing() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "  ", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "CUWBuildCommit": "$(CUW_BUILD_COMMIT)", "CUWBuildBranch": " \n", "CUWBuildDate": "$(CUW_BUILD_DATE)"
        ])
        XCTAssertEqual(info.version, "?")
        XCTAssertEqual(info.build, "?")
        XCTAssertNil(info.commit)
        XCTAssertNil(info.branch)
        XCTAssertNil(info.builtAt)
    }

    func testTrimsSurroundingWhitespace() {
        let info = BuildInfo(infoDictionary: ["CUWBuildCommit": " 0614b21\n", "CUWBuildBranch": " main "])
        XCTAssertEqual(info.commit, "0614b21")
        XCTAssertEqual(info.branch, "main")
    }

    func testMissingOrWrongTypedValuesFallBack() {
        let none = BuildInfo(infoDictionary: nil)
        XCTAssertEqual(none.version, "?")
        XCTAssertEqual(none.build, "?")
        XCTAssertNil(none.commit)
        XCTAssertNil(none.branch)
        XCTAssertNil(none.builtAt)

        let wrongTypes = BuildInfo(infoDictionary: ["CFBundleVersion": 5, "CUWBuildCommit": 42])
        XCTAssertEqual(wrongTypes.build, "?")
        XCTAssertNil(wrongTypes.commit)
    }

    func testADateThatIsNotISO8601IsIgnored() {
        XCTAssertNil(BuildInfo(infoDictionary: ["CUWBuildDate": "yesterday"]).builtAt)
        XCTAssertNil(BuildInfo(infoDictionary: ["CUWBuildDate": "2026-09-15"]).builtAt)
    }

    func testVersionText() {
        XCTAssertEqual(BuildInfo(infoDictionary: scriptBuild).versionText, "Version 1.5 (5)")
        XCTAssertEqual(BuildInfo(infoDictionary: nil).versionText, "Version ? (?)")
    }

    func testShortTextAddsTheCommitWhenThereIsOne() {
        XCTAssertEqual(BuildInfo(infoDictionary: scriptBuild).shortText, "Version 1.5 (5) · 0614b21")

        var noCommit = scriptBuild
        noCommit["CUWBuildCommit"] = ""
        XCTAssertEqual(BuildInfo(infoDictionary: noCommit).shortText, "Version 1.5 (5)")
    }

    func testACommitWithUncommittedChangesIsMarkedModified() {
        var modified = scriptBuild
        modified["CUWBuildCommit"] = "0614b21-modified"
        let info = BuildInfo(infoDictionary: modified)
        XCTAssertTrue(info.isModified)
        XCTAssertEqual(info.commit, "0614b21-modified")
        XCTAssertEqual(info.displayCommit, "0614b21")
        XCTAssertEqual(info.shortText, "Version 1.5 (5) · 0614b21 (modified)")
    }

    func testACleanCommitIsNotModified() {
        let info = BuildInfo(infoDictionary: scriptBuild)
        XCTAssertFalse(info.isModified)
        XCTAssertEqual(info.displayCommit, "0614b21")

        let none = BuildInfo(infoDictionary: nil)
        XCTAssertFalse(none.isModified)
        XCTAssertNil(none.displayCommit)
    }

    func testASuffixWithNoCommitBeforeItCountsAsMissing() {
        let info = BuildInfo(infoDictionary: ["CUWBuildCommit": "-modified"])
        XCTAssertNil(info.commit)
        XCTAssertNil(info.displayCommit)
        XCTAssertFalse(info.isModified)
    }

    func testBuiltTextUsesTheGivenTimeZone() {
        let info = BuildInfo(infoDictionary: scriptBuild)
        let locale = Locale(identifier: "en_US")
        let utc = info.builtText(timeZone: TimeZone(identifier: "UTC")!, locale: locale)
        XCTAssertTrue(utc.contains("Sep 15, 2026"), utc)
        XCTAssertTrue(utc.contains("7:04"), utc)
        let chicago = info.builtText(timeZone: TimeZone(identifier: "America/Chicago")!, locale: locale)
        XCTAssertTrue(chicago.contains("2:04"), chicago)
    }

    func testBuiltTextSaysXcodeWhenThereIsNoDate() {
        XCTAssertEqual(BuildInfo(infoDictionary: nil).builtText(), "Built in Xcode")
    }

    func testReadsTheRepositoryItWasBuiltFrom() {
        XCTAssertEqual(BuildInfo(infoDictionary: ["CUWSourceRepo": "someone/tool"]).sourceRepository?.path, "someone/tool")
        XCTAssertNil(BuildInfo(infoDictionary: ["CUWSourceRepo": "$(CUW_SOURCE_REPO)"]).sourceRepository, "Xcode left it unfilled")
        XCTAssertNil(BuildInfo(infoDictionary: ["CUWSourceRepo": "  "]).sourceRepository)
        XCTAssertNil(BuildInfo(infoDictionary: nil).sourceRepository)
    }
}
