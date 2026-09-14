import XCTest
@testable import UsageCore

final class WidgetConfigTests: XCTestCase {
    let upper = "123E4567-E89B-12D3-A456-426614174000"
    var lower: String { upper.lowercased() }

    func testFromFieldsTrimsWhitespaceAndTurnsBlankIntoNil() throws {
        let config = try WidgetConfig.fromFields(oauthToken: "  tok\n", sessionKey: "   ", organizationId: "")
        XCTAssertEqual(config, WidgetConfig(oauthToken: "tok"))
    }

    func testFromFieldsStoresOrganizationIdLowercased() throws {
        let config = try WidgetConfig.fromFields(oauthToken: nil, sessionKey: "sk", organizationId: upper)
        XCTAssertEqual(config.organizationId, lower)
    }

    func testFromFieldsRejectsOrganizationIdThatIsNotAUUID() {
        for bad in ["not-a-uuid", "../../etc/passwd", "abc/usage", String(upper.dropLast())] {
            XCTAssertThrowsError(try WidgetConfig.fromFields(oauthToken: nil, sessionKey: "sk", organizationId: bad)) {
                XCTAssertEqual($0 as? ConfigValidationError, .invalidOrganizationId, bad)
            }
        }
    }

    func testFromFieldsRequiresOrganizationIdWhenSessionKeyIsGiven() {
        XCTAssertThrowsError(try WidgetConfig.fromFields(oauthToken: nil, sessionKey: "sk", organizationId: " ")) {
            XCTAssertEqual($0 as? ConfigValidationError, .missingOrganizationId)
        }
    }

    func testFromFieldsRejectsCredentialsThatCouldBreakHTTPHeaders() {
        for bad in ["tok en", "tok\r\nX-Injected: 1", "tök"] {
            XCTAssertThrowsError(try WidgetConfig.fromFields(oauthToken: bad, sessionKey: nil, organizationId: nil)) {
                XCTAssertEqual($0 as? ConfigValidationError, .invalidToken, bad)
            }
        }
        XCTAssertThrowsError(try WidgetConfig.fromFields(oauthToken: nil, sessionKey: "sk;other=1", organizationId: upper)) {
            XCTAssertEqual($0 as? ConfigValidationError, .invalidSessionKey)
        }
    }

    func testFromFieldsAllowsEverythingBlank() throws {
        XCTAssertTrue(try WidgetConfig.fromFields(oauthToken: "", sessionKey: "", organizationId: "").isEmpty)
    }

    func testValidationMessagesAreShortAndActionable() {
        let all: [ConfigValidationError] = [.invalidToken, .invalidSessionKey, .invalidOrganizationId, .missingOrganizationId]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertLessThan(error.message.count, 90, error.message)
        }
    }

    func testIsEmptyOnlyWhenThereIsNoCredential() {
        XCTAssertTrue(WidgetConfig().isEmpty)
        XCTAssertFalse(WidgetConfig(oauthToken: "t").isEmpty)
        XCTAssertFalse(WidgetConfig(sessionKey: "s", organizationId: lower).isEmpty)
        XCTAssertTrue(WidgetConfig(organizationId: lower).isEmpty, "an organization ID alone is not a credential")
    }

    func testValidatedOrganizationIdGuardsStoredValues() {
        // Defense in depth: never trust what is stored, even though Save validates.
        XCTAssertNil(WidgetConfig(sessionKey: "s", organizationId: "../x").validatedOrganizationId)
        XCTAssertNil(WidgetConfig(sessionKey: "s").validatedOrganizationId)
        XCTAssertEqual(WidgetConfig(sessionKey: "s", organizationId: upper).validatedOrganizationId, lower)
    }

    func testJSONRoundTrip() throws {
        let original = WidgetConfig(oauthToken: "t", sessionKey: "s", organizationId: lower)
        XCTAssertEqual(try WidgetConfig.decode(try original.encoded()), original)
    }

    func testDecodeNormalizesBlankValuesAndIgnoresUnknownKeys() throws {
        let data = Data(#"{"oauthToken":"  ","sessionKey":" sk-ant-sid01-x ","organizationId":"\#(upper)","codexEnabled":true}"#.utf8)
        let config = try WidgetConfig.decode(data)
        XCTAssertNil(config.oauthToken)
        XCTAssertEqual(config.sessionKey, "sk-ant-sid01-x")
        XCTAssertEqual(config.organizationId, upper)
    }
}
