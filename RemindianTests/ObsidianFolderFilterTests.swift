import XCTest
@testable import Remindian

/// #81 regression: the includedFolders whitelist must actually restrict the scan.
/// Previously every root-level .md was always scanned on top of the whitelisted
/// folders, so a folderless vault (all notes at the root, e.g. with Virtfolder)
/// could never be scoped to a single subfolder — "every sync synced everything".
final class ObsidianFolderFilterTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        // A folderless-style note at the vault root — must NOT be scanned unless root is opted in.
        try "- [ ] RootTask\n".write(to: vault.appendingPathComponent("RootNote.md"), atomically: true, encoding: .utf8)
        // The inbox at the root — must ALWAYS be included (closed-loop safety).
        try "- [ ] InboxTask\n".write(to: vault.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8)
        // A whitelisted subfolder.
        let folder = vault.appendingPathComponent("Reminders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "- [ ] FolderTask\n".write(to: folder.appendingPathComponent("r.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func titles(includedFolders: [String], inbox: String = "Inbox.md") throws -> [String] {
        let tasks = try ObsidianService().scanVault(
            at: vault.path, excludedFolders: [], includedFolders: includedFolders, inboxRelativePath: inbox)
        return tasks.map { $0.title }
    }

    func test_81_whitelistScopesToFolderAndExcludesOtherRootNotes() throws {
        let t = Set(try titles(includedFolders: ["Reminders"]))
        XCTAssertTrue(t.contains("FolderTask"), "Whitelisted folder must be scanned")
        XCTAssertTrue(t.contains("InboxTask"), "Inbox must always be included")
        XCTAssertFalse(t.contains("RootTask"), "Other root notes must NOT be scanned in whitelist mode (#81)")
    }

    func test_81_trailingSlashAndCaseInWhitelistStillScopes() throws {
        // The user reported trying "Reminders/" — a trailing slash must still scope correctly.
        let t = Set(try titles(includedFolders: ["Reminders/"]))
        XCTAssertTrue(t.contains("FolderTask"))
        XCTAssertFalse(t.contains("RootTask"))
    }

    func test_81_rootSentinelOptsRootNotesBackIn() throws {
        let t = Set(try titles(includedFolders: ["Reminders", "/"]))
        XCTAssertTrue(t.contains("RootTask"), "\"/\" sentinel must opt root notes back in")
        XCTAssertTrue(t.contains("FolderTask"))
        XCTAssertTrue(t.contains("InboxTask"))
    }

    func test_81_inboxIncludedEvenWhenAtRootAndNotWhitelisted() throws {
        let t = Set(try titles(includedFolders: ["Reminders"], inbox: "Inbox.md"))
        XCTAssertTrue(t.contains("InboxTask"),
                      "Inbox round-trip must be protected so tasks written there aren't seen as deleted")
    }

    func test_81_emptyWhitelistScansWholeVault() throws {
        let t = Set(try titles(includedFolders: []))
        XCTAssertEqual(t, ["RootTask", "InboxTask", "FolderTask"], "No whitelist = scan everything")
    }

    func test_81_inboxNotDoubleCountedWhenRootAlsoIncluded() throws {
        // Inbox.md is reachable both via the root scan ("/") and the inbox-include —
        // it must be de-duplicated so it isn't parsed twice.
        let t = try titles(includedFolders: ["/"], inbox: "Inbox.md")
        XCTAssertEqual(t.filter { $0 == "InboxTask" }.count, 1, "Inbox must be de-duplicated")
    }
}
