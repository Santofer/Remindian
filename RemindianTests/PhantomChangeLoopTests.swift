import XCTest
@testable import Remindian

/// #99 — "Reminders changed" logged on every sync, forever, with nothing changing.
///
/// After pushing a task the engine used to store a *predicted* fingerprint of the
/// reminder ("what it should now look like"). A destination is lossy, though: with
/// "Include due time" off, a task due at 10:00 becomes an all-day reminder, so the
/// prediction (10:00) never matches what the next fetch returns (midnight). The
/// engine then saw a phantom Reminders-side change on every single sync — one
/// user logged it 16,500 times for one task and grew a 327 MB debug log.
final class PhantomChangeLoopTests: XCTestCase {

    private func dueAt(hour: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 14; c.hour = hour
        return Calendar.current.date(from: c)!
    }

    private func makeEngine(task: SyncTask) -> (SyncEngine, LossyDestination, SyncConfiguration, TempVaultPL) {
        let vault = try! TempVaultPL()
        let destination = LossyDestination()
        let engine = SyncEngine(source: FixedSource(scanned: [task]), destination: destination, syncState: SyncState())
        let config = SyncConfiguration()
        config.vaultPath = vault.path
        return (engine, destination, config, vault)
    }

    private func timedTask() -> SyncTask {
        SyncTask(
            title: "Dentist",
            isCompleted: false,
            dueDate: dueAt(hour: 10),
            obsidianSource: SyncTask.ObsidianSource(filePath: "/tasks/dentist.md", lineNumber: 1, originalLine: "due: 2026-10-14T10:00")
        )
    }

    func test_99_lossyDestinationSettlesInsteadOfLoopingForever() async {
        let (engine, destination, config, vault) = makeEngine(task: timedTask())
        defer { vault.cleanup() }

        _ = await engine.performSync(config: config)          // creates
        _ = await engine.performSync(config: config)          // may reconcile once
        let before = destination.updateCount

        for round in 3...6 {
            let result = await engine.performSync(config: config)
            XCTAssertEqual(result.updated, 0,
                           "Sync \(round): nothing changed on either side, so nothing may be reported as updated")
        }
        XCTAssertEqual(destination.updateCount, before,
                       "A settled task must not be pushed again on every sync")
    }

    func test_99_realReminderEditIsStillDetected() async throws {
        // The fix must not blind the engine: a genuine edit in Reminders still counts.
        let (engine, destination, config, vault) = makeEngine(task: timedTask())
        defer { vault.cleanup() }

        _ = await engine.performSync(config: config)
        _ = await engine.performSync(config: config)
        _ = await engine.performSync(config: config)

        destination.userEdits { $0.priority = .high }

        let result = await engine.performSync(config: config)
        XCTAssertEqual(result.updated, 1, "A real change made in Reminders must still be picked up")
    }
}

// MARK: - Fixtures

private final class TempVaultPL {
    let url: URL
    var path: String { url.path }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-phantom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private final class FixedSource: TaskSource {
    let sourceName = "FixedSource"
    private let scanned: [SyncTask]
    init(scanned: [SyncTask]) { self.scanned = scanned }
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { scanned }
    func generateTaskId(for task: SyncTask) -> String { "fixed-\(task.title)" }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        SyncTask.ObsidianSource(filePath: "/Inbox.md", lineNumber: 1, originalLine: "- [ ] \(task.title)")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

/// Stores what it is given the way Apple Reminders does with "Include due time"
/// off: the time-of-day is dropped, so what comes back is not what went in.
private final class LossyDestination: TaskDestination {
    let destinationName = "LossyDestination"
    var progressCallback: ((String) -> Void)?
    private var stored: [String: SyncTask] = [:]
    private(set) var updateCount = 0

    private func lossy(_ task: SyncTask, id: String, list: String) -> SyncTask {
        var t = task
        t.remindersId = id
        t.targetList = list
        t.obsidianSource = nil
        if let due = t.dueDate { t.dueDate = Calendar.current.startOfDay(for: due) }
        // A real reminder carries the obsidian:// link once synced; without it the
        // engine would (rightly) keep trying to backfill it.
        t.url = URL(string: "obsidian://open?vault=v&file=f")
        return t
    }

    func userEdits(_ edit: (inout SyncTask) -> Void) {
        for id in stored.keys { edit(&stored[id]!) }
    }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { Array(stored.values) }
    func getAvailableLists() async -> [String] { ["Reminders"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let id = "rem-\(stored.count + 1)"
        stored[id] = lossy(task, id: id, list: listName)
        return id
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        updateCount += 1
        stored[id] = lossy(task, id: id, list: stored[id]?.targetList ?? "Reminders")
    }
    func moveTask(withId id: String, toList listName: String) async throws { stored[id]?.targetList = listName }
    func deleteTask(withId id: String) async throws { stored[id] = nil }
    func refresh() {}
    func currentTask(withId id: String) async -> SyncTask? { stored[id] }
}
