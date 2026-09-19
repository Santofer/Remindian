import XCTest
@testable import Remindian

final class TaskParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testSimpleTaskParsing() {
        let line = "- [ ] Buy groceries"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.title, "Buy groceries")
        XCTAssertFalse(task?.isCompleted ?? true)
    }

    func testCompletedTaskParsing() {
        let line = "- [x] Buy groceries ✅ 2026-01-15"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertTrue(task?.isCompleted ?? false)
        XCTAssertNotNil(task?.completedDate)
    }

    func testTaskWithDueDate() {
        let line = "- [ ] Submit report 📅 2026-03-15"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.title, "Submit report")
        XCTAssertNotNil(task?.dueDate)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(dateFormatter.string(from: task!.dueDate!), "2026-03-15")
    }

    func testTaskWithStartDate() {
        let line = "- [ ] Start project 🛫 2026-02-01 📅 2026-03-15"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertNotNil(task?.startDate)
        XCTAssertNotNil(task?.dueDate)
    }

    func testTaskWithScheduledDate() {
        let line = "- [ ] Review docs ⏳ 2026-02-20"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertNotNil(task?.scheduledDate)
    }

    // MARK: - Priority Parsing

    func testHighPriority() {
        let line = "- [ ] Urgent task ⏫"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.priority, .high)
    }

    func testMediumPriority() {
        let line = "- [ ] Normal task 🔼"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.priority, .medium)
    }

    func testLowPriority() {
        let line = "- [ ] Optional task 🔽"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.priority, .low)
    }

    func testPriorityWithFE0FVariationSelector() {
        // Some systems append U+FE0F (variation selector) to emoji
        let line = "- [ ] Urgent task ⏫\u{FE0F}"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.priority, .high)
    }

    // MARK: - Tag Parsing

    func testSingleTag() {
        let line = "- [ ] Work meeting #work"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertTrue(task?.tags.contains("#work") ?? false)
        XCTAssertEqual(task?.targetList, "work")
    }

    func testMultipleTags() {
        let line = "- [ ] Work meeting #work #urgent"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.tags.count, 2)
    }

    func testPlusPrefixTag() {
        // Issue #14: Support + prefix for list mappings
        let line = "- [ ] Work on feature +ProjectX"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertTrue(task?.tags.contains("+ProjectX") ?? false, "Should detect +ProjectX as a tag")
        XCTAssertEqual(task?.targetList, "ProjectX")
    }

    func testHashAndPlusTags() {
        let line = "- [ ] Review docs #work +ProjectX"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.tags.count, 2)
        XCTAssertTrue(task?.tags.contains("#work") ?? false)
        XCTAssertTrue(task?.tags.contains("+ProjectX") ?? false)
        // First tag (#work) determines the target list
        XCTAssertEqual(task?.targetList, "work")
    }

    // MARK: - Recurrence Parsing (#57)

    func testRecurrenceEmojiStripped() {
        let line = "- [ ] Pay rent 🔁 every month 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        // Title should NOT contain the recurrence text
        XCTAssertFalse(task!.title.contains("every month"))
        XCTAssertFalse(task!.title.contains("🔁"))
        XCTAssertEqual(task?.title.trimmingCharacters(in: .whitespaces), "Pay rent")
    }

    func testPlainTextRecurrenceStripped() {
        let line = "- [ ] Weekly standup every week 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        // Plain text recurrence should be stripped
        XCTAssertFalse(task!.title.contains("every week"))
    }

    /// #57 Phase A: recurrence rule text is preserved on SyncTask.recurrenceRule
    /// (not just stripped), so we can disambiguate completed+new-uncompleted pairs
    /// and later write EKRecurrenceRule on the Reminders side.
    func testRecurrenceRulePreservedEmojiForm() {
        let line = "- [ ] Pay rent 🔁 every month 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task?.recurrenceRule, "Recurrence rule should be captured, not discarded")
        XCTAssertTrue(task!.recurrenceRule!.contains("every month"))
    }

    func testRecurrenceRulePreservedPlainTextForm() {
        let line = "- [ ] Weekly standup every week 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task?.recurrenceRule, "Plain-text recurrence should be captured")
        XCTAssertTrue(task!.recurrenceRule!.contains("every week"))
    }

    func testNonRecurringTaskHasNilRule() {
        let line = "- [ ] Just a task 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNil(task?.recurrenceRule)
    }

    func testRecurrenceWithWhenDoneClause() {
        let line = "- [ ] Review budget 🔁 every 2 weeks when done 📅 2026-03-01"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task?.recurrenceRule)
        XCTAssertTrue(task!.recurrenceRule!.contains("every 2 weeks"))
    }

    // MARK: - Edge Cases

    func testNonTaskLine() {
        let line = "This is just a regular line"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNil(task)
    }

    func testBulletPointNotTask() {
        let line = "- Just a regular bullet"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNil(task)
    }

    func testWikilinkBulletNotTask() {
        // Issue #13: List items with wikilinks should NOT be parsed as tasks
        let line = "- [[Sarah]] coming to stay"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNil(task, "A list item starting with a wikilink should not be parsed as a task")
    }

    func testMultipleWikilinksBulletNotTask() {
        let line = "- [[Project X]] review with [[John]]"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNil(task, "A list item with wikilinks should not be parsed as a task")
    }

    func testEmptyCheckbox() {
        let line = "- [ ] "
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        // Should return nil or a task with empty title
        if let task = task {
            XCTAssertTrue(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testTaskWithWikiLinks() {
        let line = "- [ ] Talk to [[John Doe]] about [[Project X]]"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertTrue(task!.title.contains("[[John Doe]]"))
    }

    func testTaskWithAllMetadata() {
        let line = "- [ ] Complex task ⏫ 📅 2026-03-15 🛫 2026-03-01 ⏳ 2026-02-28 #work 🔁 every week"
        let task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.priority, .high)
        XCTAssertNotNil(task?.dueDate)
        XCTAssertNotNil(task?.startDate)
        XCTAssertNotNil(task?.scheduledDate)
        XCTAssertTrue(task?.tags.contains("#work") ?? false)
        XCTAssertFalse(task!.title.contains("every week"))
    }

    // MARK: - Dataview Inline Fields (#41)

    func testDataviewDueDate() {
        let line = "- [ ] Buy milk [due::2025-06-15]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        XCTAssertNil(task.dueDate) // Emoji parser won't find it
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertNotNil(task.dueDate)
        XCTAssertEqual(task.title, "Buy milk")
    }

    func testDataviewPriority() {
        let line = "- [ ] Important task [priority::high]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.title, "Important task")
    }

    func testDataviewProject() {
        let line = "- [ ] Fix login bug [project::Backend]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertEqual(task.targetList, "Backend")
        XCTAssertEqual(task.title, "Fix login bug")
    }

    func testDataviewProjectWikilink() {
        let line = "- [ ] Review PR [project::[[Code Review]]]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertEqual(task.targetList, "Code Review")
    }

    func testDataviewMultipleFields() {
        let line = "- [ ] Complete report [due::2025-12-01] [priority::medium] [project::Work]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertNotNil(task.dueDate)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.targetList, "Work")
        XCTAssertEqual(task.title, "Complete report")
    }

    func testDataviewTags() {
        let line = "- [ ] Setup CI [tags::devops, infrastructure]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertTrue(task.tags.contains("#devops"))
        XCTAssertTrue(task.tags.contains("#infrastructure"))
    }

    func testDataviewParenthesisSyntax() {
        let line = "- [ ] Read book (due::2025-08-01) (priority::low)"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertNotNil(task.dueDate)
        XCTAssertEqual(task.priority, .low)
        XCTAssertEqual(task.title, "Read book")
    }

    func testDataviewDoesNotOverrideEmoji() {
        // Emoji metadata takes precedence — dataview fills gaps only
        let line = "- [ ] Task ⏫ 📅 2025-01-01 [due::2025-12-31] [priority::low]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        let originalDue = task.dueDate
        let originalPriority = task.priority
        SyncTask.parseDataviewFields(from: line, into: &task)
        // Emoji values should be preserved
        XCTAssertEqual(task.dueDate, originalDue)
        XCTAssertEqual(task.priority, originalPriority)
    }

    func testDataviewStartDate() {
        let line = "- [ ] Plan trip [start::2025-03-01] [scheduled::2025-03-15]"
        var task = SyncTask.fromObsidianLine(line, filePath: "/test.md", lineNumber: 1)!
        SyncTask.parseDataviewFields(from: line, into: &task)
        XCTAssertNotNil(task.startDate)
    }

    func testMarkdownHeadingRecognizesATXHeadingAndStripsClosingHashes() {
        XCTAssertEqual(ObsidianService.markdownHeading(in: "## Work ##"), "Work")
        XCTAssertEqual(ObsidianService.markdownHeading(in: "  ### Personal"), "Personal")
        XCTAssertNil(ObsidianService.markdownHeading(in: "#not-a-heading"))
    }

    func testTasksCarryTheirNearestPrecedingHeading() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let file = vault.appendingPathComponent("Tasks.md")
        try "# Top\n## Work\n- [ ] Send proposal\n## Home\n- [ ] Buy milk\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(file, vaultPath: vault.path)
        XCTAssertEqual(tasks.map { $0.obsidianSource?.sectionHeading }, ["Work", "Home"])
    }
}
