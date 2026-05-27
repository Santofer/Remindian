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
}
