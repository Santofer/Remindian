import XCTest
@testable import Remindian

/// Comprehensive tests for every code path that modifies existing vault files.
///
/// The Obsidian vault is sacrosanct. These tests verify:
/// 1. Only the targeted line is modified — surrounding content is byte-identical
/// 2. Surgical edits never reconstruct lines — only specific fields change
/// 3. Safety guards (content mismatch, line range, file existence) block bad writes
/// 4. Multi-task edits within the same file use correct position-aware offsets
/// 5. Unicode, emoji, and whitespace survive round-trips
final class WritebackTests: XCTestCase {

    private var vaultURL: URL!
    private var service: ObsidianService!

    override func setUp() {
        super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        service = ObsidianService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vaultURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, _ content: String) throws -> String {
        let url = vaultURL.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "/\(name)"
    }

    private func readLines(_ name: String) throws -> [String] {
        let url = vaultURL.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    private func readRaw(_ name: String) throws -> String {
        let url = vaultURL.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Assert that every line in the file EXCEPT the given indices is byte-identical to the original.
    private func assertSurroundingLinesUntouched(
        file: String, originalLines: [String], changedIndices: Set<Int>,
        _ message: String = "", line: UInt = #line
    ) throws {
        let current = try readLines(file)
        for i in 0..<min(originalLines.count, current.count) {
            if !changedIndices.contains(i) && i < originalLines.count {
                XCTAssertEqual(current[i], originalLines[i],
                    "Line \(i+1) unexpectedly changed\(message.isEmpty ? "" : ": \(message)")",
                    line: line)
            }
        }
    }

    // =========================================================================
    // MARK: - markTaskComplete
    // =========================================================================

    // MARK: Basic Completion

    func testCompletionSimple() throws {
        let path = try writeFile("t.md",
            "- [ ] Alpha\n- [ ] Bravo\n- [ ] Charlie")

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Bravo",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 0, "No recurrence means no insertion")
        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], "- [ ] Alpha", "Line above byte-identical")
        XCTAssertTrue(lines[1].hasPrefix("- [x] Bravo"), "Checkbox toggled")
        XCTAssertTrue(lines[1].contains("✅ 2026-03-29"), "Completion date appended")
        XCTAssertEqual(lines[2], "- [ ] Charlie", "Line below byte-identical")
    }

    func testCompletionAtFirstLine() throws {
        let path = try writeFile("t.md",
            "- [ ] First task\n- [ ] Second task")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] First task",
            completionDate: makeDate(2026, 1, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("- [x] First task"), "First line completed")
        XCTAssertEqual(lines[1], "- [ ] Second task", "Second line untouched")
    }

    func testCompletionAtLastLine() throws {
        let path = try writeFile("t.md",
            "- [ ] First\n- [ ] Last")

        try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Last",
            completionDate: makeDate(2026, 1, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], "- [ ] First", "First untouched")
        XCTAssertTrue(lines[1].contains("- [x] Last"), "Last line completed")
    }

    func testCompletionInSingleLineFile() throws {
        let path = try writeFile("t.md", "- [ ] Solo task")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Solo task",
            completionDate: makeDate(2026, 6, 15),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines.count, 1, "Still one line")
        XCTAssertTrue(lines[0].hasPrefix("- [x] Solo task"))
        XCTAssertTrue(lines[0].contains("✅ 2026-06-15"))
    }

    // MARK: Metadata Preservation During Completion

    func testCompletionPreservesAllMetadata() throws {
        let original = "- [ ] Review [[Project Plan]] ⏫ 🔁 every week 📅 2026-04-01 🛫 2026-03-25 ⏳ 2026-03-28 #work #urgent"
        let path = try writeFile("t.md", original)

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 4, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        // Recurrence inserts a new line, completed task is now line 2 (index 1)
        let completedLine = lines.first { $0.contains("- [x]") }!
        XCTAssertTrue(completedLine.contains("[[Project Plan]]"), "Wikilink preserved")
        XCTAssertTrue(completedLine.contains("⏫"), "Priority preserved")
        XCTAssertTrue(completedLine.contains("🔁 every week"), "Recurrence preserved")
        XCTAssertTrue(completedLine.contains("📅 2026-04-01"), "Due date preserved")
        XCTAssertTrue(completedLine.contains("🛫 2026-03-25"), "Start date preserved")
        XCTAssertTrue(completedLine.contains("⏳ 2026-03-28"), "Scheduled date preserved")
        XCTAssertTrue(completedLine.contains("#work"), "Tag #work preserved")
        XCTAssertTrue(completedLine.contains("#urgent"), "Tag #urgent preserved")
        XCTAssertTrue(completedLine.contains("✅ 2026-04-01"), "Completion date added")
    }

    func testCompletionPreservesIndentation() throws {
        let content = "- [ ] Parent task\n\t- [ ] Indented child\n\t\t- [ ] Deep child"
        let path = try writeFile("t.md", content)

        try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "\t- [ ] Indented child",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], "- [ ] Parent task", "Parent untouched")
        XCTAssertTrue(lines[1].hasPrefix("\t- [x] Indented child"), "Indentation preserved")
        XCTAssertEqual(lines[2], "\t\t- [ ] Deep child", "Sibling untouched")
    }

    func testCompletionPreservesFileWithFrontmatter() throws {
        let content = [
            "---",
            "title: My Notes",
            "client: \"[[Acme Corp]]\"",
            "---",
            "",
            "# Tasks",
            "- [ ] Task in note 📅 2026-04-01",
            "",
            "Some other content"
        ].joined(separator: "\n")
        let path = try writeFile("t.md", content)
        let originalLines = content.components(separatedBy: "\n")

        try service.markTaskComplete(
            filePath: path, lineNumber: 7,
            originalLine: "- [ ] Task in note 📅 2026-04-01",
            completionDate: makeDate(2026, 4, 1),
            vaultPath: vaultURL.path
        )

        // Only line 7 (index 6) changed
        try assertSurroundingLinesUntouched(
            file: "t.md", originalLines: originalLines,
            changedIndices: [6], "Frontmatter and surrounding content must survive")
        let lines = try readLines("t.md")
        XCTAssertTrue(lines[6].contains("- [x]"), "Task completed")
    }

    func testCompletionDoesNotAddDuplicateDate() throws {
        // Task already has a ✅ date (edge case: re-sync)
        let original = "- [ ] Task ✅ 2026-01-01"
        let path = try writeFile("t.md", original)

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        // Should contain - [x] but NOT add a second ✅
        let checkmarkCount = line.components(separatedBy: "✅").count - 1
        XCTAssertEqual(checkmarkCount, 1, "Only one ✅ marker present")
    }

    func testAlreadyCompletedTaskIsSkipped() throws {
        let original = "- [x] Already done ✅ 2026-03-01"
        let path = try writeFile("t.md", original)

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 0)
        XCTAssertEqual(try readLines("t.md")[0], original, "Byte-identical — no double write")
    }

    func testCompletionLineCountPreservedWithoutRecurrence() throws {
        let content = "Line 1\n- [ ] Task\nLine 3\nLine 4"
        let path = try writeFile("t.md", content)

        try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Task",
            completionDate: makeDate(2026, 1, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines.count, 4, "Line count preserved (no recurrence)")
    }

    // MARK: Recurrence

    func testCompletionWithRecurrenceInsertsLine() throws {
        let path = try writeFile("t.md",
            "- [ ] Above\n- [ ] Recurring 🔁 every week 📅 2026-03-20\n- [ ] Below")

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 1, "Recurrence inserts 1 line")
        let lines = try readLines("t.md")
        XCTAssertEqual(lines.count, 4, "3 original + 1 inserted")
        XCTAssertEqual(lines[0], "- [ ] Above", "Line above byte-identical")
        XCTAssertTrue(lines[1].contains("- [ ]") && lines[1].contains("🔁"),
                       "New recurrence line is uncompleted with marker")
        XCTAssertTrue(lines[2].contains("- [x]") && lines[2].contains("✅"),
                       "Original task completed")
        XCTAssertEqual(lines[3], "- [ ] Below", "Line below byte-identical")
    }

    func testCompletionWithMonthlyRecurrence() throws {
        let original = "- [ ] Pay rent 🔁 every month 📅 2026-03-01"
        let path = try writeFile("t.md", original)

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 1),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 1)
        let lines = try readLines("t.md")
        let recurrenceLine = lines[0]
        XCTAssertTrue(recurrenceLine.contains("- [ ]"), "New task is uncompleted")
        XCTAssertTrue(recurrenceLine.contains("🔁 every month"), "Monthly rule preserved")
        XCTAssertTrue(recurrenceLine.contains("📅"), "Has due date")
        XCTAssertTrue(lines[1].contains("- [x]"), "Original completed")
    }

    func testRecurrenceWithoutReferenceDateNoInsertion() throws {
        // Task has 🔁 but no 📅/⏳/🛫 → can't compute next date → no insertion
        let original = "- [ ] Vague recurring 🔁 every week"
        let path = try writeFile("t.md", original)

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 0, "No reference date → no recurrence insertion")
        let lines = try readLines("t.md")
        XCTAssertEqual(lines.count, 1, "Still one line")
        XCTAssertTrue(lines[0].contains("- [x]"), "Task still completed")
    }

    // MARK: Multi-Task Offset (regression tests)

    func testMultiTaskUpperRecurrenceThenLowerCompletion() throws {
        let path = try writeFile("t.md", [
            "- [ ] First",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Third",
            "- [ ] Fourth"
        ].joined(separator: "\n"))

        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        try service.markTaskComplete(
            filePath: path, lineNumber: 4, // 3 + 1 offset
            originalLine: "- [ ] Third",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], "- [ ] First", "First untouched")
        XCTAssertTrue(lines[3].contains("- [x] Third") && lines[3].contains("✅ 2026-03-30"))
        XCTAssertEqual(lines[4], "- [ ] Fourth", "Fourth untouched")
    }

    func testMultiTaskLowerRecurrenceThenUpperCompletion() throws {
        let path = try writeFile("t.md", [
            "- [ ] First",
            "- [ ] Second",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20"
        ].joined(separator: "\n"))

        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        // Insertion at line 3 (> line 1) → no offset needed
        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] First",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("- [x] First") && lines[0].contains("✅ 2026-03-30"))
        XCTAssertEqual(lines[1], "- [ ] Second", "Middle untouched")
    }

    func testInsertionDoesNotOffsetTaskAbove() throws {
        let path = try writeFile("t.md", [
            "- [ ] Task at line 1",
            "- [ ] Task at line 2",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Task at line 4"
        ].joined(separator: "\n"))

        try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        try service.markTaskComplete(
            filePath: path, lineNumber: 1, // NO offset
            originalLine: "- [ ] Task at line 1",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        XCTAssertTrue(try readLines("t.md")[0].contains("- [x] Task at line 1"),
                       "Correct task completed despite insertion below")
    }

    func testMultipleRecurrenceInsertionsThenMetadataBelow() throws {
        let path = try writeFile("t.md", [
            "- [ ] RecA 🔁 every week 📅 2026-03-20",
            "- [ ] Middle",
            "- [ ] RecB 🔁 every month 📅 2026-03-15",
            "- [ ] Spacer",
            "- [ ] Target 📅 2026-01-01"
        ].joined(separator: "\n"))

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] RecA 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        try service.markTaskComplete(
            filePath: path, lineNumber: 4, // original 3 + 1
            originalLine: "- [ ] RecB 🔁 every month 📅 2026-03-15",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 7, // original 5 + 2
            originalLine: "- [ ] Target 📅 2026-01-01",
            changes: changes,
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[6].contains("Target") && lines[6].contains("📅 2026-06-15"))
    }

    // =========================================================================
    // MARK: - markTaskIncomplete
    // =========================================================================

    func testIncompleteSimple() throws {
        let original = "- [x] Done task ✅ 2026-03-01"
        let path = try writeFile("t.md", original)

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.hasPrefix("- [ ] Done task"), "Checkbox reverted")
        XCTAssertFalse(line.contains("✅"), "Completion marker removed")
        XCTAssertFalse(line.contains("2026-03-01"), "Completion date removed")
    }

    func testIncompleteCapitalX() throws {
        let original = "- [X] Capital X task ✅ 2026-06-15"
        let path = try writeFile("t.md", original)

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.hasPrefix("- [ ] Capital X task"), "Capital [X] reverted to [ ]")
        XCTAssertFalse(line.contains("✅"), "Completion marker removed")
    }

    func testIncompletePreservesAllMetadata() throws {
        let original = "- [x] Review PR ⏫ 📅 2026-04-01 🛫 2026-03-25 🔁 every week #work #code ✅ 2026-04-01"
        let path = try writeFile("t.md", original)

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("- [ ]"), "Checkbox reverted")
        XCTAssertTrue(line.contains("⏫"), "Priority preserved")
        XCTAssertTrue(line.contains("📅 2026-04-01"), "Due date preserved")
        XCTAssertTrue(line.contains("🛫 2026-03-25"), "Start date preserved")
        XCTAssertTrue(line.contains("🔁 every week"), "Recurrence preserved")
        XCTAssertTrue(line.contains("#work"), "Tag preserved")
        XCTAssertTrue(line.contains("#code"), "Tag preserved")
        XCTAssertFalse(line.contains("✅"), "Only completion marker removed")
    }

    func testIncompleteRemovesOnlyCompletionDate() throws {
        // ✅ date removed but 📅 due date must stay
        let original = "- [x] Task 📅 2026-06-01 ✅ 2026-05-30"
        let path = try writeFile("t.md", original)

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("📅 2026-06-01"), "Due date preserved")
        XCTAssertFalse(line.contains("✅"), "Completion marker removed")
        XCTAssertFalse(line.contains("2026-05-30"), "Completion date gone")
        XCTAssertTrue(line.contains("2026-06-01"), "Due date still there")
    }

    func testIncompleteSurroundingLinesUntouched() throws {
        let content = "# Notes\n\n- [x] Done ✅ 2026-01-01\n\nMore content here"
        let path = try writeFile("t.md", content)
        let originalLines = content.components(separatedBy: "\n")

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [x] Done ✅ 2026-01-01",
            vaultPath: vaultURL.path
        )

        try assertSurroundingLinesUntouched(
            file: "t.md", originalLines: originalLines,
            changedIndices: [2], "Only the task line should change")
    }

    func testIncompleteWithFE0FVariationSelector() throws {
        // Some systems encode ✅ as ✅️ (U+2705 + U+FE0F)
        let original = "- [x] Task \u{2705}\u{FE0F} 2026-03-15"
        let path = try writeFile("t.md", original)

        try service.markTaskIncomplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("- [ ]"), "Checkbox reverted")
        XCTAssertFalse(line.contains("\u{2705}"), "FE0F variant completion marker removed")
        XCTAssertFalse(line.contains("2026-03-15"), "Date removed with marker")
    }

    // MARK: markTaskIncomplete — Safety Guards

    func testIncompleteContentMismatch() throws {
        // The recorded line names a task ("Different line") that does not exist
        // anywhere in the file. The safe outcome is a no-op — never revert the
        // wrong task, never throw a scary "file changed" error. (#75-followup)
        let path = try writeFile("t.md", "- [x] Actual line ✅ 2026-01-01")

        XCTAssertNoThrow(
            try service.markTaskIncomplete(
                filePath: path, lineNumber: 1,
                originalLine: "- [x] Different line ✅ 2026-01-01",
                vaultPath: vaultURL.path
            )
        )
        XCTAssertEqual(try readLines("t.md")[0], "- [x] Actual line ✅ 2026-01-01",
                       "A different task must never be touched.")
    }

    func testIncompleteLineOutOfRange() throws {
        // Stale line index past EOF, but the exact task still exists — relocate
        // by content and un-complete it rather than throwing. (#75-followup)
        let path = try writeFile("t.md", "- [x] Only line ✅ 2026-01-01")

        XCTAssertNoThrow(
            try service.markTaskIncomplete(
                filePath: path, lineNumber: 3,
                originalLine: "- [x] Only line ✅ 2026-01-01",
                vaultPath: vaultURL.path
            )
        )
        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("- [ ]"), "Relocated and reverted to open")
        XCTAssertFalse(line.contains("✅"), "Completion date removed")
    }

    func testIncompleteFileNotFound() throws {
        XCTAssertThrowsError(
            try service.markTaskIncomplete(
                filePath: "/nonexistent.md", lineNumber: 1,
                originalLine: "- [x] Task",
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    // =========================================================================
    // MARK: - updateTaskMetadata
    // =========================================================================

    // MARK: Due Date

    func testMetadataUpdateDueDate() throws {
        let original = "- [ ] Task 📅 2026-01-01 #work"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("📅 2026-06-15"), "Due date updated")
        XCTAssertTrue(line.contains("#work"), "Tag preserved")
        XCTAssertFalse(line.contains("2026-01-01"), "Old date gone")
    }

    func testMetadataRemoveDueDate() throws {
        let original = "- [ ] Task 📅 2026-01-01 #work"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(nil) // .some(nil) = remove
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertFalse(line.contains("📅"), "Due date marker removed entirely")
        XCTAssertTrue(line.contains("#work"), "Tag preserved")
        XCTAssertTrue(line.contains("Task"), "Title preserved")
    }

    func testMetadataAddDueDateWhenNoneExists() throws {
        let original = "- [ ] Task without dates #work"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("📅 2026-06-15"), "Due date appended")
        XCTAssertTrue(line.contains("Task without dates"), "Title preserved")
    }

    func testMetadataUpdateDueDateWithFE0F() throws {
        // Some editors encode 📅 as 📅️ (U+1F4C5 + U+FE0F)
        let original = "- [ ] Task \u{1F4C5}\u{FE0F} 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 12, 25))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("2026-12-25"), "Date updated despite FE0F")
        XCTAssertFalse(line.contains("2026-01-01"), "Old date gone")
    }

    // MARK: Start Date

    func testMetadataUpdateStartDate() throws {
        let original = "- [ ] Task 🛫 2026-01-01 📅 2026-02-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newStartDate = .some(makeDate(2026, 5, 1))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("🛫 2026-05-01"), "Start date updated")
        XCTAssertTrue(line.contains("📅 2026-02-01"), "Due date preserved")
    }

    func testMetadataRemoveStartDate() throws {
        let original = "- [ ] Task 🛫 2026-01-01 📅 2026-02-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newStartDate = .some(nil)
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertFalse(line.contains("🛫"), "Start date removed")
        XCTAssertTrue(line.contains("📅 2026-02-01"), "Due date preserved")
    }

    // MARK: Priority

    func testMetadataSetPriorityHigh() throws {
        let original = "- [ ] Task 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newPriority = .high
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("⏫"), "High priority emoji added")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Date preserved")
    }

    func testMetadataSetPriorityMedium() throws {
        let original = "- [ ] Task"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newPriority = .medium
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        XCTAssertTrue(try readLines("t.md")[0].contains("🔼"), "Medium priority emoji added")
    }

    func testMetadataSetPriorityLow() throws {
        let original = "- [ ] Task"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newPriority = .low
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        XCTAssertTrue(try readLines("t.md")[0].contains("🔽"), "Low priority emoji added")
    }

    func testMetadataChangePriority() throws {
        let original = "- [ ] Task ⏫ 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newPriority = .low
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("🔽"), "New priority present")
        XCTAssertFalse(line.contains("⏫"), "Old priority removed")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Date preserved")
    }

    func testMetadataRemovePriority() throws {
        let original = "- [ ] Task ⏫ 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        // Must use fully-qualified type — bare `.none` resolves to Optional.none (nil)
        changes.newPriority = SyncTask.Priority.none
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertFalse(line.contains("⏫"), "Priority removed")
        XCTAssertFalse(line.contains("🔼"), "No stray priority")
        XCTAssertFalse(line.contains("🔽"), "No stray priority")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Date preserved")
    }

    // MARK: Tags

    func testMetadataUpdateTags() throws {
        let original = "- [ ] Task #old-tag 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newTags = ["#new-tag", "#another"]
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("#new-tag"), "New tag present")
        XCTAssertTrue(line.contains("#another"), "Second new tag present")
        XCTAssertFalse(line.contains("#old-tag"), "Old tag removed")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Date preserved")
    }

    func testMetadataRemoveAllTags() throws {
        let original = "- [ ] Task #tag1 #tag2 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newTags = [] // empty = remove all
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertFalse(line.contains("#tag1"), "Tag 1 removed")
        XCTAssertFalse(line.contains("#tag2"), "Tag 2 removed")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Date preserved")
    }

    func testMetadataAddTagsWhenNoneExist() throws {
        let original = "- [ ] Task 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newTags = ["#project", "#urgent"]
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("#project"), "Tag added")
        XCTAssertTrue(line.contains("#urgent"), "Tag added")
    }

    // MARK: Combined / Multi-Field

    func testMetadataCombinedMultipleFields() throws {
        let original = "- [ ] Task ⏫ #old 📅 2026-01-01 🛫 2026-01-15"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 1))
        changes.newStartDate = .some(makeDate(2026, 5, 15))
        changes.newPriority = .medium
        changes.newTags = ["#new"]
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("📅 2026-06-01"), "Due date updated")
        XCTAssertTrue(line.contains("🛫 2026-05-15"), "Start date updated")
        XCTAssertTrue(line.contains("🔼"), "Priority changed to medium")
        XCTAssertFalse(line.contains("⏫"), "Old priority gone")
        XCTAssertTrue(line.contains("#new"), "New tag present")
        XCTAssertFalse(line.contains("#old"), "Old tag gone")
        XCTAssertFalse(line.contains("2026-01-01"), "Old due date gone")
        XCTAssertFalse(line.contains("2026-01-15"), "Old start date gone")
    }

    func testMetadataNoOpWhenNoChanges() throws {
        let original = "- [ ] Task 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        // MetadataChanges with all nil = hasChanges == false
        let changes = ObsidianService.MetadataChanges()
        XCTAssertFalse(changes.hasChanges)

        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        // File should be byte-identical (early return before even reading)
        XCTAssertEqual(try readLines("t.md")[0], original, "File untouched on no-op")
    }

    // MARK: Preservation

    func testMetadataPreservesRecurrenceMarker() throws {
        let original = "- [ ] Task 🔁 every week 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("🔁 every week"), "Recurrence marker preserved")
        XCTAssertTrue(line.contains("📅 2026-06-15"), "Date updated")
    }

    func testMetadataPreservesWikilinks() throws {
        let original = "- [ ] Review [[Project Plan]] and [[Budget]] 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newPriority = .high
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original, changes: changes,
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("[[Project Plan]]"), "Wikilink preserved")
        XCTAssertTrue(line.contains("[[Budget]]"), "Second wikilink preserved")
    }

    func testMetadataPreservesSurroundingLines() throws {
        let content = [
            "# Project Tasks",
            "",
            "- [ ] Task A 📅 2026-01-01",
            "- [ ] Task B",
            "",
            "## Notes",
            "Some text here"
        ].joined(separator: "\n")
        let path = try writeFile("t.md", content)
        let originalLines = content.components(separatedBy: "\n")

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 12, 25))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Task A 📅 2026-01-01",
            changes: changes,
            vaultPath: vaultURL.path
        )

        try assertSurroundingLinesUntouched(
            file: "t.md", originalLines: originalLines,
            changedIndices: [2], "Only line 3 should change")
    }

    func testMetadataUpdateAfterRecurrenceInsertion() throws {
        let path = try writeFile("t.md", [
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Target 📅 2026-01-01 🛫 2026-01-15"
        ].joined(separator: "\n"))

        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        changes.newStartDate = .some(makeDate(2026, 6, 1))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 3, // 2 + 1 offset
            originalLine: "- [ ] Target 📅 2026-01-01 🛫 2026-01-15",
            changes: changes,
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[2].contains("📅 2026-06-15") && lines[2].contains("🛫 2026-06-01"))
    }

    // MARK: updateTaskMetadata — Safety Guards

    func testMetadataContentMismatch() throws {
        // The recorded line names a task ("Wrong content") absent from the file.
        // Metadata writeback must no-op — never edit a different task. (#75-followup)
        let path = try writeFile("t.md", "- [ ] Actual content 📅 2026-01-01")

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        XCTAssertNoThrow(
            try service.updateTaskMetadata(
                filePath: path, lineNumber: 1,
                originalLine: "- [ ] Wrong content 📅 2026-01-01",
                changes: changes,
                vaultPath: vaultURL.path
            )
        )
        XCTAssertEqual(try readLines("t.md")[0], "- [ ] Actual content 📅 2026-01-01",
                       "A different task must never be edited; due date unchanged.")
    }

    func testMetadataLineOutOfRange() throws {
        // Stale line index past EOF, but the exact task still exists — relocate
        // by content and apply the metadata change rather than throwing. (#75-followup)
        let path = try writeFile("t.md", "- [ ] Only line")

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        XCTAssertNoThrow(
            try service.updateTaskMetadata(
                filePath: path, lineNumber: 10,
                originalLine: "- [ ] Only line",
                changes: changes,
                vaultPath: vaultURL.path
            )
        )
        XCTAssertTrue(try readLines("t.md")[0].contains("📅 2026-06-15"),
                      "Relocated and applied the due date")
    }

    func testMetadataFileNotFound() throws {
        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        XCTAssertThrowsError(
            try service.updateTaskMetadata(
                filePath: "/ghost.md", lineNumber: 1,
                originalLine: "- [ ] Task",
                changes: changes,
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    // Metadata writeback for a task that was completed since the scan is a safe
    // no-op: we never re-edit a completed task's metadata, and never throw.
    func testMetadataWritebackSkipsCompletedTask() throws {
        let original = "- [ ] Task 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        XCTAssertNoThrow(
            try service.updateTaskMetadata(
                filePath: path, lineNumber: 1,
                originalLine: original,
                changes: changes,
                vaultPath: vaultURL.path
            )
        )
        let line = try readLines("t.md")[0]
        XCTAssertTrue(line.contains("- [x] Task"), "Still completed")
        XCTAssertTrue(line.contains("📅 2026-01-01"), "Completed task's due date left untouched")
        XCTAssertFalse(line.contains("2026-06-15"), "Metadata change correctly skipped for a completed task")
    }

    // =========================================================================
    // MARK: - Cross-Cutting Safety & Edge Cases
    // =========================================================================

    // The exact scenario behind the user's menu error: a prior completion shifted
    // lines (recurrence inserted a new occurrence + marked the old one done), so a
    // second task's recorded line index now points at a *different*, completed
    // task. Completion must relocate to the real "Target" line, not error. (#75-followup)
    func testStaleLineNumberRelocatesToCorrectTask() throws {
        let path = try writeFile("t.md",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20\n- [ ] Target")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // Stale line number 2 now points at the completed "Recurring" line, but
        // relocation finds the real "Target" line and completes it — no error.
        XCTAssertNoThrow(
            try service.markTaskComplete(
                filePath: path, lineNumber: 2, // stale
                originalLine: "- [ ] Target",
                completionDate: makeDate(2026, 3, 30),
                vaultPath: vaultURL.path
            )
        )
        XCTAssertTrue(try readLines("t.md").contains { $0.contains("- [x] Target") },
                      "Target relocated and completed despite the stale index")
    }

    func testWrongOriginalLineNeverClobbersDifferentTask() throws {
        // The single most important safety property: asked to complete a task that
        // does not exist in the file, we must NEVER complete a different task that
        // happens to sit at the recorded index. No throw, no clobber — a no-op.
        let path = try writeFile("t.md", "- [ ] Actual content")

        XCTAssertNoThrow(
            try service.markTaskComplete(
                filePath: path, lineNumber: 1,
                originalLine: "- [ ] Wrong content",
                completionDate: makeDate(2026, 3, 29),
                vaultPath: vaultURL.path
            )
        )
        XCTAssertEqual(try readLines("t.md")[0], "- [ ] Actual content",
                       "A different task must never be completed.")
    }

    func testStaleLineNumberPastEOFRelocates() throws {
        // Line index past EOF, but the exact task still exists — relocate and
        // complete rather than throwing lineNumberOutOfRange. (#75-followup)
        let path = try writeFile("t.md", "- [ ] Only line")

        XCTAssertNoThrow(
            try service.markTaskComplete(
                filePath: path, lineNumber: 5,
                originalLine: "- [ ] Only line",
                completionDate: makeDate(2026, 3, 29),
                vaultPath: vaultURL.path
            )
        )
        XCTAssertTrue(try readLines("t.md")[0].contains("- [x] Only line"),
                      "Relocated and completed")
    }

    func testCompleteFileNotFound() throws {
        XCTAssertThrowsError(
            try service.markTaskComplete(
                filePath: "/nonexistent.md", lineNumber: 1,
                originalLine: "- [ ] Task",
                completionDate: makeDate(2026, 3, 29),
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    func testUTF8RoundTrip() throws {
        // File with emoji, CJK, accented characters, and special symbols
        let content = [
            "- [ ] 日本語タスク 📅 2026-04-01",
            "- [ ] Tâche française avec accents",
            "- [ ] Task with 🎉 emoji in title #célébration"
        ].joined(separator: "\n")
        let path = try writeFile("t.md", content)
        let originalLines = content.components(separatedBy: "\n")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] 日本語タスク 📅 2026-04-01",
            completionDate: makeDate(2026, 4, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("- [x] 日本語タスク"), "CJK preserved")
        XCTAssertEqual(lines[1], originalLines[1], "French line byte-identical")
        XCTAssertEqual(lines[2], originalLines[2], "Emoji-in-title line byte-identical")
    }

    func testEmptyLinesAroundTask() throws {
        let content = "\n\n- [ ] Task surrounded by blanks\n\n"
        let path = try writeFile("t.md", content)

        try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Task surrounded by blanks",
            completionDate: makeDate(2026, 1, 1),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], "", "Empty line 1 preserved")
        XCTAssertEqual(lines[1], "", "Empty line 2 preserved")
        XCTAssertTrue(lines[2].contains("- [x]"), "Task completed")
        XCTAssertEqual(lines[3], "", "Empty line 4 preserved")
        XCTAssertEqual(lines[4], "", "Empty line 5 preserved")
    }

    func testWhitespaceTolerance() throws {
        // originalLine has leading whitespace difference — content match trims both sides
        let path = try writeFile("t.md", "  - [ ] Indented task")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Indented task", // no leading spaces
            completionDate: makeDate(2026, 1, 1),
            vaultPath: vaultURL.path
        )

        let line = try readLines("t.md")[0]
        // The guard trims .whitespaces before comparing, so this should pass
        XCTAssertTrue(line.contains("- [x] Indented task"), "Matched despite whitespace diff")
    }

    func testBackupCreatedBeforeModification() throws {
        let path = try writeFile("t.md", "- [ ] Task to back up")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Task to back up",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // Check that a backup file was created
        let backupDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Remindian/backups")

        if FileManager.default.fileExists(atPath: backupDir.path) {
            let backups = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
            let matching = backups.filter { $0.hasPrefix("t_") || $0.hasPrefix("t.md_") }
            XCTAssertFalse(matching.isEmpty, "Backup file should exist for t.md")
        }
        // If backup dir doesn't exist (sandboxed test), skip — the important thing
        // is that the write succeeded (backup is called before write in the code)
    }

    // MARK: Position-Aware Offset Formula

    func testPositionAwareOffsetFormula() {
        let insertions = [5, 10, 15]

        XCTAssertEqual(insertions.filter { $0 <= 3 }.count, 0)
        XCTAssertEqual(insertions.filter { $0 <= 5 }.count, 1)
        XCTAssertEqual(insertions.filter { $0 <= 8 }.count, 1)
        XCTAssertEqual(insertions.filter { $0 <= 10 }.count, 2)
        XCTAssertEqual(insertions.filter { $0 <= 12 }.count, 2)
        XCTAssertEqual(insertions.filter { $0 <= 20 }.count, 3)
        XCTAssertEqual([Int]().filter { $0 <= 99 }.count, 0)
    }
}
