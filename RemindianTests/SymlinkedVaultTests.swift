import XCTest
@testable import Remindian

/// A vault reached through a symlink must behave exactly like one reached directly.
///
/// `FileManager`'s enumerator returns *resolved* file paths, while the configured
/// vault path keeps whatever spelling the user picked. Vault-relative paths were
/// computed by cutting the configured path off the front of the file path, so with
/// a symlink anywhere in the vault path the result was garbage: folder filters
/// matched nothing, the inbox lost its exemption (so its tasks looked deleted and
/// their reminders were removed), and writeback rebuilt paths that don't exist.
/// A vault that *was* a symlink was worse still — it enumerated as empty.
final class SymlinkedVaultTests: XCTestCase {

    private var root: URL!
    private var realVault: URL { root.appendingPathComponent("real/vault") }

    /// The same vault, spelled three ways.
    private var spellings: [(name: String, path: String)] {
        [
            ("direct", realVault.path),
            ("vault is a symlink", root.appendingPathComponent("vault-link").path),
            ("parent is a symlink", root.appendingPathComponent("parent-link/vault").path),
            // The resolved files then *start with* the configured path ("…/real/vau")
            // without being inside it — a plain prefix cut would return "lt/Work/a.md".
            ("link name is a prefix of its target", root.appendingPathComponent("real/vau").path),
        ]
    }

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("symlinked-vault-\(UUID().uuidString)")
        for folder in ["Work/Sub", "Other", "tasks"] {
            try fm.createDirectory(at: realVault.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "- [ ] InboxTask\n".write(to: realVault.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8)
        try "- [ ] WorkTask\n".write(to: realVault.appendingPathComponent("Work/a.md"), atomically: true, encoding: .utf8)
        try "- [ ] SubTask\n".write(to: realVault.appendingPathComponent("Work/Sub/c.md"), atomically: true, encoding: .utf8)
        try "- [ ] OtherTask\n".write(to: realVault.appendingPathComponent("Other/b.md"), atomically: true, encoding: .utf8)
        try "---\nstatus: todo\n---\n# NoteTask\n".write(to: realVault.appendingPathComponent("tasks/n.md"), atomically: true, encoding: .utf8)

        try fm.createSymbolicLink(at: root.appendingPathComponent("vault-link"), withDestinationURL: realVault)
        try fm.createSymbolicLink(at: root.appendingPathComponent("real/vau"), withDestinationURL: realVault)
        try fm.createSymbolicLink(at: root.appendingPathComponent("parent-link"),
                                  withDestinationURL: root.appendingPathComponent("real"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func config(_ vaultPath: String) -> SyncConfiguration {
        let config = SyncConfiguration()
        config.vaultPath = vaultPath
        config.inboxFilePath = "Inbox.md"
        return config
    }

    private func paths(_ tasks: [SyncTask]) -> [String: String] {
        Dictionary(tasks.map { ($0.title, $0.obsidianSource?.filePath ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - The helper

    func test_sameSpellingIsCutWithoutTouchingTheFilesystem() {
        let file = URL(fileURLWithPath: "/no/such/vault/Work/a.md")
        XCTAssertEqual(ObsidianService.vaultRelativePath(of: file, vaultPath: "/no/such/vault"), "/Work/a.md")
    }

    func test_everySpellingOfTheVaultGivesTheSameRelativePath() {
        // What the enumerator hands back: the fully resolved file.
        let enumerated = URL(fileURLWithPath: realVault.appendingPathComponent("Work/a.md").path).resolvingSymlinksInPath()
        for spelling in spellings {
            XCTAssertEqual(ObsidianService.vaultRelativePath(of: enumerated, vaultPath: spelling.path), "/Work/a.md", spelling.name)
        }
    }

    func test_aNoteThatIsItselfASymlinkKeepsItsPlaceInTheVault() throws {
        let outside = root.appendingPathComponent("outside.md")
        try "- [ ] Linked\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = realVault.appendingPathComponent("Work/linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for spelling in spellings {
            XCTAssertEqual(ObsidianService.vaultRelativePath(of: link, vaultPath: spelling.path), "/Work/linked.md", spelling.name)
        }
    }

    // MARK: - Obsidian Tasks source

    func test_obsidian_scanFindsEverythingWithCleanRelativePaths() throws {
        for spelling in spellings {
            let tasks = try ObsidianService().scanVault(at: spelling.path, excludedFolders: ["tasks"])
            XCTAssertEqual(paths(tasks), [
                "InboxTask": "/Inbox.md", "WorkTask": "/Work/a.md", "SubTask": "/Work/Sub/c.md", "OtherTask": "/Other/b.md",
            ], spelling.name)
        }
    }

    func test_obsidian_folderFiltersStillApply() throws {
        for spelling in spellings {
            let whitelisted = try ObsidianService().scanVault(
                at: spelling.path, excludedFolders: [], includedFolders: ["Work"], inboxRelativePath: "Inbox.md")
            XCTAssertEqual(Set(whitelisted.map(\.title)), ["WorkTask", "SubTask", "InboxTask"],
                           "\(spelling.name): whitelist scopes the scan, and the inbox always stays in")

            // A nested exclusion can only match by relative path, not by folder name.
            let excluded = try ObsidianService().scanVault(at: spelling.path, excludedFolders: ["tasks", "Work/Sub"])
            XCTAssertEqual(Set(excluded.map(\.title)), ["WorkTask", "OtherTask", "InboxTask"], spelling.name)
        }
    }

    /// The inbox is exempt from the note-tag whitelist. If the exemption is lost,
    /// its tasks vanish from the scan and the engine deletes their reminders.
    func test_obsidian_inboxKeepsItsExemptionFromTheNoteTagFilter() throws {
        for spelling in spellings {
            let tasks = try ObsidianService().scanVault(
                at: spelling.path, excludedFolders: [], inboxRelativePath: "Inbox.md", includedNoteTags: ["nobody-has-this"])
            XCTAssertEqual(tasks.map(\.title), ["InboxTask"], spelling.name)
        }
    }

    func test_obsidian_completionWritebackReachesTheRealFile() throws {
        for spelling in spellings {
            try "- [ ] WorkTask\n".write(to: realVault.appendingPathComponent("Work/a.md"), atomically: true, encoding: .utf8)
            let config = config(spelling.path)
            let source = ObsidianTasksSource()
            let task = try XCTUnwrap(try source.scanTasks(config: config).first { $0.title == "WorkTask" }, spelling.name)

            try source.markTaskComplete(task: task, completionDate: Date(), config: config)

            let after = try String(contentsOf: realVault.appendingPathComponent("Work/a.md"), encoding: .utf8)
            XCTAssertTrue(after.hasPrefix("- [x] WorkTask"), "\(spelling.name). File:\n\(after)")
        }
    }

    // MARK: - Generic Markdown source

    func test_generic_scanFiltersAndInboxBehaveTheSame() throws {
        for spelling in spellings {
            let config = config(spelling.path)
            config.excludedFolders = ["tasks"]
            XCTAssertEqual(paths(try GenericMarkdownSource().scanTasks(config: config)), [
                "InboxTask": "/Inbox.md", "WorkTask": "/Work/a.md", "SubTask": "/Work/Sub/c.md", "OtherTask": "/Other/b.md",
            ], spelling.name)

            config.includedFolders = ["Work"]
            XCTAssertEqual(Set(try GenericMarkdownSource().scanTasks(config: config).map(\.title)),
                           ["WorkTask", "SubTask", "InboxTask"], spelling.name)

            config.includedFolders = []
            config.excludedFolders = ["tasks", "Work/Sub"]
            XCTAssertEqual(Set(try GenericMarkdownSource().scanTasks(config: config).map(\.title)),
                           ["WorkTask", "OtherTask", "InboxTask"], spelling.name)
        }
    }

    func test_generic_completionWritebackReachesTheRealFile() throws {
        for spelling in spellings {
            try "- [ ] WorkTask\n".write(to: realVault.appendingPathComponent("Work/a.md"), atomically: true, encoding: .utf8)
            let config = config(spelling.path)
            let source = GenericMarkdownSource()
            let task = try XCTUnwrap(try source.scanTasks(config: config).first { $0.title == "WorkTask" }, spelling.name)

            _ = try source.markTaskComplete(task: task, completionDate: Date(), config: config)

            let after = try String(contentsOf: realVault.appendingPathComponent("Work/a.md"), encoding: .utf8)
            XCTAssertTrue(after.hasPrefix("- [x] WorkTask"), "\(spelling.name). File:\n\(after)")
        }
    }

    // MARK: - TaskNotes (file mode)

    func test_taskNotes_scanGivesCleanRelativePaths() throws {
        for spelling in spellings {
            let source = TaskNotesSource()
            source.integrationMode = .fileBased
            let config = config(spelling.path)
            config.taskNotesFolder = "tasks"
            let tasks = try source.scanTasks(config: config)
            XCTAssertEqual(tasks.map { $0.obsidianSource?.filePath }, ["/tasks/n.md"], spelling.name)
        }
    }
}
