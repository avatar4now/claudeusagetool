import AppKit
import XCTest
@testable import UsageCore

final class ProblemCauseTests: XCTestCase {
    /// One of every simple error, so each case is checked.
    let simpleErrors: [UsageError] = [
        .noCredentials, .invalidOrganizationId, .invalidCredentials, .tokenRejected, .tokenCannotReadUsage,
        .sessionKeyRejected, .blockedByCloudflare, .accessDenied(403), .rateLimited(retryAfter: 60),
        .rateLimited(retryAfter: nil), .redirected, .requestBlocked, .http(500), .network, .invalidResponse,
        .keychain(-25300)
    ]

    /// Every simple error, plus a failed fallback for each token problem paired with each simple session problem.
    var allErrors: [UsageError] {
        let fallbacks = [UsageError.tokenRejected, .tokenCannotReadUsage].flatMap { token in
            simpleErrors.map { UsageError.fallbackFailed(token: token, session: $0) }
        }
        return simpleErrors + fallbacks
    }

    func testEachErrorMapsToItsCause() {
        let expected: [(UsageError, ProblemCause)] = [
            (.tokenRejected, .signIn), (.tokenCannotReadUsage, .signIn), (.sessionKeyRejected, .signIn),
            (.noCredentials, .setup), (.invalidOrganizationId, .setup), (.invalidCredentials, .setup),
            (.rateLimited(retryAfter: 30), .rateLimited), (.network, .offline), (.blockedByCloudflare, .botCheck),
            (.accessDenied(401), .serviceError), (.http(502), .serviceError), (.invalidResponse, .serviceError),
            (.redirected, .serviceError), (.requestBlocked, .serviceError), (.keychain(-25293), .keychain)
        ]
        for (error, cause) in expected {
            XCTAssertEqual(ProblemCause(error), cause, "\(error)")
        }
    }

    func testAFailedFallbackTakesTheCauseOfItsSessionKeyPart() {
        XCTAssertEqual(ProblemCause(.fallbackFailed(token: .tokenRejected, session: .network)), .offline,
                       "the key may still work once the network is back")
        XCTAssertEqual(ProblemCause(.fallbackFailed(token: .tokenCannotReadUsage, session: .rateLimited(retryAfter: nil))),
                       .rateLimited)
        XCTAssertEqual(ProblemCause(.fallbackFailed(token: .tokenRejected, session: .sessionKeyRejected)), .signIn)
        XCTAssertEqual(ProblemCause(.fallbackFailed(token: .tokenRejected, session: .invalidOrganizationId)), .setup)
    }

    func testNeedsActionAgreesWithWhetherTheLastNumbersAreKept() {
        for error in allErrors {
            XCTAssertEqual(ProblemCause(error).needsAction, !RefreshPolicy.keepsLastReport(after: error), "\(error)")
        }
        XCTAssertFalse(ProblemCause.waiting.needsAction)
    }

    func testEveryCauseHasAShortTitle() {
        let titles: [ProblemCause: String] = [
            .signIn: "Sign in again", .setup: "Finish setup", .rateLimited: "Rate limited", .offline: "Offline",
            .botCheck: "Bot check", .serviceError: "Service problem", .keychain: "Keychain problem",
            .waiting: "Waiting for data"
        ]
        for cause in ProblemCause.allCases {
            XCTAssertEqual(cause.title, titles[cause], "\(cause)")
            XCTAssertLessThanOrEqual(cause.title.split(separator: " ").count, 3)
        }
    }

    func testEveryCauseHasADistinctSymbolThatExists() {
        for cause in ProblemCause.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: cause.symbol, accessibilityDescription: nil), "\(cause.symbol)")
        }
        XCTAssertEqual(Set(ProblemCause.allCases.map(\.symbol)).count, ProblemCause.allCases.count)
        XCTAssertNotNil(NSImage(systemSymbolName: ProblemCause.fallbackSymbol, accessibilityDescription: nil))
    }

    func testRawValuesStayStableBecauseTheAppAndWidgetShareThem() {
        XCTAssertEqual(ProblemCause.allCases.map(\.rawValue),
                       ["signIn", "setup", "rateLimited", "offline", "botCheck", "serviceError", "keychain", "waiting"])
    }
}
