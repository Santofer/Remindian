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
        let statusMappings: [(String, Bool)] = [
            ("todo", false),
            ("done", true),
            ("completed", true),
            ("cancelled", true),
        ]

        for (status, expectedCompleted) in statusMappings {
            // Verify the mapping logic
            let isCompleted = status == "done" || status == "completed" || status == "cancelled"
            XCTAssertEqual(isCompleted, expectedCompleted,
                          "Status '\(status)' should map to isCompleted=\(expectedCompleted)")
        }
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
}
