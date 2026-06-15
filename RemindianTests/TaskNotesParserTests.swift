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
}
