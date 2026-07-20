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

    // MARK: - H2 (partial): credential files must not be world-readable
    //
    // Full H2 (Keychain) needs a stable code-signing identity the app doesn't have
    // yet — see the notes in SecureFile. Until then the files at least stop being
    // readable by every other account on the machine.

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func test_H2_secureWriteIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")

        try SecureFile.write(Data(#"{"token":"x"}"#.utf8), to: file)
        XCTAssertEqual(try mode(of: file), 0o600, "A credential file must be rw------- , not the 0644 umask default")
    }

    func test_H2_permissionsSurviveRepeatedAtomicWrites() throws {
        // An atomic write replaces the inode, so the mode is re-derived from the
        // umask every time — the hardening has to be re-applied on each write.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("profiles.json")

        for i in 0..<3 {
            try SecureFile.write(Data("{\"n\":\(i)}".utf8), to: file)
            XCTAssertEqual(try mode(of: file), 0o600, "Write \(i) must stay owner-only")
        }
    }

    func test_H2_existingWorldReadableFileIsHardened() throws {
        // Simulates an upgrading user whose config.json is already at 0644.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Data(#"{"token":"legacy"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
        XCTAssertEqual(try mode(of: file), 0o644, "precondition")

        SecureFile.hardenExistingFiles(in: dir, names: ["config.json"])
        XCTAssertEqual(try mode(of: file), 0o600, "Pre-existing files must be fixed, not left exposed")
        XCTAssertEqual(try mode(of: dir), 0o700, "The containing directory is tightened too")
    }

    func test_H2_hardeningMissingFileIsHarmless() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Directory doesn't exist at all — must not throw or crash.
        SecureFile.hardenExistingFiles(in: dir, names: ["config.json"])
        XCTAssertFalse(SecureFile.restrictToOwner(at: dir.appendingPathComponent("nope.json")))
    }
}
