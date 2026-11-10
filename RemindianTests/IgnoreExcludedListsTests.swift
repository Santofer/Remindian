import XCTest
@testable import Remindian

/// "Ignore excluded lists completely": a reminder that was synced before its
/// list was excluded (typically a shared list) must be left alone — not
/// updated, moved, completed, recreated elsewhere or deleted.
///
/// Without the setting, mapped reminders in excluded lists keep syncing, so a
/// task whose tag routes elsewhere is moved out of the list on every sync. For
/// a shared list EventKit refuses the move (reminderkit -3002), so it's retried
/// on every sync.
final class IgnoreExcludedListsTests: XCTestCase {

    private func run(ignoreCompletely: Bool) async throws -> (IgnoreMockDestination, SyncState) {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // Changed in the vault since the last sync (new due date), and tagged
        // for a list other than the shared one it lives in.
        let task = SyncTask(
            title: "Sign up for EBT", dueDate: Date(timeIntervalSince1970: 1_800_000_000),
            tags: ["#Logistics"], targetList: "Logistics",
            obsidianSource: .init(filePath: "/Inbox.md", lineNumber: 4, originalLine: "- [ ] Sign up for EBT #Logistics")
        )
        let reminder = SyncTask(title: "Sign up for EBT", tags: ["#Logistics"], targetList: "Shared", remindersId: "r-ebt")
        let source = IgnoreMockSource(tasks: [task])
        let destination = IgnoreMockDestination(tasks: [reminder])
        let state = SyncState()
        var previous = task
        previous.dueDate = nil
        state.addOrUpdateMapping(obsidianId: source.generateTaskId(for: task), remindersId: "r-ebt",
                                 obsidianHash: SyncState.generateTaskHash(previous),
                                 remindersHash: SyncState.generateTaskHash(reminder))

        let cfg = SyncConfiguration()
        cfg.vaultPath = vault.path
        cfg.addTaskLinkToReminders = false
        cfg.excludedRemindersLists = ["Shared"]
        cfg.ignoreExcludedListsCompletely = ignoreCompletely

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)
        return (destination, state)
    }

    func test_reminderInIgnoredExcludedListIsLeftAlone() async throws {
        let (destination, state) = try await run(ignoreCompletely: true)
        XCTAssertEqual(destination.updated, [], "Not updated")
        XCTAssertEqual(destination.moved, [], "Not moved out of the shared list")
        XCTAssertEqual(destination.created, [], "Not recreated elsewhere")
        XCTAssertEqual(destination.deleted, [], "Not deleted")
        XCTAssertNotNil(state.findMapping(remindersId: "r-ebt"), "The mapping is kept, so turning the setting off later resumes syncing it")
    }

    /// Control: the long-standing behaviour is unchanged when the setting is off.
    func test_withoutTheSettingMappedRemindersInExcludedListsStillSync() async throws {
        let (destination, _) = try await run(ignoreCompletely: false)
        XCTAssertFalse(destination.updated.isEmpty, "Still updated")
        XCTAssertEqual(destination.moved.first, "Logistics", "Still routed to its tag's list")
        XCTAssertEqual(destination.created, [])
        XCTAssertEqual(destination.deleted, [])
    }
}

private final class IgnoreMockSource: TaskSource {
    let sourceName = "IgnoreMockSource"
    let tasks: [SyncTask]
    init(tasks: [SyncTask]) { self.tasks = tasks }
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { tasks }
    func generateTaskId(for task: SyncTask) -> String { "\(task.title)|\(task.tags.sorted().joined(separator: ","))" }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        XCTFail("appendNewTask must not be called"); return .init(filePath: "Inbox.md", lineNumber: 1, originalLine: "")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

private final class IgnoreMockDestination: TaskDestination {
    let destinationName = "IgnoreMockDestination"
    let tasks: [SyncTask]
    private(set) var updated: [String] = []
    private(set) var moved: [String] = []
    private(set) var created: [String] = []
    private(set) var deleted: [String] = []
    init(tasks: [SyncTask]) { self.tasks = tasks }
    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Shared", "Logistics"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        created.append(listName); return "new"
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws { updated.append(id) }
    func moveTask(withId id: String, toList listName: String) async throws { moved.append(listName) }
    func deleteTask(withId id: String) async throws { deleted.append(id) }
    func refresh() {}
}
