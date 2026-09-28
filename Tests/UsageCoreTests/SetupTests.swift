import XCTest
@testable import UsageCore

final class SetupTests: XCTestCase {
    let key = "sk-ant-sid01-abcDEF123_-xyz"

    // MARK: The organizations request

    func testOrganizationsRequestGoesOnlyToClaudeWithTheCookie() throws {
        let request = try XCTUnwrap(ClaudeEndpoints.organizationsRequest(sessionKey: key))
        XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/organizations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=\(key)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(ClaudeEndpoints.isAllowed(request))
        XCTAssertNil(ClaudeEndpoints.organizationsRequest(sessionKey: "bad\r\nkey"), "a key that could break the header is refused")
    }

    func testOnlyTheExactOrganizationsAddressIsAllowed() throws {
        var request = try XCTUnwrap(ClaudeEndpoints.organizationsRequest(sessionKey: key))
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(ClaudeEndpoints.isAllowed(request), "never a bearer token to claude.ai")
        for address in ["https://claude.ai/api/organizations?x=1", "https://claude.ai/api/organizations/",
                        "https://claude.ai/api/organizations/extra", "http://claude.ai/api/organizations",
                        "https://claude.ai.evil.example/api/organizations"] {
            var other = URLRequest(url: URL(string: address)!)
            other.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
            XCTAssertFalse(ClaudeEndpoints.isAllowed(other), address)
        }
    }

    // MARK: Reading the list

    func testParsesOrganizationsAndPutsChatOnesFirst() throws {
        let json = """
        [
          {"uuid": "11111111-2222-3333-4444-555555555555", "name": "API console", "capabilities": ["api"]},
          {"uuid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "Personal", "capabilities": ["chat", "claude_max"]},
          {"uuid": "not-a-uuid", "name": "Broken"},
          {"uuid": "99999999-8888-7777-6666-555555555555"}
        ]
        """
        let organizations = try OrganizationParser.parse(Data(json.utf8))
        XCTAssertEqual(organizations.map(\.id), ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                                 "11111111-2222-3333-4444-555555555555",
                                                 "99999999-8888-7777-6666-555555555555"])
        XCTAssertEqual(organizations.map(\.name), ["Personal", "API console", "Unnamed organization"])
        XCTAssertEqual(organizations.map(\.canChat), [true, false, nil])
        XCTAssertEqual(OrganizationParser.bestGuess(organizations)?.name, "Personal")
    }

    func testBestGuessOnlyWhenItIsClear() throws {
        let one = [ClaudeOrganization(id: "a", name: "Only", canChat: nil)]
        XCTAssertEqual(OrganizationParser.bestGuess(one)?.name, "Only")
        let twoChat = [ClaudeOrganization(id: "a", name: "Mine", canChat: true),
                       ClaudeOrganization(id: "b", name: "Team", canChat: true)]
        XCTAssertNil(OrganizationParser.bestGuess(twoChat), "with two chat organizations the person picks")
        XCTAssertNil(OrganizationParser.bestGuess([]))
    }

    func testAnythingButAListIsAnUnexpectedResponse() {
        XCTAssertThrowsError(try OrganizationParser.parse(Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertThrowsError(try OrganizationParser.parse(Data("<html>".utf8)))
        XCTAssertEqual(try OrganizationParser.parse(Data("[]".utf8)), [])
    }

    // MARK: Looking them up

    func testLookupReturnsTheListOrAClearProblem() async {
        let list = Data(#"[{"uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","name":"Personal","capabilities":["chat"]}]"#.utf8)
        let ok = UsageFetcher(send: { _ in .ok(list) })
        guard case .success(let found) = await ok.organizations(sessionKey: key) else { return XCTFail("expected success") }
        XCTAssertEqual(found.first?.name, "Personal")

        let expired = HTTPFailure(status: 403, contentType: "application/json", cfMitigated: nil, retryAfter: nil,
                                  bodyPrefix: Data(#"{"error":{"details":{"error_code":"account_session_invalid"}}}"#.utf8))
        let rejected = UsageFetcher(send: { _ in .http(expired) })
        guard case .failure(let error) = await rejected.organizations(sessionKey: key) else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .sessionKeyRejected)

        let offline = UsageFetcher(send: { _ in .network })
        guard case .failure(.network) = await offline.organizations(sessionKey: key) else { return XCTFail("expected offline") }

        let garbled = UsageFetcher(send: { _ in .ok(Data("nope".utf8)) })
        guard case .failure(.invalidResponse) = await garbled.organizations(sessionKey: key) else { return XCTFail("expected bad reply") }

        let unsafe = UsageFetcher(send: { _ in XCTFail("nothing should be sent"); return .network })
        guard case .failure(.invalidCredentials) = await unsafe.organizations(sessionKey: "bad\nkey") else {
            return XCTFail("expected a refused key")
        }
    }

    // MARK: Pasting a key

    func testCleansWhatPeopleTypicallyPaste() {
        XCTAssertEqual(SessionKeyInput.clean("  \(key)\n"), key)
        XCTAssertEqual(SessionKeyInput.clean("sessionKey=\(key)"), key, "the whole cookie pair")
        XCTAssertEqual(SessionKeyInput.clean("sessionKey=\(key); Path=/; Secure"), key)
        XCTAssertEqual(SessionKeyInput.clean("\"\(key)\""), key, "quotes from a JSON view")
    }

    func testRecognizesSessionKeys() {
        XCTAssertTrue(SessionKeyInput.looksLikeSessionKey(key))
        XCTAssertFalse(SessionKeyInput.looksLikeSessionKey("sk-ant-oat01-abc"), "an OAuth token isn't a session key")
        XCTAssertFalse(SessionKeyInput.looksLikeSessionKey("hello"))
        XCTAssertFalse(SessionKeyInput.looksLikeSessionKey(""))
    }
}
