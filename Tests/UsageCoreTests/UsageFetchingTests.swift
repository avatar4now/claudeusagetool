import XCTest
@testable import UsageCore

final class UsageFetchingTests: XCTestCase {
    let upper = "123E4567-E89B-12D3-A456-426614174000"
    /// Monday 2026-09-14 20:00:00 UTC.
    let now = Date(timeIntervalSince1970: 1_789_416_000)
    let okBody = Data(#"{"five_hour":{"utilization":42,"resets_at":"2026-09-14T22:00:00.000Z"},"seven_day":{"utilization":7}}"#.utf8)

    // Response shapes seen from the real endpoints (sanitized).
    let expiredSessionBody = #"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization","details":{"error_code":"account_session_invalid","error_visibility":"user_facing"}},"request_id":null}"#
    let scopeBody = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:profile"},"request_id":null}"#
    let invalidTokenBody = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."},"request_id":null}"#
    let cloudflarePage = #"<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script src="/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"></script></body></html>"#

    func failure(_ status: Int, contentType: String? = "application/json", cf: String? = nil,
                 retryAfter: String? = nil, body: String = "") -> HTTPFailure {
        HTTPFailure(status: status, contentType: contentType, cfMitigated: cf, retryAfter: retryAfter, bodyPrefix: Data(body.utf8))
    }

    // MARK: Endpoints and destinations

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

    func testOnlyApprovedDestinationsAndCredentialPairingsAreAllowed() throws {
        let oauth = try XCTUnwrap(ClaudeEndpoints.oauthRequest(token: "tok"))
        let session = try XCTUnwrap(ClaudeEndpoints.sessionKeyRequest(sessionKey: "sk", organizationId: upper))
        XCTAssertTrue(ClaudeEndpoints.isAllowed(oauth))
        XCTAssertTrue(ClaudeEndpoints.isAllowed(session))

        var cookieToAnthropic = oauth
        cookieToAnthropic.setValue("sessionKey=sk", forHTTPHeaderField: "Cookie")
        XCTAssertFalse(ClaudeEndpoints.isAllowed(cookieToAnthropic), "the session cookie only ever goes to claude.ai")

        var bearerToClaude = session
        bearerToClaude.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(ClaudeEndpoints.isAllowed(bearerToClaude), "the OAuth token only ever goes to api.anthropic.com")

        let lower = upper.lowercased()
        for url in ["http://claude.ai/api/organizations/\(lower)/usage",
                    "https://claude.ai.evil.example/api/organizations/\(lower)/usage",
                    "https://claude.ai/api/organizations/\(lower)/members",
                    "https://claude.ai/api/organizations/not-a-uuid/usage",
                    "https://api.anthropic.com/v1/messages"] {
            XCTAssertFalse(ClaudeEndpoints.isAllowed(URLRequest(url: URL(string: url)!)), url)
        }
    }

    func testRedirectsAreRefused() {
        let delegate = RedirectRefusingDelegate()
        let done = expectation(description: "redirect decision")
        let task = URLSession.shared.dataTask(with: URL(string: "https://claude.ai")!)
        let response = HTTPURLResponse(url: URL(string: "https://claude.ai")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/login"])!
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://example.com/login")!)) { request in
            XCTAssertNil(request)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    // MARK: Parsing and validation

    func testParsesIntegerAndDecimalUtilization() throws {
        let snapshot = try UsageParser.parse(Data(#"{"five_hour":{"utilization":42.5},"seven_day":{"utilization":7}}"#.utf8), now: now)
        XCTAssertEqual(snapshot.fiveHourPercent, 42.5)
        XCTAssertEqual(snapshot.weeklyPercent, 7)
    }

    func testParsesResetTimesWithAndWithoutFractionalSecondsAndAsEpoch() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"five_hour":{"utilization":1,"resets_at":"2026-09-14T20:00:00.123Z"},
         "seven_day":{"utilization":2,"resets_at":"2026-09-14T20:00:00Z"}}
        """.utf8), now: now)
        XCTAssertNotNil(snapshot.fiveHourResetsAt)
        XCTAssertEqual(snapshot.weeklyResetsAt, now)
        let epoch = try UsageParser.parse(Data(#"{"five_hour":{"utilization":1,"resets_at":1789416000}}"#.utf8), now: now)
        XCTAssertEqual(epoch.fiveHourResetsAt, now)
    }

    func testMissingOrMalformedValuesBecomeUnknownNotZero() throws {
        let snapshot = try UsageParser.parse(Data(#"{"five_hour":{"utilization":false},"seven_day":{"utilization":21}}"#.utf8), now: now)
        XCTAssertNil(snapshot.fiveHourPercent)
        XCTAssertEqual(snapshot.weeklyPercent, 21)
    }

    func testOutOfRangePercentagesBecomeUnknownInsteadOfClamped() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"five_hour":{"utilization":140},"seven_day":{"utilization":-3},
         "limits":[{"kind":"weekly_scoped","percent":100,"scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8), now: now)
        XCTAssertNil(snapshot.fiveHourPercent, "140% must not be shown as a trustworthy 100%")
        XCTAssertNil(snapshot.weeklyPercent)
        XCTAssertEqual(snapshot.fableWeeklyPercent, 100)
    }

    func testImplausibleResetTimesBecomeUnknownButKeepThePercent() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"five_hour":{"utilization":30,"resets_at":"2026-10-04T20:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":"2026-09-11T20:00:00Z"}}
        """.utf8), now: now)
        XCTAssertEqual(snapshot.fiveHourPercent, 30)
        XCTAssertNil(snapshot.fiveHourResetsAt, "20 days ahead is not a real reset time")
        XCTAssertEqual(snapshot.weeklyPercent, 40)
        XCTAssertNil(snapshot.weeklyResetsAt, "3 days in the past is not a real reset time")
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
        """.utf8), now: now)
        XCTAssertEqual(snapshot.fableWeeklyPercent, 61.5)
        XCTAssertEqual(snapshot.fableWeeklyResetsAt, Date(timeIntervalSince1970: 1_789_732_800))
    }

    func testFableModelNameMatchesCaseInsensitively() throws {
        let snapshot = try UsageParser.parse(Data("""
        {"limits":[{"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"fable 5.1"}}}]}
        """.utf8), now: now)
        XCTAssertEqual(snapshot.fableWeeklyPercent, 0, "a Fable limit alone still counts as usage")
    }

    func testRejectsResponsesWithoutAnyUsage() {
        let bodies = ["{}", "[]", "null", #"{"five_hour":null,"seven_day":{}}"#,
                      #"{"limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]}"#]
        for body in bodies {
            XCTAssertThrowsError(try UsageParser.parse(Data(body.utf8), now: now), body) {
                XCTAssertEqual($0 as? UsageError, .invalidResponse)
            }
        }
    }

    // MARK: Classifying failures

    func testSessionRouteFailuresAreClassifiedByEvidence() {
        func classify(_ f: HTTPFailure) -> UsageError { ResponseClassifier.classify(f, route: .sessionKey, now: now) }
        XCTAssertEqual(classify(failure(403, body: expiredSessionBody)), .sessionKeyRejected)
        XCTAssertEqual(classify(failure(401, body: #"{"type":"error","error":{"type":"authentication_error","message":"Invalid authorization"}}"#)),
                       .sessionKeyRejected)
        XCTAssertEqual(classify(failure(403, contentType: "text/html", cf: "challenge", body: "<html></html>")), .blockedByCloudflare)
        XCTAssertEqual(classify(failure(403, contentType: "text/html; charset=UTF-8", body: cloudflarePage)), .blockedByCloudflare)
        XCTAssertEqual(classify(failure(403, contentType: "text/html", body: "<html>Forbidden</html>")), .accessDenied(403),
                       "an HTML page alone is not proof of a bot check")
        XCTAssertEqual(classify(failure(403, body: #"{"type":"error","error":{"type":"permission_error","message":"Nope"}}"#)),
                       .accessDenied(403), "a 403 without the expired-session marker is not a confirmed expiry")
    }

    func testTokenRouteFailuresAreClassifiedByEvidence() {
        func classify(_ f: HTTPFailure) -> UsageError { ResponseClassifier.classify(f, route: .oauthToken, now: now) }
        XCTAssertEqual(classify(failure(401, body: invalidTokenBody)), .tokenRejected)
        XCTAssertEqual(classify(failure(403, body: scopeBody)), .tokenCannotReadUsage)
        XCTAssertEqual(classify(failure(403, body: "{}")), .accessDenied(403))
        XCTAssertEqual(classify(failure(403, contentType: "text/html", cf: "challenge")), .blockedByCloudflare)
    }

    func testRateLimitsServerErrorsAndRedirects() {
        func classify(_ f: HTTPFailure) -> UsageError { ResponseClassifier.classify(f, route: .sessionKey, now: now) }
        XCTAssertEqual(classify(failure(429, retryAfter: "120")), .rateLimited(retryAfter: 120))
        XCTAssertEqual(classify(failure(429, retryAfter: "Mon, 14 Sep 2026 20:05:00 GMT")), .rateLimited(retryAfter: 300))
        XCTAssertEqual(classify(failure(429)), .rateLimited(retryAfter: nil))
        XCTAssertEqual(classify(failure(429, retryAfter: "soon")), .rateLimited(retryAfter: nil))
        XCTAssertEqual(classify(failure(503)), .http(503))
        XCTAssertEqual(classify(failure(302)), .redirected)
    }

    func testErrorMessagesAreShortFixedStrings() {
        let all: [UsageError] = [.noCredentials, .tokenRejected, .tokenCannotReadUsage, .sessionKeyRejected,
                                 .blockedByCloudflare, .accessDenied(403), .rateLimited(retryAfter: 60), .redirected,
                                 .requestBlocked, .http(503), .network, .invalidResponse, .invalidOrganizationId,
                                 .invalidCredentials, .keychain(-25293)]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertLessThan(error.message.count, 80, error.message)
        }
        XCTAssertTrue(UsageError.http(503).message.contains("503"))
        XCTAssertTrue(UsageError.tokenCannotReadUsage.message.localizedCaseInsensitiveContains("session key"))
        XCTAssertTrue(UsageError.sessionKeyRejected.message.localizedCaseInsensitiveContains("session key"))
        XCTAssertFalse(UsageError.blockedByCloudflare.message.localizedCaseInsensitiveContains("expired"))
    }

    // MARK: Policies

    func testFallsBackOnlyWhenTheTokenItselfIsConfirmedUnusable() {
        XCTAssertTrue(FallbackPolicy.shouldTrySessionKey(afterTokenFailure: .tokenRejected))
        XCTAssertTrue(FallbackPolicy.shouldTrySessionKey(afterTokenFailure: .tokenCannotReadUsage))
        let noFallback: [UsageError] = [.accessDenied(403), .blockedByCloudflare, .rateLimited(retryAfter: nil),
                                        .network, .http(500), .redirected]
        for error in noFallback {
            XCTAssertFalse(FallbackPolicy.shouldTrySessionKey(afterTokenFailure: error), "\(error)")
        }
    }

    func testUnclearProblemsKeepTheLastNumbersButConfirmedCredentialProblemsClearThem() {
        let keep: [UsageError] = [.network, .http(503), .rateLimited(retryAfter: 60), .blockedByCloudflare,
                                  .accessDenied(403), .invalidResponse, .redirected]
        let clear: [UsageError] = [.noCredentials, .sessionKeyRejected, .tokenRejected, .tokenCannotReadUsage,
                                   .invalidCredentials, .invalidOrganizationId]
        keep.forEach { XCTAssertTrue(RefreshPolicy.keepsLastReport(after: $0), "\($0)") }
        clear.forEach { XCTAssertFalse(RefreshPolicy.keepsLastReport(after: $0), "\($0)") }
    }

    // MARK: Orchestration

    final class Recorder {
        var requests: [URLRequest] = []
        var responses: [TransportResult]
        init(_ responses: [TransportResult]) { self.responses = responses }
        func fetcher(now: Date) -> UsageFetcher {
            var fetcher = UsageFetcher { request in
                self.requests.append(request)
                return self.responses.isEmpty ? .network : self.responses.removeFirst()
            }
            fetcher.now = { now }
            return fetcher
        }
        var hosts: [String] { requests.compactMap { $0.url?.host } }
    }

    var both: WidgetConfig { WidgetConfig(oauthToken: "tok", sessionKey: "sk", organizationId: upper) }

    func testNoCredentialsMakesNoRequest() async {
        let recorder = Recorder([])
        let result = await recorder.fetcher(now: now).fetch(config: WidgetConfig())
        XCTAssertEqual(result.failure, .noCredentials)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testOAuthSuccessUsesOnlyTheAnthropicAPI() async {
        let recorder = Recorder([.ok(okBody)])
        let report = await recorder.fetcher(now: now).fetch(config: both).success
        XCTAssertEqual(report?.snapshot.fiveHourPercent, 42)
        XCTAssertEqual(report?.route, .oauthToken)
        XCTAssertNil(report?.tokenFailure)
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com"])
    }

    func testTokenThatCannotReadUsageFallsBackToTheSessionKeyAndSaysWhy() async {
        let recorder = Recorder([.http(failure(403, body: scopeBody)), .ok(okBody)])
        let report = await recorder.fetcher(now: now).fetch(config: both).success
        XCTAssertEqual(report?.snapshot.weeklyPercent, 7)
        XCTAssertEqual(report?.route, .sessionKey)
        XCTAssertEqual(report?.tokenFailure, .tokenCannotReadUsage)
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com", "claude.ai"])
    }

    func testUnclearTokenFailureDoesNotSpendTheSessionKey() async {
        let recorder = Recorder([.http(failure(403, body: "{}"))])
        let result = await recorder.fetcher(now: now).fetch(config: both)
        XCTAssertEqual(result.failure, .accessDenied(403))
        XCTAssertEqual(recorder.hosts, ["api.anthropic.com"])
    }

    func testTokenOnlyFailuresAreNamedByCause() async {
        let token = WidgetConfig(oauthToken: "tok")
        let forbidden = await Recorder([.http(failure(403, body: scopeBody))]).fetcher(now: now).fetch(config: token)
        XCTAssertEqual(forbidden.failure, .tokenCannotReadUsage)
        let rejected = await Recorder([.http(failure(401, body: invalidTokenBody))]).fetcher(now: now).fetch(config: token)
        XCTAssertEqual(rejected.failure, .tokenRejected)
    }

    func testNetworkAndRateLimitFailuresDoNotSpendTheSessionKey() async {
        for response in [TransportResult.network, .http(failure(429, retryAfter: "30"))] {
            let recorder = Recorder([response])
            _ = await recorder.fetcher(now: now).fetch(config: both)
            XCTAssertEqual(recorder.hosts, ["api.anthropic.com"])
        }
    }

    func testWhenBothRoutesFailTheSessionKeyErrorIsShown() async {
        let recorder = Recorder([.http(failure(401, body: invalidTokenBody)), .http(failure(403, body: expiredSessionBody))])
        let result = await recorder.fetcher(now: now).fetch(config: both)
        XCTAssertEqual(result.failure, .sessionKeyRejected)
    }

    func testSessionKeyAloneIsUsedDirectly() async {
        let recorder = Recorder([.ok(okBody)])
        let report = await recorder.fetcher(now: now).fetch(config: WidgetConfig(sessionKey: "sk", organizationId: upper)).success
        XCTAssertEqual(report?.route, .sessionKey)
        XCTAssertNil(report?.tokenFailure)
        XCTAssertEqual(recorder.hosts, ["claude.ai"])
    }

    func testSessionKeyFailuresPassThroughTheirClassification() async {
        let config = WidgetConfig(sessionKey: "sk", organizationId: upper)
        let expired = await Recorder([.http(failure(403, body: expiredSessionBody))]).fetcher(now: now).fetch(config: config)
        XCTAssertEqual(expired.failure, .sessionKeyRejected)
        let limited = await Recorder([.http(failure(429, retryAfter: "60"))]).fetcher(now: now).fetch(config: config)
        XCTAssertEqual(limited.failure, .rateLimited(retryAfter: 60))
        let redirected = await Recorder([.redirected]).fetcher(now: now).fetch(config: config)
        XCTAssertEqual(redirected.failure, .redirected)
        let refused = await Recorder([.refused]).fetcher(now: now).fetch(config: config)
        XCTAssertEqual(refused.failure, .requestBlocked)
    }

    func testStoredOrganizationIdThatIsNotAUUIDIsNeverSent() async {
        let recorder = Recorder([.ok(okBody)])
        let result = await recorder.fetcher(now: now).fetch(config: WidgetConfig(sessionKey: "sk", organizationId: "../evil"))
        XCTAssertEqual(result.failure, .invalidOrganizationId)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testStoredCredentialsThatCouldBreakHeadersAreNeverSent() async {
        let recorder = Recorder([.ok(okBody), .ok(okBody)])
        let badToken = await recorder.fetcher(now: now).fetch(config: WidgetConfig(oauthToken: "tok\r\nX-Injected: 1"))
        XCTAssertEqual(badToken.failure, .invalidCredentials)
        let badKey = await recorder.fetcher(now: now).fetch(config: WidgetConfig(sessionKey: "a;b", organizationId: upper))
        XCTAssertEqual(badKey.failure, .invalidCredentials)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUnparseableSuccessBodyIsReportedAsInvalidResponse() async {
        let recorder = Recorder([.ok(Data("{}".utf8))])
        let result = await recorder.fetcher(now: now).fetch(config: WidgetConfig(oauthToken: "tok"))
        XCTAssertEqual(result.failure, .invalidResponse)
    }
}

extension Result {
    var success: Success? { if case .success(let value) = self { return value } else { return nil } }
    var failure: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
