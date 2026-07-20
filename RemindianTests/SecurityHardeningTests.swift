import XCTest
@testable import Remindian

/// Regression tests for findings from the GHSA-3q2g-hmqg-qj5r security review.
final class SecurityHardeningTests: XCTestCase {

    // MARK: - H1: AppleScript injection via broken string escaping

    /// The original escaping handled `"` but not `\`. A value ending in a
    /// backslash therefore closed the AppleScript string literal early and the
    /// rest was compiled as code — `do shell script` runs outside the sandbox.
    func test_H1_backslashIsEscapedBeforeQuote() {
        XCTAssertEqual(Things3Destination.appleScriptEscape("back\\slash"), "back\\\\slash")
        XCTAssertEqual(Things3Destination.appleScriptEscape("say \"hi\""), "say \\\"hi\\\"")
        // The critical case: a trailing backslash must not be able to escape the
        // closing quote of the literal it is embedded in.
        XCTAssertEqual(Things3Destination.appleScriptEscape("trailing\\"), "trailing\\\\")
    }

    func test_H1_injectionPayloadCannotBreakOutOfLiteral() {
        // A payload that used to terminate `name:"..."` and append statements.
        let payload = #"Buy milk\" & (do shell script "touch /tmp/pwned") & \""#
        let escaped = Things3Destination.appleScriptEscape(payload)
        let literal = "name:\"\(escaped)\""

        // Walk the literal and confirm the only unescaped quotes are the
        // delimiters — i.e. the payload cannot close the string early.
        var unescapedQuotes = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            let ch = literal[index]
            if ch == "\\" {
                // Skip the escaped character — it cannot terminate the literal.
                index = literal.index(index, offsetBy: 2, limitedBy: literal.endIndex) ?? literal.endIndex
                continue
            }
            if ch == "\"" { unescapedQuotes += 1 }
            index = literal.index(after: index)
        }
        XCTAssertEqual(unescapedQuotes, 2, "Only the opening and closing delimiters may be unescaped. Literal: \(literal)")
    }

    func test_H1_tagsAreEscapedToo() {
        // Tags come from the user's markdown, so they are attacker-influenced.
        let dest = Things3Destination()
        let prop = dest.buildTagNamesProperty(tags: ["#ok", "#ev\\il"])
        XCTAssertFalse(prop.contains("ev\\il"), "A raw backslash must not survive into the script. Got: \(prop)")
        XCTAssertTrue(prop.contains("ev\\\\il"), "Backslash must be doubled. Got: \(prop)")
    }

    // MARK: - M2: OAuth authorization code must never reach the debug log

    func test_M2_callbackURLIsRedactedForLogging() throws {
        let url = try XCTUnwrap(URL(string: "remindian://oauth/ticktick?code=SECRET123&state=abc&foo=bar"))
        let logged = OAuthCallbackHandler.redactedForLogging(url)

        XCTAssertFalse(logged.contains("SECRET123"), "The auth code must never be logged. Got: \(logged)")
        XCTAssertFalse(logged.contains("state=abc"), "state must be redacted too. Got: \(logged)")
        XCTAssertTrue(logged.contains("REDACTED"), "Redaction must stay readable (not percent-encoded). Got: \(logged)")
        XCTAssertTrue(logged.contains("foo=bar"), "Non-secret params stay for debuggability. Got: \(logged)")
    }

    func test_M2_redactsTokenBearingParams() throws {
        let url = try XCTUnwrap(URL(string: "remindian://oauth/x?access_token=AAA&refresh_token=BBB"))
        let logged = OAuthCallbackHandler.redactedForLogging(url)
        XCTAssertFalse(logged.contains("AAA"))
        XCTAssertFalse(logged.contains("BBB"))
    }

    func test_M2_handlesURLWithNoQueryItems() throws {
        let url = try XCTUnwrap(URL(string: "remindian://oauth/ticktick"))
        XCTAssertFalse(OAuthCallbackHandler.redactedForLogging(url).isEmpty)
    }
}
