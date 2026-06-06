import XCTest
@testable import Remindian

/// Regression test for the silent data-loss fix in the dedup-reconnect path
/// (v5.11.0, plan item 1B).
///
/// **Bug.** When a new Obsidian task matched an existing destination reminder
/// by title, the engine pushed source content with `try?` — swallowing any
/// error — then stored the mapping with the *current* obsidian hash. If the
/// push failed, the next sync saw `hasObsidianChanged == false` and never
/// retried: the update was lost forever, silently.
///
/// **Fix.** do/catch: surface the error in `result.errors`, and on failure
/// store the mapping with an EMPTY obsidianHash so the next sync detects a
/// change and re-pushes.
final class SyncEngineReconnectFailureTests: XCTestCase {

    func test_reconnectUpdateFailure_surfacesErrorAndForcesRetry() async throws {
        let vault = try TempVaultRF()
        defer { vault.cleanup() }

        // One Obsidian task, no existing mapping → reaches the Step 5 new-task
        // path, where it reconnects to the same-title reminder below.
        let obsTask = SyncTask(
            title: "Buy milk",
            isCompleted: false,
            tags: ["#shopping"],
            targetList: "shopping",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/Inbox.md", lineNumber: 1, originalLine: "- [ ] Buy milk #shopping"
            )
        )
        let source = ReconnectMockSource(scanned: [obsTask])

        // A reminder with the SAME title, unmapped → the reconnect target.
        // Its updateTask is rigged to throw.
        let destination = ReconnectMockDestination(
            tasks: [SyncTask(title: "Buy milk", isCompleted: false, remindersId: "rem-1")],
            updateShouldThrow: true
        )

        let state = SyncState()
        let engine = SyncEngine(source: source, destination: destination, syncState: state)

        var cfg = SyncConfiguration()
        cfg.vaultPath = vault.path

        let result = await engine.performSync(config: cfg)

        // The failed push must surface as an error (not be swallowed).
        XCTAssertFalse(
            result.errors.isEmpty,
            "A failed reconnect updateTask must surface in result.errors, not be swallowed by try?."
        )

        // The mapping must still be linked (the reminder exists), BUT with an
        // empty obsidianHash so the next sync re-pushes.
        let mapping = state.findMapping(remindersId: "rem-1")
        XCTAssertNotNil(mapping, "The reminder is the right one — link it so we don't recreate a duplicate.")
        XCTAssertEqual(
            mapping?.lastObsidianHash, "",
            "On push failure the stored obsidianHash must be empty so the next sync detects a change and retries."
        )
    }

    func test_reconnectUpdateSuccess_storesRealHash() async throws {
        let vault = try TempVaultRF()
        defer { vault.cleanup() }

        let obsTask = SyncTask(
            title: "Buy milk",
            isCompleted: false,
            tags: ["#shopping"],
            targetList: "shopping",
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/Inbox.md", lineNumber: 1, originalLine: "- [ ] Buy milk #shopping"
            )
        )
        let source = ReconnectMockSource(scanned: [obsTask])
        let destination = ReconnectMockDestination(
            tasks: [SyncTask(title: "Buy milk", isCompleted: false, remindersId: "rem-1")],
            updateShouldThrow: false
        )
        let state = SyncState()
        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        var cfg = SyncConfiguration()
        cfg.vaultPath = vault.path

        _ = await engine.performSync(config: cfg)

        let mapping = state.findMapping(remindersId: "rem-1")
        XCTAssertNotNil(mapping)
        XCTAssertFalse(
            mapping?.lastObsidianHash.isEmpty ?? true,
            "On success the real obsidian hash is stored (no spurious retry next sync)."
        )
        XCTAssertEqual(mapping?.lastObsidianHash, SyncState.generateTaskHash(obsTask))
        XCTAssertTrue(destination.updateCalled, "Happy path must actually call updateTask.")
    }
}

// MARK: - Fixtures

private struct ReconnectError: Error {}

private final class TempVaultRF {
    let url: URL
    var path: String { url.path }
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-reconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // performSync requires a .obsidian dir for the Obsidian Tasks source.
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private final class ReconnectMockSource: TaskSource {
    let sourceName = "ReconnectMockSource"
    private let scanned: [SyncTask]
    init(scanned: [SyncTask]) { self.scanned = scanned }

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { scanned }
    func generateTaskId(for task: SyncTask) -> String { "mock-\(task.title)" }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        SyncTask.ObsidianSource(filePath: "/Inbox.md", lineNumber: 1, originalLine: "- [ ] \(task.title)")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

private final class ReconnectMockDestination: TaskDestination {
    let destinationName = "ReconnectMockDestination"
    private let tasks: [SyncTask]
    private let updateShouldThrow: Bool
    private(set) var updateCalled = false
    var progressCallback: ((String) -> Void)?

    init(tasks: [SyncTask], updateShouldThrow: Bool) {
        self.tasks = tasks
        self.updateShouldThrow = updateShouldThrow
    }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["shopping"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String { "new-id" }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        updateCalled = true
        if updateShouldThrow { throw ReconnectError() }
    }
    func moveTask(withId id: String, toList listName: String) async throws {}
    func deleteTask(withId id: String) async throws {}
    func refresh() {}
}
