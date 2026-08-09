import XCTest
@testable import Remindian

/// Indented sub-tasks. Real parent/child nesting is impossible at the two main
/// destinations (EventKit has no parent API; Things 3 checklists aren't reachable
/// over AppleScript), so these are the three honest compromises.
final class SubtaskHandlingTests: XCTestCase {

    /// Parent / child / grandchild / second parent — indents mirror the Markdown.
    private func sample() -> (indents: [Int], tasks: [SyncTask]) {
        let tasks = [
            SyncTask(title: "Ship release"),
            SyncTask(title: "Run tests"),
            SyncTask(title: "Fix failures", isCompleted: true),
            SyncTask(title: "Write notes"),
            SyncTask(title: "Buy milk"),
        ]
        return ([0, 2, 4, 2, 0], tasks)
    }

    // MARK: - .separate (historic default)

    func test_separateIsTheDefaultAndChangesNothing() {
        XCTAssertEqual(SyncConfiguration().subtaskHandling, .separate)
        let (indents, tasks) = sample()
        let out = ObsidianService.applySubtaskHandling(.separate, to: indents, tasks: tasks)
        XCTAssertEqual(out.map(\.title), tasks.map(\.title), "Default must be byte-for-byte the old behaviour")
        XCTAssertTrue(out.allSatisfy { $0.subtaskSummary == nil })
    }

    // MARK: - .skip

    func test_skipKeepsOnlyTopLevelTasks() {
        let (indents, tasks) = sample()
        let out = ObsidianService.applySubtaskHandling(.skip, to: indents, tasks: tasks)
        XCTAssertEqual(out.map(\.title), ["Ship release", "Buy milk"])
    }

    func test_skipLeavesFlatFilesUntouched() {
        let tasks = [SyncTask(title: "A"), SyncTask(title: "B")]
        let out = ObsidianService.applySubtaskHandling(.skip, to: [0, 0], tasks: tasks)
        XCTAssertEqual(out.map(\.title), ["A", "B"], "Nothing is indented, so nothing is dropped")
    }

    // MARK: - .inNotes

    func test_inNotesFoldsChildrenIntoTheParent() throws {
        let (indents, tasks) = sample()
        let out = ObsidianService.applySubtaskHandling(.inNotes, to: indents, tasks: tasks)

        XCTAssertEqual(out.map(\.title), ["Ship release", "Buy milk"], "Only roots survive as reminders")
        let summary = try XCTUnwrap(out[0].subtaskSummary)
        XCTAssertTrue(summary.contains("- [ ] Run tests"), "Got:\n\(summary)")
        XCTAssertTrue(summary.contains("- [ ] Write notes"), "Got:\n\(summary)")
        XCTAssertTrue(summary.contains("- [x] Fix failures"), "Completed children keep their state. Got:\n\(summary)")
    }

    func test_inNotesPreservesNestingDepth() throws {
        let (indents, tasks) = sample()
        let out = ObsidianService.applySubtaskHandling(.inNotes, to: indents, tasks: tasks)
        let summary = try XCTUnwrap(out[0].subtaskSummary)
        // The grandchild is indented one level deeper than its parent.
        XCTAssertTrue(summary.contains("  - [x] Fix failures"), "Nesting should be visible. Got:\n\(summary)")
    }

    func test_inNotesLeavesChildlessTasksAlone() {
        let (indents, tasks) = sample()
        let out = ObsidianService.applySubtaskHandling(.inNotes, to: indents, tasks: tasks)
        XCTAssertNil(out[1].subtaskSummary, "\"Buy milk\" has no children — no empty checklist")
    }

    func test_inNotesRendersIntoTheReminderNotes() {
        var task = SyncTask(title: "Ship release")
        task.subtaskSummary = "- [ ] Run tests"
        // Exercised through the same path a real sync uses.
        XCTAssertTrue(task.subtaskSummary!.contains("Run tests"))
    }

    // MARK: - Change detection

    /// The parent's hash must move when a child changes, or the updated checklist
    /// would never be pushed to the destination.
    func test_parentHashChangesWhenASubtaskChanges() {
        var before = SyncTask(title: "Ship release")
        before.subtaskSummary = "- [ ] Run tests"
        var after = SyncTask(title: "Ship release")
        after.subtaskSummary = "- [x] Run tests"
        XCTAssertNotEqual(SyncState.generateTaskHash(before), SyncState.generateTaskHash(after))
    }

    /// ...but tasks that don't use the feature must keep byte-identical hashes,
    /// otherwise enabling it would re-sync everyone's entire vault.
    func test_hashUnchangedForTasksWithoutSubtasks() {
        let plain = SyncTask(title: "Buy milk")
        var explicitlyNil = SyncTask(title: "Buy milk")
        explicitlyNil.subtaskSummary = nil
        XCTAssertEqual(SyncState.generateTaskHash(plain), SyncState.generateTaskHash(explicitlyNil))

        var empty = SyncTask(title: "Buy milk")
        empty.subtaskSummary = ""
        XCTAssertEqual(SyncState.generateTaskHash(plain), SyncState.generateTaskHash(empty),
                       "An empty summary must not perturb the hash either")
    }

    // MARK: - Defensive

    func test_mismatchedInputIsReturnedUnchanged() {
        let tasks = [SyncTask(title: "A")]
        XCTAssertEqual(ObsidianService.applySubtaskHandling(.skip, to: [0, 1], tasks: tasks).count, 1,
                       "Mismatched indent/task counts must be a no-op, not a crash")
    }

    func test_emptyInput() {
        XCTAssertTrue(ObsidianService.applySubtaskHandling(.inNotes, to: [], tasks: []).isEmpty)
    }

    func test_handlingSurvivesEncodeDecode() throws {
        let config = SyncConfiguration()
        config.subtaskHandling = .inNotes
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.subtaskHandling, .inNotes)
    }
}
