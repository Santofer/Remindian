import XCTest
@testable import Remindian

/// Regression tests for the content-relocation fix (v5.21.2).
///
/// The bug: the menu-bar Today list (and the sync writeback queue) hold each
/// task's `lineNumber` + `originalLine` captured at scan time. By the time the
/// user checks a task off, a prior sync, an iCloud re-sync, or an edit in
/// Obsidian itself may have shifted lines — so the stored index points at a
/// *different* task. The old code trusted the index, compared content, and threw
/// `lineContentMismatch` ("File has changed since last scan. Expected line
/// content doesn't match current content…"), which surfaced as scary errors when
/// completing tasks from the menu.
///
/// The fix relocates the task by its content (`SyncTask.taskIdentityBody`) and
/// only ever edits a line whose identity matches what we intend to change. These
/// tests lock in that behavior, including the exact screenshot scenario: a task
/// that the *sync* already completed a moment ago must be a no-op when the user
/// then taps it in the (stale) menu — not an error.
final class LineRelocationRegressionTests: XCTestCase {

    private var vaultURL: URL!
    private var service: ObsidianService!

    override func setUp() {
        super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-reloc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        service = ObsidianService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vaultURL)
        super.tearDown()
    }

    private func write(_ name: String, _ content: String) throws -> String {
        try content.write(to: vaultURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "/\(name)"
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: vaultURL.appendingPathComponent(name), encoding: .utf8)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - taskIdentityBody

    func test_identityBody_stripsCheckboxAndCompletionDate() {
        // Open and completed forms of the same task collapse to one identity.
        let open = "- [ ] Remplir la déclaration CNSS #netspace ⬆ 🔁 every month 📅 2026-06-14"
        let done = "- [x] Remplir la déclaration CNSS #netspace ⬆ 🔁 every month 📅 2026-06-14 ✅ 2026-06-14"
        XCTAssertEqual(SyncTask.taskIdentityBody(of: open), SyncTask.taskIdentityBody(of: done))
        XCTAssertFalse(SyncTask.taskIdentityBody(of: open).isEmpty)
    }

    func test_identityBody_indentationAndMarkerVariants() {
        let a = "    - [ ] Task 📅 2026-01-01"
        let b = "- [/] Task 📅 2026-01-01"   // in-progress marker
        let c = "- [X] Task 📅 2026-01-01 ✅ 2026-02-02"
        XCTAssertEqual(SyncTask.taskIdentityBody(of: a), SyncTask.taskIdentityBody(of: b))
        XCTAssertEqual(SyncTask.taskIdentityBody(of: a), SyncTask.taskIdentityBody(of: c))
    }

    func test_identityBody_nonTaskLineIsEmpty() {
        XCTAssertEqual(SyncTask.taskIdentityBody(of: "## A heading"), "")
        XCTAssertEqual(SyncTask.taskIdentityBody(of: "- [[A wikilink]]"), "")
        XCTAssertEqual(SyncTask.taskIdentityBody(of: "plain text"), "")
    }

    func test_identityBody_distinguishesDifferentDueDates() {
        // A recurring task's next occurrence carries an advanced 📅 date, so it
        // must NOT share identity with the just-completed instance.
        let completed = "- [x] Pay #bills 🔁 every week 📅 2026-06-14 ✅ 2026-06-14"
        let nextOccurrence = "- [ ] Pay #bills 🔁 every week 📅 2026-06-21"
        XCTAssertNotEqual(SyncTask.taskIdentityBody(of: completed),
                          SyncTask.taskIdentityBody(of: nextOccurrence))
    }

    // MARK: - The screenshot scenario

    func test_completingTaskAlreadyCompletedBySync_isNoOpSuccess() throws {
        // The sync just wrote `[x]` back for this task (completed in Reminders on
        // the phone). The menu still shows it (stale snapshot). Tapping it must be
        // a silent no-op, NOT "File has changed since last scan".
        let path = try write("CNSS.md",
            "- [x] Remplir la déclaration CNSS #netspace ⬆ ✅ 2026-06-14\n- [ ] Autre tâche")

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Remplir la déclaration CNSS #netspace ⬆", // open form from the stale menu
            completionDate: date(2026, 6, 14),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(inserted, 0, "Already done — nothing inserted, no throw")
        XCTAssertEqual(try read("CNSS.md"),
            "- [x] Remplir la déclaration CNSS #netspace ⬆ ✅ 2026-06-14\n- [ ] Autre tâche",
            "File untouched — the task was already completed.")
    }

    func test_twoTasksInSameFile_completingBothFromStaleSnapshot() throws {
        // Both tasks were scanned at once, so both hold line indexes from BEFORE
        // either was completed. Completing the first rewrites its line; completing
        // the second must still succeed even though every index is now stale.
        let path = try write("inbox.md",
            "- [ ] Faire le virement à Nabil #netspace\n- [ ] Remplir la déclaration CNSS #netspace")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Faire le virement à Nabil #netspace",
            completionDate: date(2026, 6, 14),
            vaultPath: vaultURL.path
        )
        // Second task — index 2 is still valid here, but its content check would
        // have failed under the old code if line 1 had grown/shrunk. Relocation
        // makes it robust regardless.
        XCTAssertNoThrow(try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Remplir la déclaration CNSS #netspace",
            completionDate: date(2026, 6, 14),
            vaultPath: vaultURL.path
        ))
        let content = try read("inbox.md")
        XCTAssertTrue(content.contains("- [x] Faire le virement à Nabil"))
        XCTAssertTrue(content.contains("- [x] Remplir la déclaration CNSS"))
    }

    func test_recurrenceInsertionShiftsLater_taskStillRelocates() throws {
        // Completing a recurring task inserts a new occurrence line above and marks
        // the old one done — shifting every later task down by one. A later task's
        // recorded index is now off-by-one and lands on the wrong line. It must
        // relocate to its real line, not error. This is the user's exact scenario.
        let path = try write("day.md",
            "- [ ] Weekly review 🔁 every week 📅 2026-06-14\n- [ ] Remplir la déclaration CNSS #netspace")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Weekly review 🔁 every week 📅 2026-06-14",
            completionDate: date(2026, 6, 14),
            vaultPath: vaultURL.path
        )
        // "CNSS" was at line 2; it is now at line 3 (recurrence inserted a line).
        // The stale snapshot still says line 2 → relocation saves it.
        XCTAssertNoThrow(try service.markTaskComplete(
            filePath: path, lineNumber: 2, // stale — points at the completed "Weekly review"
            originalLine: "- [ ] Remplir la déclaration CNSS #netspace",
            completionDate: date(2026, 6, 14),
            vaultPath: vaultURL.path
        ))
        XCTAssertTrue(try read("day.md").contains("- [x] Remplir la déclaration CNSS"),
                      "CNSS relocated and completed")
    }
}
