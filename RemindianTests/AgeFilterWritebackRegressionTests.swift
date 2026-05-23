import XCTest
@testable import Remindian

/// Regression tests for the `maxCompletedTaskAgeDays` filter asymmetry.
///
/// **The bug.** The age cutoff was applied to the source scan (Step 1) but not
/// to the Reminders → Obsidian writeback (Step 6). With
/// `enableNewTaskWriteback = true` and a long history of completed reminders,
/// every old completion was eligible for writeback into the source vault on
/// next sync — recreating the exact symptom that #11 was filed for (and that
/// v3.3.0 only half-fixed by adding the setting).
///
/// **The fix.** Split the filter into two helpers:
///   * `SyncEngine.completedTaskCutoffDate(for:)` — compute the cutoff once
///     per sync; returns nil when the filter is disabled.
///   * `SyncEngine.isCompletedTaskTooOld(_:cutoff:)` — pure comparison.
/// Both the source scan (Step 1) and the writeback loop (Step 6) call the
/// pair. In the writeback loop the age filter runs AFTER the v5.8.2 title-
/// dedup so the dedup's `syncState.addOrUpdateMapping(...)` side-effect is
/// preserved for old reminders whose titles match an existing vault task.
///
/// The tests split into two groups: pure helper unit tests at the top, then
/// integration tests at the bottom that drive `SyncEngine.performSync(...)`
/// with mock `TaskSource` / `TaskDestination` so the writeback site itself is
/// exercised — without these, a future refactor that inverts or removes the
/// `if` at the writeback call site would pass the unit tests but reintroduce
/// the bug.
final class AgeFilterWritebackRegressionTests: XCTestCase {

    // Fixed Gregorian calendar so the test is robust to CI machines running
    // under non-Gregorian default locales (Hebrew, Buddhist, Japanese, ...).
    // Force-unwrapping `Calendar.current.date(byAdding:)` would crash there.
    private let gregorian = Calendar(identifier: .gregorian)

    private func config(maxAgeDays: Int) -> SyncConfiguration {
        var c = SyncConfiguration()
        c.maxCompletedTaskAgeDays = maxAgeDays
        c.syncCompletedTasks = true
        c.enableNewTaskWriteback = true
        return c
    }

    private func daysAgo(_ n: Int) throws -> Date {
        try XCTUnwrap(gregorian.date(byAdding: .day, value: -n, to: Date()))
    }

    private func cutoff(maxAgeDays: Int) -> Date? {
        SyncEngine.completedTaskCutoffDate(for: config(maxAgeDays: maxAgeDays))
    }

    // MARK: - Helper unit tests

    /// A reminder completed 31 days ago, when `maxCompletedTaskAgeDays = 30`,
    /// must be filtered.
    func testOldCompletedReminderIsFilteredByHelper() throws {
        let task = SyncTask(
            title: "Old completed reminder",
            isCompleted: true,
            completedDate: try daysAgo(31)
        )
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: cutoff(maxAgeDays: 30)),
            "Reminder completed 31 days ago must be filtered when maxCompletedTaskAgeDays=30. Without this, old completed reminders bypass the cutoff via the writeback path. (regression: #11 part 2)"
        )
    }

    /// Fallback path: when a completed task has no `completedDate`, the helper
    /// uses `lastModified` instead. Mirrors the source-scan behavior.
    func testCompletedReminderWithoutCompletedDateFallsBackToLastModified() throws {
        var task = SyncTask(
            title: "Completed but no completedDate",
            isCompleted: true,
            completedDate: nil
        )
        task.lastModified = try daysAgo(60)
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: cutoff(maxAgeDays: 30)),
            "When completedDate is nil, lastModified must be consulted. The source-scan filter does this; writeback must match."
        )
    }

    /// A reminder completed 5 days ago must NOT be filtered when the cutoff is
    /// 30 days. Catches over-filtering — i.e. the helper accidentally returning
    /// true for in-window tasks.
    func testRecentCompletedReminderIsNotFiltered() throws {
        let task = SyncTask(
            title: "Recently completed reminder",
            isCompleted: true,
            completedDate: try daysAgo(5)
        )
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: cutoff(maxAgeDays: 30)),
            "Reminder completed within the 30-day window must NOT be filtered — that would over-correct and hide legitimate recent work."
        )
    }

    /// An uncompleted reminder must never be filtered, regardless of how stale
    /// `lastModified` is. The age cutoff is about completion age only.
    func testUncompletedReminderIsNeverFilteredEvenIfStale() throws {
        var task = SyncTask(
            title: "Old open reminder",
            isCompleted: false,
            completedDate: nil
        )
        task.lastModified = try daysAgo(365)
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: cutoff(maxAgeDays: 30)),
            "Uncompleted tasks must never be age-filtered. Open work doesn't expire."
        )
    }

    /// `maxCompletedTaskAgeDays = 0` (disabled) must short-circuit
    /// `completedTaskCutoffDate(for:)` to nil, and the comparison helper must
    /// then return false for everything.
    func testDisabledSettingNeverFilters() throws {
        let task = SyncTask(
            title: "Ancient completed reminder",
            isCompleted: true,
            completedDate: try daysAgo(3650)
        )
        XCTAssertNil(
            SyncEngine.completedTaskCutoffDate(for: config(maxAgeDays: 0)),
            "Disabled setting must produce a nil cutoff so callers can skip the filter step entirely."
        )
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: nil),
            "A nil cutoff must always return false — otherwise toggling the setting off would silently break sync."
        )
    }

    /// Boundary semantics: source scan uses `> cutoff` to KEEP, so equal-to-
    /// cutoff is dropped. Helper uses `<= cutoff` to FILTER. These must agree.
    func testBoundaryCaseMatchesSourceScanSemantics() throws {
        let cutoffDate = try XCTUnwrap(gregorian.date(byAdding: .day, value: -30, to: Date()))
        var task = SyncTask(
            title: "Edge case",
            isCompleted: true,
            completedDate: cutoffDate
        )
        task.lastModified = cutoffDate
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, cutoff: cutoffDate),
            "Boundary semantics must match source-scan filter. Source uses `> cutoff` to keep, so equal-to-cutoff is dropped; helper does the same with `<= cutoff`."
        )
    }

    // MARK: - Integration tests (drive performSync via mock source/destination)

    /// End-to-end: the writeback loop must skip old completed reminders and
    /// append everything else. Without this test, a refactor that inverts the
    /// `if SyncEngine.isCompletedTaskTooOld(...)` at the writeback site (or
    /// removes the block) would silently re-introduce the bug — the helper
    /// unit tests above all still pass in that case.
    func testWritebackSkipsOldCompletedReminders() async throws {
        let vault = try TempVault()
        defer { vault.cleanup() }

        let source = MockTaskSource()
        let destination = MockTaskDestination(tasks: [
            SyncTask(title: "old completed", isCompleted: true, completedDate: try daysAgo(60), remindersId: "r-old"),
            SyncTask(title: "recent completed", isCompleted: true, completedDate: try daysAgo(5), remindersId: "r-recent"),
            SyncTask(title: "open task", isCompleted: false, remindersId: "r-open"),
        ])
        let engine = SyncEngine(source: source, destination: destination, syncState: SyncState())

        var cfg = config(maxAgeDays: 30)
        cfg.vaultPath = vault.path

        let result = await engine.performSync(config: cfg)

        let appendedTitles = source.appendedTasks.map(\.title).sorted()
        XCTAssertEqual(
            appendedTitles, ["open task", "recent completed"],
            "Writeback must append recent + open reminders and skip the old completed one. errors=\(result.errors)"
        )
        XCTAssertFalse(
            appendedTitles.contains("old completed"),
            "Old completed reminder must not reach appendNewTask — that's exactly the #68 regression."
        )
    }

    /// The reorder (v5.8.2 dedup BEFORE age filter) must preserve the dedup's
    /// `syncState.addOrUpdateMapping(...)` side-effect for old reminders whose
    /// titles match an existing vault task. If a future refactor swaps the
    /// order back, this assertion fails.
    func testWritebackPreservesDedupMappingForOldMatchedReminders() async throws {
        let vault = try TempVault()
        defer { vault.cleanup() }

        let matchingTitle = "weekly standup"
        let existingVaultTask = SyncTask(
            title: matchingTitle,
            isCompleted: false,
            tags: ["#work"],
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/Work.md",
                lineNumber: 3,
                originalLine: "- [ ] \(matchingTitle) #work"
            )
        )

        let source = MockTaskSource(scannedTasks: [existingVaultTask])
        let destination = MockTaskDestination(tasks: [
            // Old completed reminder whose title matches a vault task.
            SyncTask(title: matchingTitle, isCompleted: true, completedDate: try daysAgo(120), remindersId: "r-old-match"),
        ])

        let state = SyncState()
        let engine = SyncEngine(source: source, destination: destination, syncState: state)

        var cfg = config(maxAgeDays: 30)
        cfg.vaultPath = vault.path

        _ = await engine.performSync(config: cfg)

        let existingObsidianId = source.generateTaskId(for: existingVaultTask)
        XCTAssertNotNil(
            state.findMapping(remindersId: "r-old-match"),
            "Dedup must run BEFORE the age filter so an old completed reminder whose title matches a vault task still produces a syncState mapping. Otherwise that reminder appears unmapped on every sync and the 'Skipped N' count includes it forever. (regression: reorder)"
        )
        XCTAssertEqual(
            state.findMapping(remindersId: "r-old-match")?.obsidianId,
            existingObsidianId,
            "Mapping must point at the matching vault task's obsidianId."
        )
        XCTAssertFalse(
            source.appendedTasks.contains(where: { $0.title == matchingTitle }),
            "An old completed reminder with a title match must NOT be appended — dedup skips, age skip would also skip."
        )
    }

    /// Locks in the guard ordering: when `syncCompletedTasks = false`, the
    /// existing first-line guard skips all completed reminders before our age
    /// filter ever runs. The age filter is dead code in this path — but the
    /// behavior is still correct (no completed reminder is appended). A future
    /// refactor that removes the `syncCompletedTasks` half of that guard must
    /// keep the age filter as the safety net.
    func testWritebackUnreachableWhenSyncCompletedTasksFalse() async throws {
        let vault = try TempVault()
        defer { vault.cleanup() }

        let source = MockTaskSource()
        let destination = MockTaskDestination(tasks: [
            SyncTask(title: "old completed", isCompleted: true, completedDate: try daysAgo(60), remindersId: "r-old"),
            SyncTask(title: "open task", isCompleted: false, remindersId: "r-open"),
        ])
        let engine = SyncEngine(source: source, destination: destination, syncState: SyncState())

        var cfg = config(maxAgeDays: 30)
        cfg.syncCompletedTasks = false   // ← the path under test
        cfg.vaultPath = vault.path

        _ = await engine.performSync(config: cfg)

        let appendedTitles = source.appendedTasks.map(\.title)
        XCTAssertEqual(
            appendedTitles, ["open task"],
            "With syncCompletedTasks=false, completed reminders must be skipped by the existing guard — regardless of age. Only the open task should be appended."
        )
    }
}

// MARK: - Test fixtures

/// Minimal disk fixture so `performSync` clears its `FileManager.default.fileExists(atPath:)`
/// precondition on `config.vaultPath`. We never read from this directory in
/// these tests — the mock source returns its own tasks — but the engine
/// validates the path early.
private final class TempVault {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-age-filter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // performSync validates this exists before scanning the vault.
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".obsidian"),
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Minimal `TaskSource` that records every call to `appendNewTask` and returns
/// a pre-seeded list from `scanTasks`. Other methods are unused by these tests
/// and trap on call so a future expansion of the writeback path doesn't go
/// unnoticed.
private final class MockTaskSource: TaskSource {
    let sourceName = "MockTaskSource"
    private let scannedTasks: [SyncTask]
    private(set) var appendedTasks: [SyncTask] = []

    init(scannedTasks: [SyncTask] = []) {
        self.scannedTasks = scannedTasks
    }

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { scannedTasks }

    func generateTaskId(for task: SyncTask) -> String {
        // Deterministic, stable across calls — matches what real sources do.
        return "mock-\(task.title)"
    }

    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        XCTFail("markTaskComplete should not be called by the writeback path"); return 0
    }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        XCTFail("markTaskIncomplete should not be called by the writeback path")
    }
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        XCTFail("updateTaskMetadata should not be called by the writeback path")
    }

    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        appendedTasks.append(task)
        return SyncTask.ObsidianSource(
            filePath: "Inbox.md",
            lineNumber: appendedTasks.count,
            originalLine: "- [ ] \(task.title)"
        )
    }

    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

/// Minimal `TaskDestination` that returns a pre-seeded list from
/// `fetchAllTasks`. All other methods are unused by these tests.
private final class MockTaskDestination: TaskDestination {
    let destinationName = "MockTaskDestination"
    let tasks: [SyncTask]

    init(tasks: [SyncTask]) { self.tasks = tasks }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Reminders"] }

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        XCTFail("createTask should not be called by these tests"); return ""
    }
    // Legitimately called by the dedup-reconnect path in SyncEngine (Step 4)
    // when a vault task title matches a destination reminder — the engine pushes
    // the source-of-truth content back to the destination. No-op in tests.
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {}
    func moveTask(withId id: String, toList listName: String) async throws {
        XCTFail("moveTask should not be called by these tests")
    }
    func deleteTask(withId id: String) async throws {
        XCTFail("deleteTask should not be called by these tests")
    }
    func refresh() {}
}
