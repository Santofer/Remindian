import XCTest
@testable import Remindian

/// #95 — scan only notes carrying a given tag. The tag lives on the *note*
/// (frontmatter or inline), not on the individual task line.
final class NoteTagFilterTests: XCTestCase {

    // MARK: - Reading a note's tags

    func test_readsInlineFrontmatterTagList() {
        let note = """
        ---
        title: Plan
        tags: [project, work]
        ---
        - [ ] Do the thing
        """
        XCTAssertEqual(ObsidianService.noteTags(in: note), ["project", "work"])
    }

    func test_readsYamlListFrontmatterTags() {
        let note = """
        ---
        tags:
          - project
          - Work
        status: open
        ---
        """
        let tags = ObsidianService.noteTags(in: note)
        XCTAssertTrue(tags.contains("project"))
        XCTAssertTrue(tags.contains("work"), "Tags are compared lowercased")
        XCTAssertFalse(tags.contains("status"), "A following key must end the list block")
    }

    func test_readsInlineBodyTags() {
        XCTAssertTrue(ObsidianService.noteTags(in: "Some notes #project here").contains("project"))
    }

    func test_stripsHashAndQuotes() {
        let note = """
        ---
        tags: ["#project", 'work']
        ---
        """
        XCTAssertEqual(ObsidianService.noteTags(in: note), ["project", "work"])
    }

    func test_noteWithoutTags() {
        XCTAssertTrue(ObsidianService.noteTags(in: "- [ ] plain task").isEmpty)
    }

    // MARK: - Matching

    func test_emptyWhitelistMatchesEverything() {
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter([], whitelist: []))
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter(["anything"], whitelist: []))
    }

    func test_matchesConfiguredTag() {
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter(["project"], whitelist: ["project"]))
        XCTAssertFalse(ObsidianService.noteMatchesTagFilter(["personal"], whitelist: ["project"]))
    }

    func test_whitelistEntryMayCarryAHash() {
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter(["project"], whitelist: ["#project"]))
    }

    func test_parentTagMatchesNestedChildren() {
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter(["project/alpha"], whitelist: ["project"]),
                      "A parent tag should select its children")
        XCTAssertFalse(ObsidianService.noteMatchesTagFilter(["projectile"], whitelist: ["project"]),
                       "Prefix match must respect the / boundary")
    }

    func test_caseInsensitive() {
        XCTAssertTrue(ObsidianService.noteMatchesTagFilter(["work"], whitelist: ["Work"]))
    }

    // MARK: - End to end

    func test_scanSkipsUntaggedNotesButKeepsTaggedOnes() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try "---\ntags: [project]\n---\n- [ ] Tagged task\n"
            .write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "- [ ] Untagged task\n"
            .write(to: vault.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let titles = try ObsidianService()
            .scanVault(at: vault.path, excludedFolders: [], includedNoteTags: ["project"])
            .map(\.title)

        XCTAssertTrue(titles.contains("Tagged task"))
        XCTAssertFalse(titles.contains("Untagged task"))
    }

    /// The inbox must stay in scope or tasks written there by the
    /// destination→vault direction would look deleted and lose their reminders.
    func test_inboxIsScannedEvenWhenUntagged() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try "- [ ] Task from a reminder\n"
            .write(to: vault.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8)

        let titles = try ObsidianService()
            .scanVault(at: vault.path, excludedFolders: [],
                       inboxRelativePath: "Inbox.md", includedNoteTags: ["project"])
            .map(\.title)

        XCTAssertTrue(titles.contains("Task from a reminder"),
                      "The inbox is exempt from the note-tag whitelist")
    }

    func test_filterOffByDefault() {
        XCTAssertTrue(SyncConfiguration().includedNoteTags.isEmpty)
    }
}
