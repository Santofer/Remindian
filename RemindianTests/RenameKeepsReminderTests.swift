import XCTest
@testable import Remindian

/// #113: renaming a task in the vault deleted its reminder and created a new
/// one, so notes, subtasks, attachments and sharing added in Reminders stayed
/// on the deleted copy.
///
/// A task's ID includes its title. On a rename the old ID vanishes and a new
/// one appears; re-linking only matched an unchanged title, so the old mapping
/// looked deleted and the renamed task looked new. A rename is now recognised
/// when the new task is identical to the last synced one apart from the title:
/// same file, tags, dates, done state and repeat, and the same line for
/// repeating tasks.
final class RenameKeepsReminderTests: XCTestCase {

    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, file: String = "/Work.md", line: Int = 3, due: Date? = nil,
                      tags: [String] = ["#work"], recurrence: String? = nil) -> SyncTask {
        SyncTask(title: title, dueDate: due, tags: tags, targetList: "Work",
                 obsidianSource: .init(filePath: file, lineNumber: line, originalLine: "- [ ] \(title)"),
                 recurrenceRule: recurrence)
    }

    private func config() -> (SyncConfiguration, URL) {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let cfg = SyncConfiguration()
        cfg.vaultPath = vault.path
        cfg.addTaskLinkToReminders = false
        return (cfg, vault)
    }

    /// Syncs `before` once so it is mapped, then renames it to `after` and syncs twice.
    private func runRename(before: [SyncTask], after: [SyncTask]) async -> (RenameMockSource, RenameMockDestination, SyncState) {
        let source = RenameMockSource(tasks: before)
        let destination = RenameMockDestination()
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }
        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        _ = await engine.performSync(config: cfg)
        destination.resetLog()
        source.tasks = after
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)
        return (source, destination, state)
    }

    // MARK: - The reported case

    func test_113_renameKeepsTheSameReminderAndPushesTheNewTitle() async {
        let (_, destination, state) = await runRename(
            before: [task("**Map test no tag**")],
            after: [task("**Map test no tag renamed twice**")]
        )

        XCTAssertEqual(destination.deleted, [], "The reminder must not be deleted.")
        XCTAssertEqual(destination.created, [], "No second reminder.")
        XCTAssertEqual(destination.tasks.count, 1)
        XCTAssertEqual(destination.tasks.first?.title, "**Map test no tag renamed twice**", "The same reminder gets the new title.")
        XCTAssertEqual(destination.tasks.first?.remindersId, "r-1")
        XCTAssertNotNil(state.findMapping(remindersId: "r-1"))
    }

    func test_renameOfDatedTaggedTaskKeepsReminder() async {
        let (_, destination, _) = await runRename(
            before: [task("Call the bank", due: due, tags: ["#errands"])],
            after: [task("Call the bank about the card", due: due, tags: ["#errands"])]
        )
        XCTAssertEqual(destination.deleted, [])
        XCTAssertEqual(destination.created, [])
        XCTAssertEqual(destination.tasks.first?.title, "Call the bank about the card")
    }

    /// Repeating tasks carry their line in the ID; a rename keeps the line.
    func test_renameOfRepeatingTaskKeepsReminder() async {
        let (_, destination, _) = await runRename(
            before: [task("Clear out Reader", line: 12, due: due, recurrence: "every week")],
            after: [task("Clear out Reader and Instapaper", line: 12, due: due, recurrence: "every week")]
        )
        XCTAssertEqual(destination.deleted, [])
        XCTAssertEqual(destination.created, [])
        XCTAssertEqual(destination.tasks.first?.title, "Clear out Reader and Instapaper")
    }

    /// Other tasks in the vault are untouched by the rename.
    func test_renameAmongOtherTasksOnlyAffectsThatTask() async {
        let (_, destination, _) = await runRename(
            before: [task("Alpha", line: 1, due: due), task("Beta", line: 2), task("Gamma", file: "/Other.md", line: 1)],
            after: [task("Alpha renamed", line: 1, due: due), task("Beta", line: 2), task("Gamma", file: "/Other.md", line: 1)]
        )
        XCTAssertEqual(destination.deleted, [])
        XCTAssertEqual(destination.created, [])
        XCTAssertEqual(Set(destination.tasks.map(\.title)), ["Alpha renamed", "Beta", "Gamma"])
    }

    // MARK: - Not a rename: old behaviour (delete and create)

    func test_taskMovedToAnotherFileWithNewTitleIsNotARename() async {
        let (_, destination, _) = await runRename(
            before: [task("Alpha", file: "/A.md")],
            after: [task("Alpha renamed", file: "/B.md")]
        )
        XCTAssertEqual(destination.deleted, ["r-1"])
        XCTAssertEqual(destination.created.count, 1)
    }

    func test_renameWithADifferentDueDateIsNotMatched() async {
        let (_, destination, _) = await runRename(
            before: [task("Alpha", due: due)],
            after: [task("Alpha renamed", due: due.addingTimeInterval(86_400))]
        )
        XCTAssertEqual(destination.deleted, ["r-1"])
        XCTAssertEqual(destination.created.count, 1)
    }

    func test_renameWithDifferentTagsIsNotMatched() async {
        let (_, destination, _) = await runRename(
            before: [task("Alpha", tags: ["#work"])],
            after: [task("Alpha renamed", tags: ["#home"])]
        )
        XCTAssertEqual(destination.deleted, ["r-1"])
    }

    /// Two identical tasks renamed in one sync: which is which can't be told,
    /// so neither is guessed.
    func test_ambiguousRenamesAreNotGuessed() async {
        let (_, destination, _) = await runRename(
            before: [task("One", line: 1), task("Two", line: 2)],
            after: [task("One renamed", line: 1), task("Two renamed", line: 2)]
        )
        XCTAssertEqual(destination.deleted.count, 2)
        XCTAssertEqual(destination.created.count, 2)
    }

    // MARK: - The matcher itself

    func test_matcherHandlesTitlesContainingTheSeparator() {
        let old = task("Pick | choose", due: due)
        let new = task("Pick | choose wisely", due: due)
        let id = { (t: SyncTask) in SyncState.generateObsidianId(task: t) }
        let match = SyncEngine.renamedTaskId(
            lastObsidianId: id(old), lastObsidianHash: SyncState.generateTaskHash(old),
            candidates: [id(new): new], generateId: id)
        XCTAssertEqual(match, id(new))
    }

    func test_matcherIgnoresAnEmptyLastHash() {
        let new = task("Alpha renamed")
        let id = { (t: SyncTask) in SyncState.generateObsidianId(task: t) }
        XCTAssertNil(SyncEngine.renamedTaskId(
            lastObsidianId: id(task("Alpha")), lastObsidianHash: "",
            candidates: [id(new): new], generateId: id))
    }
}

private final class RenameMockSource: TaskSource {
    let sourceName = "RenameMockSource"
    var tasks: [SyncTask]
    init(tasks: [SyncTask]) { self.tasks = tasks }
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { tasks }
    func generateTaskId(for task: SyncTask) -> String { SyncState.generateObsidianId(task: task) }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        XCTFail("appendNewTask must not be called"); return .init(filePath: "/Inbox.md", lineNumber: 1, originalLine: "")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

/// Keeps the reminders it creates and applies updates, so later syncs see them.
private final class RenameMockDestination: TaskDestination {
    let destinationName = "RenameMockDestination"
    private(set) var tasks: [SyncTask] = []
    private(set) var created: [String] = []
    private(set) var deleted: [String] = []
    private var nextId = 1
    func resetLog() { created = []; deleted = [] }
    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Work"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        var made = task
        made.obsidianSource = nil
        made.remindersId = "r-\(nextId)"
        made.targetList = listName
        nextId += 1
        tasks.append(made)
        created.append(made.remindersId!)
        return made.remindersId!
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        guard let i = tasks.firstIndex(where: { $0.remindersId == id }) else { return }
        var updated = task
        updated.obsidianSource = nil
        updated.remindersId = id
        updated.targetList = tasks[i].targetList
        tasks[i] = updated
    }
    func moveTask(withId id: String, toList listName: String) async throws {}
    func deleteTask(withId id: String) async throws {
        tasks.removeAll { $0.remindersId == id }
        deleted.append(id)
    }
    func refresh() {}
}
