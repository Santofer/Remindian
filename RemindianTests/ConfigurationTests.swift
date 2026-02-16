import XCTest
@testable import Remindian

final class ConfigurationTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultConfiguration() {
        let config = SyncConfiguration()

        XCTAssertEqual(config.vaultPath, "")
        XCTAssertEqual(config.syncIntervalMinutes, 5)
        XCTAssertTrue(config.enableAutoSync)
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
}
