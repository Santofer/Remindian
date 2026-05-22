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
/// **The fix.** Extract the inline source-side filter into
/// `SyncEngine.isCompletedTaskTooOld(_:config:)` and reuse it in the writeback
/// loop. These tests guard each of the cases the helper must get right.
final class AgeFilterWritebackRegressionTests: XCTestCase {

    private func config(maxAgeDays: Int) -> SyncConfiguration {
        var c = SyncConfiguration()
        c.maxCompletedTaskAgeDays = maxAgeDays
        c.syncCompletedTasks = true
        c.enableNewTaskWriteback = true
        return c
    }

    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date())!
    }

    // MARK: - Old completed reminders are filtered

    /// A reminder completed 31 days ago, when `maxCompletedTaskAgeDays = 30`,
    /// must be filtered. Without this check the writeback loop would call
    /// `appendNewTask` for it.
    func testOldCompletedReminderIsFilteredByHelper() {
        let task = SyncTask(
            title: "Old completed reminder",
            isCompleted: true,
            completedDate: daysAgo(31)
        )
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 30)),
            "Reminder completed 31 days ago must be filtered when maxCompletedTaskAgeDays=30. Without this, old completed reminders bypass the cutoff via the writeback path. (regression: #11 part 2)"
        )
    }

    /// Fallback path: when a completed task has no `completedDate`, the helper
    /// uses `lastModified` instead. Mirrors the source-scan behavior.
    func testCompletedReminderWithoutCompletedDateFallsBackToLastModified() {
        var task = SyncTask(
            title: "Completed but no completedDate",
            isCompleted: true,
            completedDate: nil
        )
        task.lastModified = daysAgo(60)
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 30)),
            "When completedDate is nil, lastModified must be consulted. The source-scan filter does this; writeback must match."
        )
    }

    // MARK: - Recent completed reminders are kept (negative case)

    /// A reminder completed 5 days ago must NOT be filtered when the cutoff is
    /// 30 days. Catches over-filtering — i.e. the helper accidentally returning
    /// true for in-window tasks.
    func testRecentCompletedReminderIsNotFiltered() {
        let task = SyncTask(
            title: "Recently completed reminder",
            isCompleted: true,
            completedDate: daysAgo(5)
        )
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 30)),
            "Reminder completed within the 30-day window must NOT be filtered — that would over-correct and hide legitimate recent work."
        )
    }

    // MARK: - Uncompleted reminders are always kept

    /// An uncompleted reminder must never be filtered by this helper, regardless
    /// of how stale `lastModified` is. The age cutoff is about completion age
    /// only; an open task is still actionable.
    func testUncompletedReminderIsNeverFilteredEvenIfStale() {
        var task = SyncTask(
            title: "Old open reminder",
            isCompleted: false,
            completedDate: nil
        )
        task.lastModified = daysAgo(365)
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 30)),
            "Uncompleted tasks must never be age-filtered. Open work doesn't expire."
        )
    }

    // MARK: - Disabled setting

    /// `maxCompletedTaskAgeDays = 0` (the disabled sentinel) must short-circuit
    /// to false. This preserves opt-in behavior — users who explicitly turn the
    /// setting off get the old "sync everything" behavior, including via
    /// writeback.
    func testDisabledSettingNeverFilters() {
        let task = SyncTask(
            title: "Ancient completed reminder",
            isCompleted: true,
            completedDate: daysAgo(3650)
        )
        XCTAssertFalse(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 0)),
            "When maxCompletedTaskAgeDays is 0 (disabled), the helper must return false for everything — otherwise toggling the setting off would silently break sync."
        )
    }

    /// Boundary case: a task completed exactly `maxCompletedTaskAgeDays` ago
    /// is inside the window. We use `<=` against the cutoff date, which is
    /// `now - N days`, so a `completedDate` of exactly that point is treated as
    /// too old (matches the source-scan semantics: source uses `>` to KEEP, so
    /// equal-to-cutoff is dropped on source too — the helper must match).
    func testBoundaryCaseMatchesSourceScanSemantics() {
        // Reminder completed exactly at the cutoff instant. Source scan uses
        // `completedDate > cutoffDate` to keep, so equal-to-cutoff is filtered.
        // Helper must agree.
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var task = SyncTask(
            title: "Edge case",
            isCompleted: true,
            completedDate: cutoff
        )
        task.lastModified = cutoff
        XCTAssertTrue(
            SyncEngine.isCompletedTaskTooOld(task, config: config(maxAgeDays: 30)),
            "Boundary semantics must match source-scan filter. Source uses `> cutoff` to keep, so equal-to-cutoff is dropped; helper does the same with `<= cutoff`."
        )
    }
}
