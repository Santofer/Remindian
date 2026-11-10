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

/// #96 — route every task of a tagged note to a list ("Notes with these tags").
final class NoteTagRoutingTests: XCTestCase {

    private func config() -> SyncConfiguration {
        let config = SyncConfiguration()
        config.defaultList = "Inbox"
        config.noteTagMappings = [.init(obsidianTag: "client13", remindersList: "Client 13")]
        return config
    }

    func test_96_tasksOfATaggedNoteGoToTheMappedListFromAnyFolder() {
        let c = config()
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/A/b.md", noteTags: ["client13"]), "Client 13")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/Z/deep/c.md", noteTags: ["other", "client13"]), "Client 13")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/A/b.md", noteTags: ["other"]), "Inbox")
        XCTAssertEqual(c.explainTargetList(tag: nil, filePath: "/A/b.md", noteTags: ["client13"]).reason, "note tagged “#client13”")
    }

    func test_96_matchingIgnoresHashCaseAndCoversNestedTags() {
        let c = config()
        c.noteTagMappings = [.init(obsidianTag: "#Client13", remindersList: "Client 13")]
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: nil, noteTags: ["client13/invoices"]), "Client 13")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: nil, noteTags: ["client130"]), "Inbox",
                       "A longer tag that merely starts the same is a different tag")
    }

    func test_96_precedence_taskTagAndFileBeatNoteTag_noteTagBeatsFolder() {
        let c = config()
        c.listMappings = [.init(obsidianTag: "urgent", remindersList: "Urgent")]
        c.filePathMappings = [.init(filePath: "A/special.md", remindersList: "Special")]
        c.folderPathMappings = [.init(folderPath: "A", remindersList: "Folder A")]

        XCTAssertEqual(c.resolveTargetList(tag: "urgent", filePath: "/A/b.md", tags: ["#urgent"], noteTags: ["client13"]), "Urgent")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/A/special.md", noteTags: ["client13"]), "Special")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/A/b.md", noteTags: ["client13"]), "Client 13")
        XCTAssertEqual(c.resolveTargetList(tag: nil, filePath: "/A/b.md"), "Folder A")
    }

    func test_96_mappingsSurviveEncodeDecode_andOldConfigsDecode() throws {
        let c = config()
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.noteTagMappings.map(\.remindersList), ["Client 13"])

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        json.removeValue(forKey: "noteTagMappings")
        json.removeValue(forKey: "unmappedTagsCreateLists")
        let old = try JSONDecoder().decode(SyncConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.noteTagMappings.isEmpty)
        XCTAssertTrue(old.unmappedTagsCreateLists, "Existing users keep the routing they have")
    }

    /// The scan has to hand the note's tags to the router — and a tag on one task
    /// line must not become a tag of the whole note.
    func test_96_scanAttachesNoteTagsButNotTaskLineTags() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notetag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plan.md")
        try """
        ---
        tags: [client13]
        ---
        Kickoff notes #meeting
        - [ ] Send the quote
        - [ ] Call back #urgent
        """.write(to: file, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(file, vaultPath: dir.path)
        XCTAssertEqual(tasks.count, 2)
        for task in tasks {
            XCTAssertEqual(task.obsidianSource?.noteTags, ["client13", "meeting"])
            // Both follow the note: an *unmapped* task tag is the last resort in
            // the cascade, so it doesn't pull a task out of its note's list.
            XCTAssertEqual(config().resolveTargetList(for: task), "Client 13")
        }
    }
}

/// #103 — an unmapped tag must be able to stay "just a tag".
final class UnmappedTagRoutingTests: XCTestCase {

    func test_103_defaultKeepsTheHistoricBehaviour() {
        let c = SyncConfiguration()
        c.defaultList = "Inbox"
        XCTAssertEqual(c.resolveTargetList(tag: "errands", filePath: nil, tags: ["#errands"]), "Errands")
    }

    func test_103_optOutSendsUnmappedTagsToTheDefaultList() {
        let c = SyncConfiguration()
        c.defaultList = "Inbox"
        c.unmappedTagsCreateLists = false
        c.listMappings = [.init(obsidianTag: "work", remindersList: "Work Tasks")]
        c.folderPathMappings = [.init(folderPath: "Home", remindersList: "Home")]

        XCTAssertEqual(c.resolveTargetList(tag: "errands", filePath: nil, tags: ["#errands"]), "Inbox")
        XCTAssertEqual(c.resolveTargetList(tag: "work", filePath: nil, tags: ["#work"]), "Work Tasks", "Mapped tags still route")
        XCTAssertEqual(c.resolveTargetList(tag: "errands", filePath: "/Home/a.md", tags: ["#errands"]), "Home", "Other rules still apply first")
        XCTAssertTrue(c.explainTargetList(tag: "errands", filePath: nil, tags: ["#errands"]).reason.contains("no mapping"))
    }
}

/// #101 — TaskNotes 4.13+ requires a bearer token on its HTTP API.
final class TaskNotesApiTokenTests: XCTestCase {

    private let url = URL(string: "http://localhost:8080/api/tasks?limit=1&offset=0")!

    func test_101_tokenIsSentAsBearerHeader() {
        let request = TaskNotesSource.apiRequest(url: url, token: "  abc123\n")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
    }

    func test_101_noTokenMeansNoHeader() {
        // Older TaskNotes versions have no auth; an empty "Bearer " would be wrong.
        XCTAssertNil(TaskNotesSource.apiRequest(url: url, token: "  ").value(forHTTPHeaderField: "Authorization"))
    }

    func test_101_a401SaysWhatToDoInsteadOfDumpingJSON() {
        let missing = TaskNotesSource.apiFailureMessage(status: 401, hasToken: false, body: #"{"success":false}"#)
        XCTAssertTrue(missing.contains("requires an API token"))
        XCTAssertTrue(missing.contains("Settings → TaskNotes"))
        XCTAssertFalse(missing.contains("success"))

        let wrong = TaskNotesSource.apiFailureMessage(status: 401, hasToken: true, body: "")
        XCTAssertTrue(wrong.contains("rejected"))

        XCTAssertEqual(TaskNotesSource.apiFailureMessage(status: 500, hasToken: true, body: "boom"), "HTTP 500: boom")
    }

    func test_101_tokenSurvivesEncodeDecode_andIsEmptyForOldConfigs() throws {
        let c = SyncConfiguration()
        c.taskNotesApiToken = "tok"
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(SyncConfiguration.self, from: data).taskNotesApiToken, "tok")

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "taskNotesApiToken")
        XCTAssertEqual(try JSONDecoder().decode(SyncConfiguration.self, from: JSONSerialization.data(withJSONObject: json)).taskNotesApiToken, "")
    }
}
