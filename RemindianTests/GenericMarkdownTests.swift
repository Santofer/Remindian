import XCTest
@testable import Remindian

/// Tests for the Generic Markdown source (#27, v5.15.0) — the NotePlan-style
/// configurable token dialect.
///
/// The load-bearing invariant is **round-trip fidelity**: for every field the
/// dialect supports, `parse(buildLine(task))` reproduces the task, and surgical
/// edits (`markComplete`, `markIncomplete`, `updateMetadata`) preserve every
/// untouched token on the line. If parsing and writing ever disagree, a sync
/// could corrupt a user's NotePlan file — so these are correctness tests, not
/// cosmetics.
final class GenericMarkdownTests: XCTestCase {

    private func makeParser(_ settings: SyncConfiguration.GenericMarkdownSettings = .init()) -> GenericMarkdownParser {
        GenericMarkdownParser(settings: settings)
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    // MARK: - Parsing (NotePlan defaults)

    func test_parsesNotePlanDueAndPriorityAndTag() {
        let p = makeParser()
        let task = p.parse("- [ ] Buy milk >2025-01-20 !!! #errands", filePath: "/n.md", lineNumber: 3)
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.title, "Buy milk")
        XCTAssertEqual(task?.dueDate, date("2025-01-20"))
        XCTAssertEqual(task?.priority, .high)
        XCTAssertEqual(task?.tags, ["#errands"])
        XCTAssertEqual(task?.isCompleted, false)
        XCTAssertEqual(task?.obsidianSource?.lineNumber, 3)
    }

    func test_parsesParenthesizedDoneDate() {
        let p = makeParser()
        let task = p.parse("- [x] Ship it @done(2025-02-01)", filePath: "/n.md", lineNumber: 1)
        XCTAssertEqual(task?.isCompleted, true)
        XCTAssertEqual(task?.completedDate, date("2025-02-01"))
        XCTAssertEqual(task?.title, "Ship it")
    }

    func test_priorityLongestTokenWins() {
        let p = makeParser()
        XCTAssertEqual(p.parse("- [ ] A !!!", filePath: "/n", lineNumber: 1)?.priority, .high)
        XCTAssertEqual(p.parse("- [ ] A !!", filePath: "/n", lineNumber: 1)?.priority, .medium)
        XCTAssertEqual(p.parse("- [ ] A !", filePath: "/n", lineNumber: 1)?.priority, .low)
    }

    func test_bangInsideWordIsNotPriority() {
        let p = makeParser()
        let task = p.parse("- [ ] Hello! world", filePath: "/n", lineNumber: 1)
        XCTAssertEqual(task?.priority, SyncTask.Priority.none, "A `!` glued to a word is not a priority token.")
        XCTAssertEqual(task?.title, "Hello! world")
    }

    func test_acceptsAsteriskAndPlusBullets() {
        let p = makeParser()
        XCTAssertNotNil(p.parse("* [ ] Star task", filePath: "/n", lineNumber: 1))
        XCTAssertNotNil(p.parse("+ [ ] Plus task", filePath: "/n", lineNumber: 1))
    }

    func test_rejectsNonTaskLines() {
        let p = makeParser()
        XCTAssertNil(p.parse("Just a paragraph", filePath: "/n", lineNumber: 1))
        XCTAssertNil(p.parse("- [[Wikilink]] not a task", filePath: "/n", lineNumber: 1))
        XCTAssertNil(p.parse("# Heading", filePath: "/n", lineNumber: 1))
        XCTAssertNil(p.parse("- bare bullet, no checkbox", filePath: "/n", lineNumber: 1))
    }

    func test_unknownMarkerNotParsed() {
        // Default markers are " " open, "x"/"X" done. An unrecognized marker
        // like `/` isn't classified → skipped (conservative).
        let p = makeParser()
        XCTAssertNil(p.parse("- [/] in progress", filePath: "/n", lineNumber: 1))
    }

    func test_ignoredMarkerSkipsLine() {
        let p = makeParser()
        XCTAssertNil(p.parse("- [-] cancelled", filePath: "/n", lineNumber: 1, ignoredMarkers: ["-"]))
    }

    func test_disabledTokenIsNotParsed() {
        // start/scheduled tokens are empty by default → never extracted.
        let p = makeParser()
        let task = p.parse("- [ ] Task <2025-01-01", filePath: "/n", lineNumber: 1)
        XCTAssertNil(task?.startDate)
        XCTAssertEqual(task?.title, "Task <2025-01-01", "An unconfigured token is left in the title verbatim.")
    }

    // MARK: - Round-trip (the core invariant)

    func test_roundTrip_allFields() {
        var settings = SyncConfiguration.GenericMarkdownSettings()
        settings.startToken = "<"   // enable start so we can round-trip it
        let p = makeParser(settings)

        let original = SyncTask(
            title: "Write report",
            isCompleted: true,
            priority: .medium,
            dueDate: date("2025-03-15"),
            startDate: date("2025-03-10"),
            completedDate: date("2025-03-14"),
            tags: ["#work"]
        )
        let line = p.buildLine(from: original)
        let parsed = p.parse(line, filePath: "/n", lineNumber: 1)
        XCTAssertNotNil(parsed, "Built line must re-parse. Line was: \(line)")
        XCTAssertEqual(parsed?.title, "Write report")
        XCTAssertEqual(parsed?.isCompleted, true)
        XCTAssertEqual(parsed?.priority, .medium)
        XCTAssertEqual(parsed?.dueDate, date("2025-03-15"))
        XCTAssertEqual(parsed?.startDate, date("2025-03-10"))
        XCTAssertEqual(parsed?.completedDate, date("2025-03-14"))
        XCTAssertEqual(parsed?.tags, ["#work"])
    }

    func test_roundTrip_minimalOpenTask() {
        let p = makeParser()
        let original = SyncTask(title: "Simple", isCompleted: false)
        let parsed = p.parse(p.buildLine(from: original), filePath: "/n", lineNumber: 1)
        XCTAssertEqual(parsed?.title, "Simple")
        XCTAssertEqual(parsed?.isCompleted, false)
        XCTAssertEqual(parsed?.priority, SyncTask.Priority.none)
        XCTAssertNil(parsed?.dueDate)
    }

    // MARK: - Surgical completion

    func test_markComplete_flipsCheckboxAndAppendsDone_preservingTokens() {
        let p = makeParser()
        let line = "- [ ] Buy milk >2025-01-20 !! #errands"
        let done = p.markComplete(line: line, completionDate: date("2025-01-22"))
        XCTAssertTrue(done.hasPrefix("- [x]"), "Checkbox must flip to done. Got: \(done)")
        XCTAssertTrue(done.contains(">2025-01-20"), "Due date must be preserved verbatim.")
        XCTAssertTrue(done.contains("!!"), "Priority must be preserved.")
        XCTAssertTrue(done.contains("#errands"), "Tag must be preserved.")
        XCTAssertTrue(done.contains("@done(2025-01-22)"), "Done token must be appended. Got: \(done)")
    }

    func test_markComplete_isIdempotentOnDoneToken() {
        let p = makeParser()
        let line = "- [x] Done already @done(2025-01-01)"
        let again = p.markComplete(line: line, completionDate: date("2025-02-02"))
        XCTAssertEqual(again.components(separatedBy: "@done").count - 1, 1, "Must not add a second @done token.")
    }

    func test_markIncomplete_flipsAndRemovesDone() {
        let p = makeParser()
        let line = "- [x] Task >2025-01-20 @done(2025-01-22) #t"
        let open = p.markIncomplete(line: line)
        XCTAssertTrue(open.hasPrefix("- [ ]"))
        XCTAssertFalse(open.contains("@done"), "Done token must be removed. Got: \(open)")
        XCTAssertTrue(open.contains(">2025-01-20"), "Due date preserved.")
        XCTAssertTrue(open.contains("#t"))
    }

    // MARK: - Surgical metadata

    func test_updateMetadata_replacesDueAndPriority() {
        let p = makeParser()
        let line = "- [ ] Task >2025-01-20 !"
        let updated = p.updateMetadata(line: line, newDueDate: .some(date("2025-05-05")), newStartDate: nil, newPriority: .high, newTags: nil)
        XCTAssertTrue(updated.contains(">2025-05-05"), "Got: \(updated)")
        XCTAssertFalse(updated.contains(">2025-01-20"))
        XCTAssertTrue(updated.contains("!!!"), "Priority upgraded to high. Got: \(updated)")
        // Re-parsing the edited line confirms exactly one priority survived.
        XCTAssertEqual(makeParser().parse(updated, filePath: "/n", lineNumber: 1)?.priority, .high)
    }

    func test_updateMetadata_addsDueWhenAbsent_andRemovesWhenNil() {
        let p = makeParser()
        let added = p.updateMetadata(line: "- [ ] Task", newDueDate: .some(date("2025-06-01")), newStartDate: nil, newPriority: nil, newTags: nil)
        XCTAssertTrue(added.contains(">2025-06-01"))
        let removed = p.updateMetadata(line: added, newDueDate: .some(nil), newStartDate: nil, newPriority: nil, newTags: nil)
        XCTAssertFalse(removed.contains(">"), "Due token removed. Got: \(removed)")
        XCTAssertEqual(removed, "- [ ] Task")
    }

    func test_updateMetadata_replacesTags() {
        let p = makeParser()
        let updated = p.updateMetadata(line: "- [ ] Task #old >2025-01-01", newDueDate: nil, newStartDate: nil, newPriority: nil, newTags: ["#new", "#extra"])
        XCTAssertFalse(updated.contains("#old"))
        XCTAssertTrue(updated.contains("#new"))
        XCTAssertTrue(updated.contains("#extra"))
        XCTAssertTrue(updated.contains(">2025-01-01"), "Due preserved.")
    }

    // MARK: - Source-level scan + writeback against real files

    func test_source_scanAndCompletionWriteback() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("gm-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let file = vault.appendingPathComponent("tasks.md")
        try "- [ ] Alpha >2025-01-10 !!\n- [x] Beta @done(2025-01-05)\nNot a task\n".write(to: file, atomically: true, encoding: .utf8)

        let config = SyncConfiguration()
        config.vaultPath = vault.path

        let source = GenericMarkdownSource()
        let tasks = try source.scanTasks(config: config)
        XCTAssertEqual(tasks.count, 2)
        let alpha = try XCTUnwrap(tasks.first { $0.title == "Alpha" })
        XCTAssertEqual(alpha.dueDate, date("2025-01-10"))
        XCTAssertEqual(alpha.priority, .medium)

        // Complete Alpha via the source; the file must reflect a surgical edit.
        try source.markTaskComplete(task: alpha, completionDate: date("2025-01-12"), config: config)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("- [x] Alpha >2025-01-10 !! @done(2025-01-12)"), "Surgical completion. File:\n\(after)")
        XCTAssertTrue(after.contains("- [x] Beta @done(2025-01-05)"), "Other lines untouched.")
        XCTAssertTrue(after.contains("Not a task"))
    }

    func test_source_appendNewTaskCreatesInbox() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("gm-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let config = SyncConfiguration()
        config.vaultPath = vault.path
        config.inboxFilePath = "Inbox.md"

        let source = GenericMarkdownSource()
        let task = SyncTask(title: "From reminders", isCompleted: false, priority: .high, dueDate: date("2025-09-09"))
        let src = try source.appendNewTask(task, config: config)

        let inbox = vault.appendingPathComponent("Inbox.md")
        let content = try String(contentsOf: inbox, encoding: .utf8)
        XCTAssertTrue(content.contains("- [ ] From reminders"))
        XCTAssertTrue(content.contains(">2025-09-09"))
        XCTAssertTrue(content.contains("!!!"))
        XCTAssertEqual(src.filePath, "/Inbox.md")

        // The appended line must itself re-parse cleanly (round-trip through disk).
        let reparsed = try source.scanTasks(config: config)
        XCTAssertTrue(reparsed.contains { $0.title == "From reminders" && $0.dueDate == self.date("2025-09-09") && $0.priority == .high })
    }

    func test_source_writebackAbortsOnLineMismatch() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("gm-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let file = vault.appendingPathComponent("t.md")
        try "- [ ] Original\n".write(to: file, atomically: true, encoding: .utf8)

        let config = SyncConfiguration()
        config.vaultPath = vault.path
        let source = GenericMarkdownSource()

        // A task whose recorded originalLine no longer matches the file (someone
        // edited it externally). Writeback must throw, not clobber.
        let stale = SyncTask(title: "Original", obsidianSource: .init(filePath: "/t.md", lineNumber: 1, originalLine: "- [ ] Something totally different"))
        XCTAssertThrowsError(try source.markTaskComplete(task: stale, completionDate: self.date("2025-01-01"), config: config))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- [ ] Original\n", "File must be untouched on mismatch.")
    }
}
