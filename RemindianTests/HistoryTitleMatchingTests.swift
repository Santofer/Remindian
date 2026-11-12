import XCTest
@testable import Remindian

/// Completed history must never claim new work by title.
///
/// Remindian guesses links by title in four places: importing a new reminder,
/// creating a reminder for a new vault task, cross-file dedup, and re-linking a
/// mapping whose vault task vanished. Weekly routines leave many completed
/// lines and reminders with the same title ("Clear out Reader" ✅ every week),
/// so a guess that pairs a completed item with a new open one is easy to hit:
///
/// - A new reminder was attached to a completed vault line instead of being
///   imported. The next sync saw "done in the vault, open in Reminders",
///   ticked the reminder off, removed its repeat and moved it to the old
///   line's list.
/// - A new open vault line was reconnected to an old completed reminder.
/// - Adding the line to Inbox.md hid same-title completed lines elsewhere
///   (cross-file dedup), orphaning their mappings. Their completed reminders
///   were then re-linked to the new open line, and "completed in Reminders"
///   wins, so the new line would be ticked off.
///
/// Matching open with open, and completed with completed, is unchanged.
final class HistoryTitleMatchingTests: XCTestCase {

    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    private func vaultTask(_ title: String, file: String, line: Int, completed: Bool, list: String = "Chores") -> SyncTask {
        SyncTask(
            title: title, isCompleted: completed, dueDate: due,
            completedDate: completed ? due : nil, tags: ["#\(list)"], targetList: list,
            obsidianSource: .init(filePath: file, lineNumber: line, originalLine: "- [\(completed ? "x" : " ")] \(title)")
        )
    }

    private func reminder(_ title: String, id: String, completed: Bool, list: String = "Chores") -> SyncTask {
        SyncTask(
            title: title, isCompleted: completed, dueDate: due,
            completedDate: completed ? due : nil, tags: ["#\(list)"], targetList: list, remindersId: id
        )
    }

    private func config() -> (SyncConfiguration, URL) {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let cfg = SyncConfiguration()
        cfg.vaultPath = vault.path
        cfg.addTaskLinkToReminders = false
        cfg.enableNewTaskWriteback = true
        cfg.syncCompletedTasks = false
        return (cfg, vault)
    }

    // MARK: - Importing a new reminder

    func test_newOpenReminderIsImported_notAttachedToCompletedHistory() async {
        let history = vaultTask("Clear out Reader", file: "/Library/Articles.md", line: 117, completed: true)
        let source = HistoryMockSource(tasks: [history])
        let destination = HistoryMockDestination(tasks: [reminder("Clear out Reader", id: "r-new", completed: false)])
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        _ = await SyncEngine(source: source, destination: destination, syncState: state).performSync(config: cfg)

        XCTAssertEqual(source.appended, ["Clear out Reader"], "The new reminder is new work: add it to the inbox.")
        XCTAssertNotEqual(state.findMapping(remindersId: "r-new")?.obsidianId, source.generateTaskId(for: history),
                          "It must not be linked to the completed history line.")
        XCTAssertEqual(destination.updated, [], "Nothing ticks the new reminder off.")
        XCTAssertEqual(destination.moved, [])
    }

    /// Control: the 2026-04-30 behaviour, a reminder whose open task is already
    /// in the vault (usually a 🔁 line elsewhere), still attaches to it.
    func test_newOpenReminderStillAttachesToOpenVaultTask() async {
        let open = vaultTask("Water plants", file: "/Home.md", line: 3, completed: false)
        let source = HistoryMockSource(tasks: [open])
        let destination = HistoryMockDestination(tasks: [reminder("Water plants", id: "r-1", completed: false)])
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        _ = await SyncEngine(source: source, destination: destination, syncState: state).performSync(config: cfg)

        XCTAssertEqual(source.appended, [], "No inbox duplicate.")
        XCTAssertEqual(destination.created, [], "No second reminder.")
        XCTAssertNotNil(state.findMapping(remindersId: "r-1"))
    }

    // MARK: - Creating a reminder for a new vault task

    func test_newOpenVaultTaskGetsFreshReminder_notAnOldCompletedOne() async {
        let line = vaultTask("Clear out Reader", file: "/Inbox.md", line: 32, completed: false)
        let source = HistoryMockSource(tasks: [line])
        let destination = HistoryMockDestination(tasks: [reminder("Clear out Reader", id: "r-old", completed: true, list: "Projects")])
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        _ = await SyncEngine(source: source, destination: destination, syncState: state).performSync(config: cfg)

        XCTAssertEqual(destination.created, ["Chores"], "A fresh reminder for the new line.")
        XCTAssertFalse(destination.updated.contains("r-old"), "The old completed reminder is not reopened.")
        XCTAssertNil(state.findMapping(remindersId: "r-old"))
    }

    // MARK: - Cross-file dedup and re-linking

    /// The sequence from the report: a completed line in another note is mapped
    /// to its completed reminder; an open line with the same title is added to
    /// Inbox.md. Across two syncs the history pair must stay as it was, and
    /// the new line must get its own reminder and stay open.
    func test_addingInboxLineDoesNotStealCompletedHistoryMapping() async {
        let history = vaultTask("Clear out Reader", file: "/Library/Articles.md", line: 117, completed: true, list: "Logistics")
        let newLine = vaultTask("Clear out Reader", file: "/Inbox.md", line: 32, completed: false)
        let oldReminder = reminder("Clear out Reader", id: "r-old", completed: true, list: "Logistics")
        let source = HistoryMockSource(tasks: [history, newLine])
        let destination = HistoryMockDestination(tasks: [oldReminder])
        let state = SyncState()
        state.addOrUpdateMapping(obsidianId: source.generateTaskId(for: history), remindersId: "r-old",
                                 obsidianHash: SyncState.generateTaskHash(history),
                                 remindersHash: SyncState.generateTaskHash(oldReminder))
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)

        XCTAssertEqual(state.findMapping(remindersId: "r-old")?.obsidianId, source.generateTaskId(for: history),
                       "The history pair keeps its link.")
        XCTAssertEqual(source.completed, [], "The new line is not ticked off.")
        XCTAssertFalse(destination.updated.contains("r-old"))
        XCTAssertEqual(destination.deleted, [])
        XCTAssertEqual(destination.created, ["Chores"], "The new line gets its own reminder.")
    }

    /// Backstop: even when a completed reminder's line really is gone, it is not
    /// re-linked to an open line with the same title.
    func test_completedReminderIsNotRelinkedToOpenLine() async {
        let gone = vaultTask("Clear out Podcasts", file: "/Archive.md", line: 39, completed: true)
        let newLine = vaultTask("Clear out Podcasts", file: "/Inbox.md", line: 33, completed: false)
        let oldReminder = reminder("Clear out Podcasts", id: "r-old", completed: true, list: "Research")
        let source = HistoryMockSource(tasks: [newLine])
        let destination = HistoryMockDestination(tasks: [oldReminder])
        let state = SyncState()
        state.addOrUpdateMapping(obsidianId: source.generateTaskId(for: gone), remindersId: "r-old",
                                 obsidianHash: SyncState.generateTaskHash(gone),
                                 remindersHash: SyncState.generateTaskHash(oldReminder))
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)

        XCTAssertNotEqual(state.findMapping(remindersId: "r-old")?.obsidianId, source.generateTaskId(for: newLine))
        XCTAssertEqual(source.completed, [], "The new line is not ticked off.")
        XCTAssertFalse(destination.updated.contains("r-old"), "The old reminder is not reopened.")
    }

    /// Control: an open reminder whose open line moved (new ID) is still re-linked.
    func test_openReminderStillRelinksToMovedOpenLine() async {
        let before = vaultTask("Pay rent", file: "/Home.md", line: 3, completed: false)
        let after = vaultTask("Pay rent", file: "/Home.md", line: 9, completed: false)
        let live = reminder("Pay rent", id: "r-1", completed: false)
        let source = HistoryMockSource(tasks: [after])
        let destination = HistoryMockDestination(tasks: [live])
        let state = SyncState()
        state.addOrUpdateMapping(obsidianId: source.generateTaskId(for: before), remindersId: "r-1",
                                 obsidianHash: SyncState.generateTaskHash(before),
                                 remindersHash: SyncState.generateTaskHash(live))
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }

        _ = await SyncEngine(source: source, destination: destination, syncState: state).performSync(config: cfg)

        XCTAssertEqual(state.findMapping(remindersId: "r-1")?.obsidianId, source.generateTaskId(for: after))
        XCTAssertEqual(destination.deleted, [])
        XCTAssertEqual(destination.created, [])
    }

    // MARK: - Completed reminders (syncCompletedTasks on)

    /// An old completed reminder must not be linked to an open vault task with
    /// the same title. Completion in Reminders wins on the next sync, so the
    /// open task would be ticked off by a months-old reminder.
    func test_oldCompletedReminderDoesNotCompleteOpenVaultTask() async {
        let open = vaultTask("weekly standup", file: "/Work.md", line: 3, completed: false)
        let source = HistoryMockSource(tasks: [open])
        let destination = HistoryMockDestination(tasks: [reminder("weekly standup", id: "r-old", completed: true)])
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }
        cfg.syncCompletedTasks = true

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)

        XCTAssertEqual(source.completed, [], "The open task stays open.")
        XCTAssertNotEqual(state.findMapping(remindersId: "r-old")?.obsidianId, source.generateTaskId(for: open))
    }

    /// Control: a completed reminder still links to the completed line it matches.
    func test_completedReminderStillLinksToCompletedLine() async {
        let done = vaultTask("weekly standup", file: "/Work.md", line: 3, completed: true)
        let source = HistoryMockSource(tasks: [done])
        let destination = HistoryMockDestination(tasks: [reminder("weekly standup", id: "r-old", completed: true)])
        let state = SyncState()
        let (cfg, vault) = config(); defer { try? FileManager.default.removeItem(at: vault) }
        cfg.syncCompletedTasks = true

        _ = await SyncEngine(source: source, destination: destination, syncState: state).performSync(config: cfg)

        XCTAssertEqual(state.findMapping(remindersId: "r-old")?.obsidianId, source.generateTaskId(for: done))
        XCTAssertEqual(source.appended, [])
    }
}

private final class HistoryMockSource: TaskSource {
    let sourceName = "HistoryMockSource"
    let tasks: [SyncTask]
    private(set) var appended: [String] = []
    private(set) var completed: [String] = []
    init(tasks: [SyncTask]) { self.tasks = tasks }
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { tasks }
    func generateTaskId(for task: SyncTask) -> String {
        "\(task.obsidianSource?.filePath ?? "")|\(task.title)|L\(task.obsidianSource?.lineNumber ?? 0)"
    }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        completed.append(task.title); return 0
    }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        appended.append(task.title)
        return .init(filePath: "/Inbox.md", lineNumber: 100 + appended.count, originalLine: "- [ ] \(task.title)")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

private final class HistoryMockDestination: TaskDestination {
    let destinationName = "HistoryMockDestination"
    private(set) var tasks: [SyncTask]
    private(set) var updated: [String] = []
    private(set) var moved: [String] = []
    private(set) var created: [String] = []
    private(set) var deleted: [String] = []
    init(tasks: [SyncTask]) { self.tasks = tasks }
    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Chores", "Logistics", "Research", "Projects", "Inbox"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        created.append(listName)
        var made = task
        made.remindersId = "new-\(created.count)"
        made.targetList = listName
        made.obsidianSource = nil
        tasks.append(made)
        return made.remindersId!
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws { updated.append(id) }
    func moveTask(withId id: String, toList listName: String) async throws { moved.append(listName) }
    func deleteTask(withId id: String) async throws { deleted.append(id) }
    func refresh() {}
}
