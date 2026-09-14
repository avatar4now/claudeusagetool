import XCTest
@testable import UsageCore

final class UsageFetchingTests: XCTestCase {
    let upper = "123E4567-E89B-12D3-A456-426614174000"
    let okBody = Data(#"{"five_hour":{"utilization":42,"resets_at":"2026-09-14T20:00:00.000Z"},"seven_day":{"utilization":7}}"#.utf8)

    // MARK: Endpoints

    func testOAuthRequestTargetsAnthropicWithBearerToken() throws {
        let request = try XCTUnwrap(ClaudeEndpoints.oauthRequest(token: "tok"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSessionKeyRequestBuildsTheURLFromAParsedUUIDOnly() throws {
        let request = try XCTUnwrap(ClaudeEndpoints.sessionKeyRequest(sessionKey: "sk", organizationId: upper))
        XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/organizations/\(upper.lowercased())/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk")
        for bad in ["../../x", "abc/usage", "\(upper)/../../other", "\(upper)?a=b", ""] {
            XCTAssertNil(ClaudeEndpoints.sessionKeyRequest(sessionKey: "sk", organizationId: bad), bad)
        }
    }

    func testEndpointsRefuseCredentialsThatCouldBreakHeaders() {
        XCTAssertNil(ClaudeEndpoints.oauthRequest(token: "tok\r\nX-Injected: 1"))
        XCTAssertNil(ClaudeEndpoints.oauthRequest(token: "tok en"))
        XCTAssertNil(ClaudeEndpoints.sessionKeyRequest(sessionKey: "a;b", organizationId: upper))
        XCTAssertNil(ClaudeEndpoints.sessionKeyRequest(sessionKey: "a\nb", organizationId: upper))
    }

    // MARK: Parsing

    func testParsesIntegerAndDecimalUtilization() throws {
        let snapshot = try UsageParser.parse(Data(#"{"five_hour":{"utilization":42.5},"seven_day":{"utilization":7}}"#.utf8))
        XCTAssertEqual(snapshot.fiveHourPercent, 42.5)
        XCTAssertEqual(snapshot.weeklyPercent, 7)
    }

    func testParsesResetTimesWithAndWithoutFractionalSecondsAndAsEpoch() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"five_hour":{"utilization":1,"resets_at":"2026-09-14T20:00:00.123Z"},
         "seven_day":{"utilization":2,"resets_at":"2026-09-14T20:00:00Z"}}
        """.utf8))
        XCTAssertNotNil(snapshot.fiveHourResetsAt)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 1_789_416_000))
        let epoch = try UsageParser.parse(Data(#"{"five_hour":{"utilization":1,"resets_at":1789416000}}"#.utf8))
        XCTAssertEqual(epoch.fiveHourResetsAt, Date(timeIntervalSince1970: 1_789_416_000))
    }

    func testMissingOrMalformedValuesBecomeUnknownNotZero() throws {
        let snapshot = try UsageParser.parse(Data(#"{"five_hour":{"utilization":false},"seven_day":{"utilization":21}}"#.utf8))
        XCTAssertNil(snapshot.fiveHourPercent)
        XCTAssertEqual(snapshot.weeklyPercent, 21)
    }

    /// Mirrors how Claude Code's /usage screen reads model-specific weekly limits.
    func testParsesFableWeeklyFromTheScopedLimitsList() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"five_hour":{"utilization":12},
         "limits":[
          {"kind":"spend","percent":98},
          {"kind":"weekly_scoped","percent":70,"scope":{"model":{"display_name":"Opus"}}},
          {"kind":"weekly_scoped","percent":61.5,"resets_at":"2026-09-18T12:00:00Z",
           "scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8))
        XCTAssertEqual(snapshot.fableWeeklyPercent, 61.5)
        XCTAssertEqual(snapshot.fableWeeklyResetsAt, Date(timeIntervalSince1970: 1_789_732_800))
    }

    func testFableModelNameMatchesCaseInsensitively() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"limits":[{"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"fable 5.1"}}}]}
        """.utf8))
        XCTAssertEqual(snapshot.fableWeeklyPercent, 0, "a Fable limit alone still counts as usage")
    }

    func testFableIsUnknownWhenTheResponseHasNoFableLimit() throws {
        let snapshot = try UsageParser.parse(okBody)
        XCTAssertNil(snapshot.fableWeeklyPercent)
        XCTAssertNil(snapshot.fableWeeklyResetsAt)
    }

    func testRejectsResponsesWithoutAnyUsage() {
        let bodies = ["{}", "[]", "null", #"{"five_hour":null,"seven_day":{}}"#,
                      #"{"limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]}"#]
        for body in bodies {
            XCTAssertThrowsError(try UsageParser.parse(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? UsageError, .invalidResponse)
            }
        }
    }

    // MARK: Errors

    func testErrorMessagesAreShortFixedStrings() {
        let all: [UsageError] = [.noCredentials, .tokenRejected, .tokenCannotReadUsage, .sessionKeyRejected,
                                 .http(429), .http(503), .network, .invalidResponse, .invalidOrganizationId,
                                 .invalidCredentials, .keychain(-25293)]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertLessThan(error.message.count, 80, error.message)
        }
        XCTAssertTrue(UsageError.http(503).message.contains("503"))
    }

    func testCredentialErrorsSayWhatToDoNext() {
        XCTAssertTrue(UsageError.tokenCannotReadUsage.message.localizedCaseInsensitiveContains("session key"))
        XCTAssertTrue(UsageError.sessionKeyRejected.message.localizedCaseInsensitiveContains("session key"))
        XCTAssertTrue(UsageError.tokenRejected.message.contains("401"))
    }

    // MARK: Policies (tune these if needed, then update the expectations)

    func testFallsBackToTheSessionKeyOnlyWhenTheOAuthCredentialItselfIsRefused() {
        XCTAssertTrue(FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: .http(401)))
        XCTAssertTrue(FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: .http(403)))
        XCTAssertFalse(FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: .network))
        XCTAssertFalse(FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: .http(429)))
        XCTAssertFalse(FallbackPolicy.shouldTrySessionKey(afterOAuthFailure: .http(500)))
    }

    func testTemporaryProblemsKeepTheLastNumbersButCredentialProblemsClearThem() {
        XCTAssertTrue(RefreshPolicy.keepsLastReport(after: .network))
        XCTAssertTrue(RefreshPolicy.keepsLastReport(after: .http(429)))
        XCTAssertTrue(RefreshPolicy.keepsLastReport(after: .http(503)))
        XCTAssertFalse(RefreshPolicy.keepsLastReport(after: .noCredentials))
        XCTAssertFalse(RefreshPolicy.keepsLastReport(after: .sessionKeyRejected))
        XCTAssertFalse(RefreshPolicy.keepsLastReport(after: .tokenCannotReadUsage))
    }

    // MARK: Orchestration

    final class Recorder {
        var requests: [URLRequest] = []
        var responses: [Result<Data, UsageError>]
        init(_ responses: [Result<Data, UsageError>]) { self.responses = responses }
        var fetcher: UsageFetcher {
            UsageFetcher { request in
                self.requests.append(request)
                return self.responses.isEmpty ? .failure(.network) : self.responses.removeFirst()
            }
        }
        var hosts: [String] { requests.compactMap { $0.url?.host } }
    }

    var both: WidgetConfig { WidgetConfig(oauthToken: "tok", sessionKey: "sk", organizationId: upper) }

    func testNoCredentialsMakesNoRequest() async {
        let recorder = Recorder([])
        let result = await recorder.fetcher.fetch(config: WidgetConfig())
        XCTAssertEqual(result.failure, .noCredentials)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testOAuthSuccessUsesOnlyTheAnthropicAPI() async {
        let recorder = Recorder([.success(okBody)])
        let report = await recorder.fetcher.fetch(config: both).success
        XCTAssertEqual(report?.snapshot.fiveHourPercent, 42)
        XCTAssertEqual(report?.route, .oauthToken)
        XCTAssertNil(report?.tokenFailure)
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com"])
    }

    func testTokenThatCannotReadUsageFallsBackToTheSessionKeyAndSaysWhy() async {
        let recorder = Recorder([.failure(.http(403)), .success(okBody)])
        let report = await recorder.fetcher.fetch(config: both).success
        XCTAssertEqual(report?.snapshot.weeklyPercent, 7)
        XCTAssertEqual(report?.route, .sessionKey)
        XCTAssertEqual(report?.tokenFailure, .tokenCannotReadUsage)
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com", "claude.ai"])
    }

    func testTokenOnlyFailuresAreNamedByCause() async {
        let forbidden = await Recorder([.failure(.http(403))]).fetcher.fetch(config: WidgetConfig(oauthToken: "tok"))
        XCTAssertEqual(forbidden.failure, .tokenCannotReadUsage)
        let rejected = await Recorder([.failure(.http(401))]).fetcher.fetch(config: WidgetConfig(oauthToken: "tok"))
        XCTAssertEqual(rejected.failure, .tokenRejected)
    }

    func testNetworkFailureDoesNotSpendTheSessionKey() async {
        let recorder = Recorder([.failure(.network)])
        let result = await recorder.fetcher.fetch(config: both)
        XCTAssertEqual(result.failure, .network)
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com"])
    }

    func testWhenBothRoutesFailTheSessionKeyErrorIsShown() async {
        // The fallback only runs once the token is known not to work, so the session key is what still needs fixing.
        let recorder = Recorder([.failure(.http(403)), .failure(.http(403))])
        let result = await recorder.fetcher.fetch(config: both)
        XCTAssertEqual(result.failure, .sessionKeyRejected)
    }

    func testSessionKeyAloneIsUsedDirectly() async {
        let recorder = Recorder([.success(okBody)])
        let report = await recorder.fetcher.fetch(config: WidgetConfig(sessionKey: "sk", organizationId: upper)).success
        XCTAssertEqual(report?.route, .sessionKey)
        XCTAssertNil(report?.tokenFailure)
        XCTAssertEqual(recorder.hosts, ["claude.ai"])
    }

    func testExpiredSessionKeyIsNamedAndOtherFailuresPassThrough() async {
        let config = WidgetConfig(sessionKey: "sk", organizationId: upper)
        for code in [401, 403] {
            let result = await Recorder([.failure(.http(code))]).fetcher.fetch(config: config)
            XCTAssertEqual(result.failure, .sessionKeyRejected, "HTTP \(code)")
        }
        let limited = await Recorder([.failure(.http(429))]).fetcher.fetch(config: config)
        XCTAssertEqual(limited.failure, .http(429))
    }

    func testStoredOrganizationIdThatIsNotAUUIDIsNeverSent() async {
        let recorder = Recorder([.success(okBody)])
        let result = await recorder.fetcher.fetch(config: WidgetConfig(sessionKey: "sk", organizationId: "../evil"))
        XCTAssertEqual(result.failure, .invalidOrganizationId)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testStoredCredentialsThatCouldBreakHeadersAreNeverSent() async {
        let recorder = Recorder([.success(okBody), .success(okBody)])
        let badToken = await recorder.fetcher.fetch(config: WidgetConfig(oauthToken: "tok\r\nX-Injected: 1"))
        XCTAssertEqual(badToken.failure, .invalidCredentials)
        let badKey = await recorder.fetcher.fetch(config: WidgetConfig(sessionKey: "a;b", organizationId: upper))
        XCTAssertEqual(badKey.failure, .invalidCredentials)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUnparseableSuccessBodyIsReportedAsInvalidResponse() async {
        let recorder = Recorder([.success(Data("{}".utf8))])
        let result = await recorder.fetcher.fetch(config: WidgetConfig(oauthToken: "tok"))
        XCTAssertEqual(result.failure, .invalidResponse)
    }
}

extension Result {
    var success: Success? { if case .success(let value) = self { return value } else { return nil } }
    var failure: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
