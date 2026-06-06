import XCTest
@testable import Remindian

/// Unit tests for Things3Destination's AppleScript property construction.
///
/// We don't drive NSAppleScript here (Things 3 isn't available in CI); we verify the
/// AppleScript text that would be passed to it. The critical invariant is #59:
/// `tag names` must be a comma-separated STRING, not an AppleScript list.
final class Things3DestinationTests: XCTestCase {

    // MARK: - #59 tag names must be text, not a list

    /// Regression test: with 2+ tags we must emit `tag names:"a, b"`, never
    /// `tag names:{"a", "b"}`. Things 3's scripting dictionary declares `tag names`
    /// as TEXT, so list syntax fails AppleScript coercion with error -1700.
    func testBuildTagNamesPropertyMultipleTags_usesCommaSeparatedString() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["#work", "#urgent"])

        XCTAssertEqual(result, "tag names:\"work, urgent\"")
        XCTAssertFalse(result.contains("{"), "Must not use AppleScript list syntax `{…}` — breaks Things 3 with -1700 when 2+ tags (#59)")
        XCTAssertFalse(result.contains("}"), "Must not use AppleScript list syntax `{…}` — breaks Things 3 with -1700 when 2+ tags (#59)")
    }

    /// Single tag case still works — this path previously coerced by accident in list form,
    /// string form is correct either way.
    func testBuildTagNamesPropertySingleTag_usesString() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["#work"])

        XCTAssertEqual(result, "tag names:\"work\"")
        XCTAssertFalse(result.contains("{"))
    }

    func testBuildTagNamesPropertyEmptyTags_returnsEmptyString() {
        let dest = Things3Destination()
        XCTAssertEqual(dest.buildTagNamesProperty(tags: []), "")
    }

    /// Hash prefixes should be stripped per cleanTagsForThings.
    func testBuildTagNamesPropertyStripsHashPrefix() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["#work", "personal"])
        XCTAssertEqual(result, "tag names:\"work, personal\"")
    }

    /// Hierarchical tags (`person/name`) should be reduced to leaf (`name`) — Things 3
    /// URL scheme and scripting dictionary require exact tag match by leaf name.
    func testBuildTagNamesPropertyExtractsLeafFromHierarchical() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["#person/alice", "#project/x"])
        XCTAssertEqual(result, "tag names:\"alice, x\"")
    }

    /// Duplicates after leaf extraction should be deduped.
    func testBuildTagNamesPropertyDedupsDuplicates() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["#work", "#work", "#urgent"])
        XCTAssertEqual(result, "tag names:\"work, urgent\"")
    }

    /// Quote characters in tag names must be escaped so they don't close the AppleScript
    /// string literal prematurely. (Uncommon but defensive.)
    func testBuildTagNamesPropertyEscapesQuotes() {
        let dest = Things3Destination()
        let result = dest.buildTagNamesProperty(tags: ["she\"said"])
        XCTAssertEqual(result, "tag names:\"she\\\"said\"")
    }

    // MARK: - AppleScript error classification (#56)

    func test_56_minus1743ClassifiesAsNotAuthorized() {
        // -1743 = errAEEventNotPermitted (user denied Automation permission).
        let err = Things3Error.classifyAppleScriptError(
            errorNumber: -1743,
            message: "Not authorized to send Apple events to Things3."
        )
        XCTAssertEqual(err, .notAuthorized, "-1743 must map to .notAuthorized so the actionable message shows and retries are skipped.")
    }

    func test_56_minus1744ClassifiesAsNotAuthorized() {
        // -1744 = errAEEventWouldRequireUserConsent (consent not yet given).
        let err = Things3Error.classifyAppleScriptError(errorNumber: -1744, message: "consent required")
        XCTAssertEqual(err, .notAuthorized)
    }

    func test_56_genericErrorStaysAppleScriptError() {
        // A non-permission error keeps its original message.
        let err = Things3Error.classifyAppleScriptError(errorNumber: -1728, message: "Can't get to do id \"X\".")
        XCTAssertEqual(err, .appleScriptError("Can't get to do id \"X\"."))
    }

    func test_56_unknownNumberStaysAppleScriptError() {
        let err = Things3Error.classifyAppleScriptError(errorNumber: 0, message: "Unknown")
        XCTAssertEqual(err, .appleScriptError("Unknown"))
    }

    func test_56_notAuthorizedMessageIsActionable() {
        // The message must name the exact System Settings location and the
        // tccutil fallback — that's the whole point of the typed error.
        let msg = Things3Error.notAuthorized.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Privacy & Security"), "Must point at the right Settings pane.")
        XCTAssertTrue(msg.contains("Automation"), "Must name the Automation section.")
        XCTAssertTrue(msg.lowercased().contains("tccutil"), "Must include the reset fallback for when the toggle is missing.")
    }
}
