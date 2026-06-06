import XCTest
@testable import Remindian

/// Regression tests for the silent-data-loss bug where a Reminders-side change
/// (due date, completion, etc.) was permanently dropped when the .md file's
/// mtime bumped between sync-start and the per-mapping writeback check.
///
/// **The bug.** `SyncEngine.performSync` was unconditionally rolling both
/// `lastObsidianHash` and `lastRemindersHash` forward to
/// `generateTaskHash(taskForReminders)` at the end of each mapping iteration —
/// *even when* the `fileNotModifiedBeforeSync` guard had silently blocked the
/// Obsidian-side writeback. The stored state then claimed "everything is
/// synced" for a change that had never reached Obsidian. The next sync saw no
/// diff to retry, and on the sync after that the "Obsidian wins" path
/// overwrote the user's Reminders edit too.
///
/// **The fix.** When the file-mod guard skips the writeback, preserve the
/// pre-sync hashes so the next sync re-detects `rChanged` and retries.
///
/// These tests pin the `SyncState.addOrUpdateMapping` invariant that Fix 1
/// depends on: passing the old hashes through must actually preserve them.
/// If a future refactor accidentally rewrites that semantic (e.g. always
/// regenerating from the live task), the fix silently breaks and the bug
/// returns. The full SyncEngine path is verified end-to-end manually since
/// the project doesn't yet have mock infrastructure for `TaskSource` /
/// `TaskDestination`.
final class FileModSkipRegressionTests: XCTestCase {

    func testAddOrUpdateMappingWithSameHashesPreservesThem() {
        let state = SyncState()
        let oldHash = "OLD_HASH_VALUE"
        state.addOrUpdateMapping(
            obsidianId: "task-1",
            remindersId: "reminder-1",
            obsidianHash: oldHash,
            remindersHash: oldHash
        )
        let firstSyncDate = state.findMapping(obsidianId: "task-1")?.lastSyncDate

        // Simulate the Fix 1 path: writeback was skipped, so we re-call
        // addOrUpdateMapping with the same (pre-sync) hashes to refresh
        // lastSyncDate without poisoning the diff signal.
        Thread.sleep(forTimeInterval: 0.01)  // ensure date strictly advances
        state.addOrUpdateMapping(
            obsidianId: "task-1",
            remindersId: "reminder-1",
            obsidianHash: oldHash,
            remindersHash: oldHash
        )

        guard let mapping = state.findMapping(obsidianId: "task-1") else {
            XCTFail("Mapping must still exist")
            return
        }
        XCTAssertEqual(
            mapping.lastObsidianHash, oldHash,
            "Re-saving with the same obsidianHash must preserve it. Fix 1 relies on this so the next sync still sees rChanged and retries."
        )
        XCTAssertEqual(
            mapping.lastRemindersHash, oldHash,
            "Re-saving with the same remindersHash must preserve it. Without this preservation, a writeback skipped due to file-mod is permanently lost."
        )
        XCTAssertNotNil(firstSyncDate)
        XCTAssertGreaterThan(
            mapping.lastSyncDate, firstSyncDate!,
            "lastSyncDate should still advance even when hashes are preserved — the sync did run, it just didn't write."
        )
    }

    func testAddOrUpdateMappingWithNewHashesOverridesThem() {
        // Positive control: the happy path (writeback succeeded) must still
        // roll hashes forward as it always has. Fix 1 must not have broken this.
        let state = SyncState()
        state.addOrUpdateMapping(
            obsidianId: "task-2",
            remindersId: "reminder-2",
            obsidianHash: "INITIAL",
            remindersHash: "INITIAL"
        )

        state.addOrUpdateMapping(
            obsidianId: "task-2",
            remindersId: "reminder-2",
            obsidianHash: "UPDATED",
            remindersHash: "UPDATED"
        )

        let mapping = state.findMapping(obsidianId: "task-2")
        XCTAssertEqual(mapping?.lastObsidianHash, "UPDATED")
        XCTAssertEqual(mapping?.lastRemindersHash, "UPDATED")
    }

    func testHasRemindersChangedReportsTrueWhenStoredHashIsStale() {
        // Documents the diff-detection contract Fix 1 depends on. After a
        // skipped writeback, the stored remindersHash stays at its pre-sync
        // value. On the next sync, currentHash (computed from rTask which
        // still has the user's new Reminders value) differs from
        // lastRemindersHash → hasRemindersChanged returns true → the
        // metadata writeback block at SyncEngine.swift:565 is re-entered.
        let mapping = SyncState.TaskMapping(
            obsidianId: "task-3",
            remindersId: "reminder-3",
            lastObsidianHash: "PRE_SYNC_OBSIDIAN",
            lastRemindersHash: "PRE_SYNC_REMINDERS",
            lastSyncDate: Date()
        )
        XCTAssertTrue(
            mapping.hasRemindersChanged(currentHash: "NEW_REMINDERS_HASH"),
            "When the live rTask hash differs from the preserved lastRemindersHash, the retry must fire."
        )
        XCTAssertFalse(
            mapping.hasRemindersChanged(currentHash: "PRE_SYNC_REMINDERS"),
            "Sanity: identical hashes mean no change. If this fails, the diff-detection logic itself is broken."
        )
    }

    // MARK: - Phantom "N updated every sync" regression (reminders-hash list seed)

    /// End-to-end reproduction of the "N tasks updated every sync with nothing
    /// changing" bug. After a mapping is synced, `lastRemindersHash` must equal
    /// what the LIVE reminder hashes to on the next fetch — including its actual
    /// destination list. The bug stored the Obsidian task's hash (whose
    /// targetList is empty for inbox tasks, or the raw lowercase tag), which
    /// never matched the reminder's real list ("Inbox", "Someday", …). Every
    /// subsequent sync then saw a phantom rChanged=true and redundantly
    /// re-pushed, logging "N updated" forever.
    ///
    /// Drives the real `performSync` via mock source/destination (seam added in
    /// v5.10.1). Sync 1 corrects the stored hash; sync 2 must be a clean no-op.
    func testNoPhantomRechangeWhenObsidianListIsEmptyButReminderHasList() async throws {
        let vault = try PhantomTempVault()
        defer { vault.cleanup() }

        // Inbox task: no tag → targetList resolves to defaultList ("Inbox").
        let obsidianTask = SyncTask(
            title: "Respond to Suzie's email",
            isCompleted: false,
            targetList: nil,
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/Inbox.md",
                lineNumber: 3,
                originalLine: "- [ ] Respond to Suzie's email"
            )
        )
        // The live reminder actually lives in the "Inbox" list.
        let reminder = SyncTask(
            title: "Respond to Suzie's email",
            isCompleted: false,
            targetList: "Inbox",
            remindersId: "r-suzie"
        )

        let source = PhantomMockSource(scannedTasks: [obsidianTask])
        let destination = PhantomMockDestination(tasks: [reminder])

        // Seed the mapping with the OLD buggy reminders hash: the Obsidian
        // task's hash, whose targetList is empty. This is exactly what the
        // pre-fix save wrote, and what we found in the user's real sync_state.
        let state = SyncState()
        let obsidianId = source.generateTaskId(for: obsidianTask)
        state.addOrUpdateMapping(
            obsidianId: obsidianId,
            remindersId: "r-suzie",
            obsidianHash: SyncState.generateTaskHash(obsidianTask),
            remindersHash: SyncState.generateTaskHash(obsidianTask)  // buggy: empty list
        )

        let engine = SyncEngine(source: source, destination: destination, syncState: state)

        // SyncConfiguration is a class — property mutation works through `let`.
        let cfg = SyncConfiguration()
        cfg.vaultPath = vault.path
        cfg.defaultList = "Inbox"
        cfg.addTaskLinkToReminders = false  // isolate: URL backfill is a separate entry trigger

        // Sync 1: stored empty-list hash != live "Inbox" hash → rChanged fires,
        // the fix re-stores the reminders hash seeded with the resolved list.
        _ = await engine.performSync(config: cfg)

        XCTAssertEqual(
            state.findMapping(remindersId: "r-suzie")?.lastRemindersHash,
            SyncState.generateTaskHash(reminder),
            "After sync, lastRemindersHash must equal the LIVE reminder's hash (incl. its real 'Inbox' list) so the next sync sees no phantom change."
        )

        // Sync 2: steady state — must be a clean no-op for this mapping.
        let result2 = await engine.performSync(config: cfg)
        XCTAssertEqual(
            result2.updated, 0,
            "Second sync must report zero updates. A non-zero count means the phantom-rechange flap is back. errors=\(result2.errors)"
        )
    }
}

// MARK: - Test fixtures (phantom-rechange test)

/// Minimal on-disk vault so `performSync` clears its vaultPath + `.obsidian`
/// preconditions. Never read from — the mock source returns its own tasks.
private final class PhantomTempVault {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-phantom-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".obsidian"),
            withIntermediateDirectories: true
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private final class PhantomMockSource: TaskSource {
    let sourceName = "PhantomMockSource"
    private let scannedTasks: [SyncTask]

    init(scannedTasks: [SyncTask]) { self.scannedTasks = scannedTasks }

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { scannedTasks }
    func generateTaskId(for task: SyncTask) -> String { "mock-\(task.title)" }

    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        XCTFail("markTaskComplete must not be called: nothing changed"); return 0
    }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        XCTFail("markTaskIncomplete must not be called: nothing changed")
    }
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        XCTFail("updateTaskMetadata must not be called: due/start/priority all match")
    }
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        XCTFail("appendNewTask must not be called: task is already mapped")
        return SyncTask.ObsidianSource(filePath: "Inbox.md", lineNumber: 1, originalLine: "")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

private final class PhantomMockDestination: TaskDestination {
    let destinationName = "PhantomMockDestination"
    let tasks: [SyncTask]
    private(set) var updateCount = 0

    init(tasks: [SyncTask]) { self.tasks = tasks }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Inbox"] }

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        XCTFail("createTask must not be called: task is already mapped"); return ""
    }
    // Called once on sync 1 (the redundant push that re-baselines the hash). No-op.
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws { updateCount += 1 }
    func moveTask(withId id: String, toList listName: String) async throws {
        XCTFail("moveTask must not be called: reminder is already in the resolved list")
    }
    func deleteTask(withId id: String) async throws {
        XCTFail("deleteTask must not be called")
    }
    func refresh() {}
}
