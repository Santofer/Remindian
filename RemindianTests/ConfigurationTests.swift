import XCTest
@testable import Remindian

final class ConfigurationTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultConfiguration() {
        let config = SyncConfiguration()

        XCTAssertEqual(config.vaultPath, "")
        XCTAssertEqual(config.syncIntervalMinutes, 5)
        // Default OFF since v5.8.1 — fresh installs don't start syncing
        // automatically before the user has set up mappings (#62.4).
        XCTAssertFalse(config.enableAutoSync)
        XCTAssertTrue(config.syncOnLaunch)
        XCTAssertEqual(config.defaultList, "Reminders")
        XCTAssertTrue(config.excludedFolders.contains(".obsidian"))
        XCTAssertTrue(config.excludedFolders.contains(".git"))
        XCTAssertTrue(config.excludedFolders.contains(".trash"))
        XCTAssertTrue(config.includedFolders.isEmpty)
        XCTAssertFalse(config.dryRunMode)
        XCTAssertTrue(config.enableCompletionWriteback)
        XCTAssertEqual(config.taskSourceType, .obsidianTasks)
        XCTAssertEqual(config.taskDestinationType, .appleReminders)
        XCTAssertEqual(config.things3AuthToken, "")
        XCTAssertEqual(config.taskNotesFolder, "")
    }

    // MARK: - Codable

    func testConfigurationEncodeDecode() {
        let config = SyncConfiguration()
        config.vaultPath = "/Users/test/vault"
        config.taskSourceType = .taskNotes
        config.taskDestinationType = .things3
        config.things3AuthToken = "test-token-123"
        config.taskNotesFolder = "TaskNotes/Tasks"
        config.includedFolders = ["Work", "Personal"]
        config.excludedFolders = [".obsidian", ".git", "Templates"]
        config.listMappings = [
            SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work"),
            SyncConfiguration.ListMapping(obsidianTag: "personal", remindersList: "Personal"),
        ]

        // Encode
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(config) else {
            XCTFail("Failed to encode config")
            return
        }

        // Decode
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(SyncConfiguration.self, from: data) else {
            XCTFail("Failed to decode config")
            return
        }

        XCTAssertEqual(decoded.vaultPath, "/Users/test/vault")
        XCTAssertEqual(decoded.taskSourceType, .taskNotes)
        XCTAssertEqual(decoded.taskDestinationType, .things3)
        XCTAssertEqual(decoded.things3AuthToken, "test-token-123")
        XCTAssertEqual(decoded.taskNotesFolder, "TaskNotes/Tasks")
        XCTAssertEqual(decoded.includedFolders, ["Work", "Personal"])
        XCTAssertEqual(decoded.excludedFolders, [".obsidian", ".git", "Templates"])
        XCTAssertEqual(decoded.listMappings.count, 2)
        XCTAssertEqual(decoded.listMappings[0].obsidianTag, "work")
        XCTAssertEqual(decoded.listMappings[0].remindersList, "Work")
    }

    func testBackwardCompatibility() {
        // Simulate a config from before source/destination were added
        let json = """
        {
            "vaultPath": "/old/vault",
            "syncIntervalMinutes": 5,
            "enableAutoSync": true,
            "syncOnLaunch": true,
            "listMappings": [],
            "defaultList": "Reminders",
            "taskFilesPattern": "*.md",
            "excludedFolders": [".obsidian"],
            "syncCompletedTasks": false,
            "conflictResolution": "obsidian",
            "includeDueTime": false,
            "hideDockIcon": false,
            "forceDarkIcon": false,
            "dryRunMode": false,
            "enableCompletionWriteback": true,
            "enableDueDateWriteback": true,
            "enableStartDateWriteback": true,
            "enablePriorityWriteback": true,
            "enableNewTaskWriteback": false,
            "inboxFilePath": "Inbox.md",
            "enableFileWatcher": false,
            "enableNotifications": true,
            "globalHotKeyEnabled": false,
            "globalHotKeyCode": 1,
            "globalHotKeyModifiers": 3328
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(SyncConfiguration.self, from: json) else {
            XCTFail("Failed to decode legacy config")
            return
        }

        // New fields should have defaults
        XCTAssertEqual(config.taskSourceType, .obsidianTasks)
        XCTAssertEqual(config.taskDestinationType, .appleReminders)
        XCTAssertEqual(config.things3AuthToken, "")
        XCTAssertEqual(config.taskNotesFolder, "")
        XCTAssertTrue(config.includedFolders.isEmpty)
    }

    // MARK: - #80-class: syncIntervalMinutes must be clamped on decode

    func test_80_syncIntervalClampedHighOnDecodePreventsOverflow() throws {
        // A corrupt / hand-edited profiles.json can carry a value that is a valid
        // Int64 (so decode succeeds and try? does not catch it) but overflows
        // `minutes * 60` when arming the auto-sync timer → EXC_BREAKPOINT on launch.
        let config = SyncConfiguration()
        config.syncIntervalMinutes = 200_000_000_000_000_000  // 2e17
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: data)

        XCTAssertLessThanOrEqual(decoded.syncIntervalMinutes, 24 * 60)
        XCTAssertGreaterThanOrEqual(decoded.syncIntervalMinutes, 1)
        // The clamped value must be safe to multiply by 60 (the timer arithmetic).
        let (_, overflow) = decoded.syncIntervalMinutes.multipliedReportingOverflow(by: 60)
        XCTAssertFalse(overflow, "Clamped interval must never overflow minutes * 60")
    }

    func test_80_syncIntervalClampedLowOnDecode() throws {
        let config = SyncConfiguration()
        config.syncIntervalMinutes = 0   // would schedule a continuously-firing timer
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: data)
        XCTAssertEqual(decoded.syncIntervalMinutes, 1)
    }

    func test_80_syncIntervalNormalValuePreserved() throws {
        let config = SyncConfiguration()
        config.syncIntervalMinutes = 30   // a normal UI value must pass through unchanged
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: data)
        XCTAssertEqual(decoded.syncIntervalMinutes, 30)
    }

    // MARK: - List Mapping

    func testRemindersListForTag() {
        let config = SyncConfiguration()
        config.listMappings = [
            SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work Tasks"),
            SyncConfiguration.ListMapping(obsidianTag: "personal", remindersList: "Personal"),
        ]
        config.defaultList = "Inbox"

        XCTAssertEqual(config.remindersListForTag("work"), "Work Tasks")
        XCTAssertEqual(config.remindersListForTag("personal"), "Personal")
        XCTAssertEqual(config.remindersListForTag("unknown"), "Unknown")  // Auto-capitalize
    }

    // MARK: - Source/Destination Types

    func testSourceTypeDisplayNames() {
        XCTAssertEqual(SyncConfiguration.TaskSourceType.obsidianTasks.displayName, "Obsidian Tasks")
        XCTAssertEqual(SyncConfiguration.TaskSourceType.taskNotes.displayName, "TaskNotes")
    }

    func testDestinationTypeDisplayNames() {
        XCTAssertEqual(SyncConfiguration.TaskDestinationType.appleReminders.displayName, "Apple Reminders")
        XCTAssertEqual(SyncConfiguration.TaskDestinationType.things3.displayName, "Things 3")
    }

    // MARK: - File Path Mapping (#37)

    func testResolveTargetListTagMappingWins() {
        let config = SyncConfiguration()
        config.listMappings = [
            SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work Tasks"),
        ]
        config.filePathMappings = [
            SyncConfiguration.FileMapping(filePath: "Projects/Work.md", remindersList: "Work Projects"),
        ]

        // Tag mapping should win over file mapping
        let result = config.resolveTargetList(tag: "work", filePath: "Projects/Work.md")
        XCTAssertEqual(result, "Work Tasks")
    }

    func testResolveTargetListFileMapping() {
        let config = SyncConfiguration()
        config.filePathMappings = [
            SyncConfiguration.FileMapping(filePath: "Projects/Work.md", remindersList: "Work Projects"),
        ]
        config.defaultList = "Inbox"

        // No tag → file mapping should match
        let result = config.resolveTargetList(tag: nil, filePath: "Projects/Work.md")
        XCTAssertEqual(result, "Work Projects")
    }

    func testResolveTargetListFileMappingNoTag() {
        let config = SyncConfiguration()
        config.filePathMappings = [
            SyncConfiguration.FileMapping(filePath: "Shopping.md", remindersList: "Groceries"),
        ]
        config.defaultList = "Inbox"

        // Untagged task in a mapped file
        let result = config.resolveTargetList(tag: "", filePath: "Shopping.md")
        XCTAssertEqual(result, "Groceries")
    }

    func testResolveTargetListFallsBackToDefault() {
        let config = SyncConfiguration()
        config.defaultList = "Inbox"

        let result = config.resolveTargetList(tag: nil, filePath: "Random/File.md")
        XCTAssertEqual(result, "Inbox")
    }

    func testResolveTargetListAutoCapitalizeTag() {
        let config = SyncConfiguration()
        config.defaultList = "Inbox"

        // No explicit mapping, no file mapping → auto-capitalize
        let result = config.resolveTargetList(tag: "family", filePath: nil)
        XCTAssertEqual(result, "Family")
    }

    func testFileMappingEncodeDecode() {
        let config = SyncConfiguration()
        config.filePathMappings = [
            SyncConfiguration.FileMapping(filePath: "Work/Tasks.md", remindersList: "Work"),
            SyncConfiguration.FileMapping(filePath: "Personal/Todo.md", remindersList: "Personal"),
        ]

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(config) else {
            XCTFail("Failed to encode config with file mappings")
            return
        }

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(SyncConfiguration.self, from: data) else {
            XCTFail("Failed to decode config with file mappings")
            return
        }

        XCTAssertEqual(decoded.filePathMappings.count, 2)
        XCTAssertEqual(decoded.filePathMappings[0].filePath, "Work/Tasks.md")
        XCTAssertEqual(decoded.filePathMappings[0].remindersList, "Work")
        XCTAssertEqual(decoded.filePathMappings[1].filePath, "Personal/Todo.md")
        XCTAssertEqual(decoded.filePathMappings[1].remindersList, "Personal")
    }

    func testFileMappingBackwardCompatibility() {
        // Config without filePathMappings should decode with empty array
        let json = """
        {
            "vaultPath": "/test",
            "syncIntervalMinutes": 5,
            "enableAutoSync": true,
            "syncOnLaunch": true,
            "listMappings": [],
            "defaultList": "Reminders",
            "taskFilesPattern": "*.md",
            "excludedFolders": [".obsidian"],
            "syncCompletedTasks": false,
            "conflictResolution": "obsidian",
            "includeDueTime": false,
            "hideDockIcon": false,
            "forceDarkIcon": false,
            "dryRunMode": false,
            "enableCompletionWriteback": true,
            "enableDueDateWriteback": false,
            "enableStartDateWriteback": false,
            "enablePriorityWriteback": false,
            "enableNewTaskWriteback": false,
            "inboxFilePath": "Inbox.md",
            "enableFileWatcher": false,
            "enableNotifications": true,
            "globalHotKeyEnabled": false,
            "globalHotKeyCode": 1,
            "globalHotKeyModifiers": 3328
        }
        """.data(using: .utf8)!

        let config = try? JSONDecoder().decode(SyncConfiguration.self, from: json)
        XCTAssertNotNil(config)
        XCTAssertTrue(config!.filePathMappings.isEmpty)
        XCTAssertTrue(config!.folderPathMappings.isEmpty)
        XCTAssertFalse(config!.enableDataviewFormat)
    }

    // MARK: - Folder Path Mapping (#40)

    func testResolveTargetListFolderMapping() {
        let config = SyncConfiguration()
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Projects/Work", remindersList: "Work Tasks"),
        ]
        config.defaultList = "Inbox"

        // File inside mapped folder
        let result = config.resolveTargetList(tag: nil, filePath: "Projects/Work/task-list.md")
        XCTAssertEqual(result, "Work Tasks")
    }

    func testResolveTargetListFolderMappingNested() {
        let config = SyncConfiguration()
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Projects/Work", remindersList: "Work Tasks"),
        ]
        config.defaultList = "Inbox"

        // Deeply nested file inside mapped folder
        let result = config.resolveTargetList(tag: nil, filePath: "Projects/Work/Clients/Acme/tasks.md")
        XCTAssertEqual(result, "Work Tasks")
    }

    func testResolveTargetListFolderMappingSpecificWins() {
        let config = SyncConfiguration()
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Projects", remindersList: "All Projects"),
            SyncConfiguration.FolderMapping(folderPath: "Projects/Work", remindersList: "Work Tasks"),
        ]
        config.defaultList = "Inbox"

        // More specific folder mapping should win
        let result = config.resolveTargetList(tag: nil, filePath: "Projects/Work/task.md")
        XCTAssertEqual(result, "Work Tasks")

        // Broader mapping for non-matching subfolder
        let result2 = config.resolveTargetList(tag: nil, filePath: "Projects/Personal/task.md")
        XCTAssertEqual(result2, "All Projects")
    }

    func testResolveTargetListFileMappingBeatsFolder() {
        let config = SyncConfiguration()
        config.filePathMappings = [
            SyncConfiguration.FileMapping(filePath: "Projects/Work/special.md", remindersList: "Special"),
        ]
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Projects/Work", remindersList: "Work Tasks"),
        ]
        config.defaultList = "Inbox"

        // File mapping should beat folder mapping
        let result = config.resolveTargetList(tag: nil, filePath: "Projects/Work/special.md")
        XCTAssertEqual(result, "Special")

        // Non-matching file still falls through to folder mapping
        let result2 = config.resolveTargetList(tag: nil, filePath: "Projects/Work/other.md")
        XCTAssertEqual(result2, "Work Tasks")
    }

    func testFolderMappingEncodeDecode() {
        let config = SyncConfiguration()
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Work", remindersList: "Work"),
            SyncConfiguration.FolderMapping(folderPath: "Personal/Family", remindersList: "Family"),
        ]

        guard let data = try? JSONEncoder().encode(config) else {
            XCTFail("Failed to encode config with folder mappings")
            return
        }

        guard let decoded = try? JSONDecoder().decode(SyncConfiguration.self, from: data) else {
            XCTFail("Failed to decode config with folder mappings")
            return
        }

        XCTAssertEqual(decoded.folderPathMappings.count, 2)
        XCTAssertEqual(decoded.folderPathMappings[0].folderPath, "Work")
        XCTAssertEqual(decoded.folderPathMappings[0].remindersList, "Work")
        XCTAssertEqual(decoded.folderPathMappings[1].folderPath, "Personal/Family")
        XCTAssertEqual(decoded.folderPathMappings[1].remindersList, "Family")
    }

    func testResolveTargetListFolderMappingNoMatch() {
        let config = SyncConfiguration()
        config.folderPathMappings = [
            SyncConfiguration.FolderMapping(folderPath: "Projects/Work", remindersList: "Work Tasks"),
        ]
        config.defaultList = "Inbox"

        // File NOT inside mapped folder
        let result = config.resolveTargetList(tag: nil, filePath: "Notes/random.md")
        XCTAssertEqual(result, "Inbox")
    }
}
