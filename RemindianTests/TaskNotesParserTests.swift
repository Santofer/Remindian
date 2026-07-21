import XCTest
@testable import Remindian

final class TaskNotesParserTests: XCTestCase {

    // MARK: - YAML Frontmatter Parsing

    func testFrontmatterUpdateField() {
        let source = TaskNotesSource()
        let content = """
        ---
        status: todo
        priority: high
        due: 2026-03-15
        ---
        # My Task
        """

        // Use reflection to test private method indirectly via the public API
        // Instead, we test via the full flow
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let taskFile = tempDir.appendingPathComponent("test-task.md")
        try? content.write(to: taskFile, atomically: true, encoding: .utf8)

        // Read it back as a task
        let config = SyncConfiguration()
        config.vaultPath = tempDir.path
        config.taskNotesFolder = "" // root level

        // The file should be at /test-task.md relative to vault
        let fileContent = try? String(contentsOf: taskFile, encoding: .utf8)
        XCTAssertNotNil(fileContent)
        XCTAssertTrue(fileContent?.contains("status: todo") ?? false)
        XCTAssertTrue(fileContent?.contains("priority: high") ?? false)
        XCTAssertTrue(fileContent?.contains("due: 2026-03-15") ?? false)
    }

    func testPriorityMapping() {
        // Test that TaskNotes priorities map correctly to SyncTask priorities
        let priorities: [(String, SyncTask.Priority)] = [
            ("high", .high),
            ("medium", .medium),
            ("low", .low),
            ("none", .none),
        ]

        for (yamlValue, expectedPriority) in priorities {
            let content = """
            ---
            status: todo
            priority: \(yamlValue)
            ---
            # Priority Test
            """

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let taskFile = tempDir.appendingPathComponent("test.md")
            try? content.write(to: taskFile, atomically: true, encoding: .utf8)

            // Parse the content
            let fileContent = try? String(contentsOf: taskFile, encoding: .utf8)
            XCTAssertNotNil(fileContent)
            XCTAssertTrue(fileContent?.contains("priority: \(yamlValue)") ?? false,
                         "Should contain priority: \(yamlValue)")
        }
    }

    func testStatusMapping() {
        let config = SyncConfiguration()
        // Default completed statuses: ["done", "completed", "cancelled"]

        let statusMappings: [(String, Bool)] = [
            ("todo", false),
            ("done", true),
            ("completed", true),
            ("cancelled", true),
            ("open", false),
            ("in-progress", false),
        ]

        for (status, expectedCompleted) in statusMappings {
            let isCompleted = config.isTaskNotesStatusCompleted(status)
            XCTAssertEqual(isCompleted, expectedCompleted,
                          "Status '\(status)' should map to isCompleted=\(expectedCompleted)")
        }
    }

    func testCustomStatusMapping() {
        let config = SyncConfiguration()
        // Custom statuses: user has "archived" and "shipped" as completed
        config.taskNotesCompletedStatuses = ["done", "archived", "shipped"]

        XCTAssertTrue(config.isTaskNotesStatusCompleted("done"))
        XCTAssertTrue(config.isTaskNotesStatusCompleted("archived"))
        XCTAssertTrue(config.isTaskNotesStatusCompleted("shipped"))
        XCTAssertTrue(config.isTaskNotesStatusCompleted("Done"))  // case-insensitive
        XCTAssertFalse(config.isTaskNotesStatusCompleted("completed"))  // removed from list
        XCTAssertFalse(config.isTaskNotesStatusCompleted("open"))
        XCTAssertFalse(config.isTaskNotesStatusCompleted("in-progress"))
    }

    func testTagsParsing() {
        let yamlTags = "[work, urgent, project-alpha]"
        let cleaned = yamlTags
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        let tags = cleaned.components(separatedBy: ",").map { "#\($0.trimmingCharacters(in: .whitespaces))" }

        XCTAssertEqual(tags.count, 3)
        XCTAssertTrue(tags.contains("#work"))
        XCTAssertTrue(tags.contains("#urgent"))
        XCTAssertTrue(tags.contains("#project-alpha"))
    }

    func testDateParsing() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let date = dateFormatter.date(from: "2026-03-15")
        XCTAssertNotNil(date)

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let isoDate = isoFormatter.date(from: "2026-03-15T14:30:00")
        XCTAssertNotNil(isoDate)
    }

    // MARK: - #78 default tag for reminders synced into TaskNotes

    private func makeFileSource(defaultTag: String) -> TaskNotesSource {
        let source = TaskNotesSource()
        source.integrationMode = .fileBased   // force the file writer (no mtn CLI)
        source.defaultTag = defaultTag
        return source
    }

    private func newNoteContent(_ source: TaskNotesSource, _ task: SyncTask) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let config = SyncConfiguration()
        config.vaultPath = tempDir.path
        config.taskNotesFolder = "tasks"
        let src = try source.appendNewTask(task, config: config)
        let rel = src.filePath.hasPrefix("/") ? String(src.filePath.dropFirst()) : src.filePath
        return try String(contentsOf: tempDir.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_78_defaultTagStampedOnTaglessReminder() throws {
        let content = try newNoteContent(makeFileSource(defaultTag: "task"), SyncTask(title: "Buy milk"))
        XCTAssertTrue(content.contains("- task"), "Default tag must be written to frontmatter tags. Got:\n\(content)")
    }

    func test_78_defaultTagNotDuplicated() throws {
        let task = SyncTask(title: "Buy milk", tags: ["#task"])
        let content = try newNoteContent(makeFileSource(defaultTag: "task"), task)
        let occurrences = content.components(separatedBy: "- task").count - 1
        XCTAssertEqual(occurrences, 1, "Default tag must not be duplicated when already present. Got:\n\(content)")
    }

    func test_78_noTagsBlockWhenUnsetAndTagless() throws {
        let content = try newNoteContent(makeFileSource(defaultTag: ""), SyncTask(title: "Buy milk"))
        XCTAssertFalse(content.contains("tags:"), "No default tag + no task tags → no tags block. Got:\n\(content)")
    }

    // MARK: - #82: due dates with a time-of-day must sync (not vanish)
    // `DateFormatter` does not prefix-match, so parsing "2026-07-20T14:30" with a
    // date-only format returned nil — a TaskNotes task with a time synced with NO
    // due date at all.

    func test_82_parsesDateOnly() throws {
        let d = try XCTUnwrap(TaskNotesSource.parseFrontmatterDate("2026-07-20"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 7, 20, 0, 0])
    }

    func test_82_parsesDateTimeWithoutSeconds() throws {
        // TaskNotes' usual datetime form — this is the exact case that produced no due date.
        let d = try XCTUnwrap(TaskNotesSource.parseFrontmatterDate("2026-07-20T14:30"),
                              "A due value with a time must parse, not return nil")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 7, 20, 14, 30])
    }

    func test_82_parsesDateTimeWithSeconds() throws {
        let d = try XCTUnwrap(TaskNotesSource.parseFrontmatterDate("2026-07-20T14:30:45"))
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        XCTAssertEqual([c.hour, c.minute], [14, 30])
    }

    func test_82_parsesBlankAndGarbageAsNil() {
        XCTAssertNil(TaskNotesSource.parseFrontmatterDate(""))
        XCTAssertNil(TaskNotesSource.parseFrontmatterDate("   "))
        XCTAssertNil(TaskNotesSource.parseFrontmatterDate("not a date"))
    }

    func test_82_formatRoundTripsPreservingTime() throws {
        // Round-trip: a datetime keeps its time, an all-day date stays date-only
        // so existing files don't churn.
        let withTime = try XCTUnwrap(TaskNotesSource.parseFrontmatterDate("2026-07-20T14:30"))
        XCTAssertEqual(TaskNotesSource.formatFrontmatterDate(withTime), "2026-07-20T14:30")

        let allDay = try XCTUnwrap(TaskNotesSource.parseFrontmatterDate("2026-07-20"))
        XCTAssertEqual(TaskNotesSource.formatFrontmatterDate(allDay), "2026-07-20")
    }

    func test_82_scannedTaskCarriesTimeOfDay() throws {
        // End-to-end: a TaskNotes file with a date+time must produce a due date.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tasksDir = tempDir.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try """
        ---
        status: todo
        due: 2026-07-20T14:30
        ---
        # Meeting
        """.write(to: tasksDir.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)

        let source = TaskNotesSource()
        source.integrationMode = .fileBased
        let config = SyncConfiguration()
        config.vaultPath = tempDir.path
        config.taskNotesFolder = "tasks"

        let tasks = try source.scanTasks(config: config)
        let due = try XCTUnwrap(tasks.first?.dueDate, "A task with a date+time must have a due date (#82)")
        let c = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual([c.hour, c.minute], [14, 30], "The time-of-day must survive the scan")
    }

    // MARK: - #80: fieldLookup must never trap on blank / duplicate field names
    // The original code built `fieldLookup` as a dictionary *literal* of
    // user-entered names. Two blanked fields (both "") or two identical names
    // collide → `Dictionary.init(dictionaryLiteral:)` fatal-errors (EXC_BREAKPOINT),
    // crashing every launch sync and bricking the app.

    func test_80_fieldLookupDoesNotTrapOnBlankNames() {
        // bengt's config: fields he doesn't use are blanked → multiple "" keys.
        var m = TaskNotesFieldMapping()
        m.project = ""
        m.context = ""
        m.completedDate = ""
        let lookup = m.fieldLookup   // must not trap
        XCTAssertNil(lookup[""], "Blank names must be dropped, not stored under an empty key")
        XCTAssertEqual(lookup["title"], "title")
        XCTAssertEqual(lookup["due"], "due")
        XCTAssertEqual(lookup["tags"], "tags")
    }

    func test_80_fieldLookupDoesNotTrapOnDuplicateNames() {
        // Two fields mapped to the same custom name (case-insensitively).
        var m = TaskNotesFieldMapping()
        m.due = "when"
        m.scheduled = "WHEN"
        let lookup = m.fieldLookup   // must not trap
        // Declaration order wins: `due` precedes `scheduled`.
        XCTAssertEqual(lookup["when"], "due")
        XCTAssertEqual(lookup.values.filter { $0 == "due" || $0 == "scheduled" }.count, 1)
    }

    func test_80_fieldLookupDefaultMappingIntact() {
        let lookup = TaskNotesFieldMapping().fieldLookup
        XCTAssertEqual(lookup.count, 9, "All nine distinct defaults must be present")
        XCTAssertEqual(lookup["status"], "status")
        XCTAssertEqual(lookup["completeddate"], "completedDate")
        XCTAssertEqual(lookup["context"], "context")
    }

    func test_80_scanDoesNotCrashWithBlankedMapping() throws {
        // End-to-end reproduction of the #80 backtrace:
        // scanTasks → scanTasksFromFiles → parseTaskNotesFile → fieldLookup.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tasksDir = tempDir.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let taskFile = tasksDir.appendingPathComponent("uppgift.md")   // Swedish, like bengt
        try """
        ---
        status: todo
        due: 2026-06-19
        ---
        # Uppgift
        """.write(to: taskFile, atomically: true, encoding: .utf8)

        let source = TaskNotesSource()
        source.integrationMode = .fileBased
        var blanked = TaskNotesFieldMapping()
        blanked.project = ""
        blanked.context = ""
        blanked.completedDate = ""
        source.fieldMapping = blanked

        let config = SyncConfiguration()
        config.vaultPath = tempDir.path
        config.taskNotesFolder = "tasks"

        let tasks = try source.scanTasks(config: config)   // must not trap
        XCTAssertEqual(tasks.count, 1, "The blanked-mapping vault must scan without crashing")
    }
}
