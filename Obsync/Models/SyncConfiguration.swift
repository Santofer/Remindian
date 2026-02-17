import Foundation
import SwiftUI

/// Configuration for the sync behavior
class SyncConfiguration: ObservableObject, Codable {
    @Published var vaultPath: String
    @Published var syncIntervalMinutes: Int
    @Published var enableAutoSync: Bool
    @Published var syncOnLaunch: Bool
    @Published var listMappings: [ListMapping]
    @Published var defaultList: String
    @Published var taskFilesPattern: String
    @Published var excludedFolders: [String]
    @Published var includedFolders: [String]  // Whitelist: if non-empty, ONLY scan these folders
    @Published var syncCompletedTasks: Bool
    @Published var deleteCompletedAfterDays: Int?
    @Published var conflictResolution: ConflictResolution
    @Published var includeDueTime: Bool
    @Published var hideDockIcon: Bool
    @Published var forceDarkIcon: Bool
    @Published var dryRunMode: Bool
    @Published var enableCompletionWriteback: Bool
    @Published var enableDueDateWriteback: Bool
    @Published var enableStartDateWriteback: Bool
    @Published var enablePriorityWriteback: Bool
    @Published var enableNewTaskWriteback: Bool
    @Published var inboxFilePath: String
    @Published var enableFileWatcher: Bool
    @Published var enableNotifications: Bool
    @Published var globalHotKeyEnabled: Bool
    @Published var globalHotKeyCode: UInt32
    @Published var globalHotKeyModifiers: UInt32

    // MARK: - Source & Destination Selection
    @Published var taskSourceType: TaskSourceType
    @Published var taskDestinationType: TaskDestinationType
    @Published var things3AuthToken: String
    @Published var taskNotesFolder: String  // Relative path within vault (e.g., "tasks")
    @Published var taskNotesIntegrationMode: String  // "cli", "file", or "http"
    @Published var taskNotesApiPort: Int

    enum TaskSourceType: String, Codable, CaseIterable {
        case obsidianTasks = "obsidianTasks"
        case taskNotes = "taskNotes"

        var displayName: String {
            switch self {
            case .obsidianTasks: return "Obsidian Tasks"
            case .taskNotes: return "TaskNotes"
            }
        }
    }

    enum TaskDestinationType: String, Codable, CaseIterable {
        case appleReminders = "appleReminders"
        case things3 = "things3"

        var displayName: String {
            switch self {
            case .appleReminders: return "Apple Reminders"
            case .things3: return "Things 3"
            }
        }
    }

    struct ListMapping: Codable, Identifiable, Equatable {
        var id = UUID()
        var obsidianTag: String
        var remindersList: String
    }

    enum ConflictResolution: String, Codable, CaseIterable {
        case obsidianWins = "obsidian"

        var displayName: String {
            switch self {
            case .obsidianWins: return "Obsidian is source of truth"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case vaultPath, syncIntervalMinutes, enableAutoSync, syncOnLaunch
        case listMappings, defaultList, taskFilesPattern, excludedFolders, includedFolders
        case syncCompletedTasks, deleteCompletedAfterDays, conflictResolution
        case includeDueTime, hideDockIcon, forceDarkIcon, dryRunMode, enableCompletionWriteback
        case enableDueDateWriteback, enableStartDateWriteback, enablePriorityWriteback
        case enableNewTaskWriteback, inboxFilePath, enableFileWatcher
        case enableNotifications, globalHotKeyEnabled, globalHotKeyCode, globalHotKeyModifiers
        case taskSourceType, taskDestinationType, things3AuthToken, taskNotesFolder, taskNotesIntegrationMode
        case taskNotesApiPort
        case taskNotesApiBaseUrl  // Legacy key for migration from URL-based setting
    }

    init(
        vaultPath: String = "",
        syncIntervalMinutes: Int = 5,
        enableAutoSync: Bool = true,
        syncOnLaunch: Bool = true,
        listMappings: [ListMapping] = [],
        defaultList: String = "Reminders",
        taskFilesPattern: String = "**/*.md",
        excludedFolders: [String] = [".obsidian", ".git", ".trash"],
        includedFolders: [String] = [],
        syncCompletedTasks: Bool = true,
        deleteCompletedAfterDays: Int? = nil,
        conflictResolution: ConflictResolution = .obsidianWins,
        includeDueTime: Bool = false,
        hideDockIcon: Bool = false,
        dryRunMode: Bool = false,
        enableCompletionWriteback: Bool = true,
        enableDueDateWriteback: Bool = false,
        enableStartDateWriteback: Bool = false,
        enablePriorityWriteback: Bool = false,
        enableNewTaskWriteback: Bool = false,
        inboxFilePath: String = "Inbox.md",
        enableFileWatcher: Bool = false,
        enableNotifications: Bool = true,
        forceDarkIcon: Bool = false,
        globalHotKeyEnabled: Bool = false,
        globalHotKeyCode: UInt32 = 1, // kVK_ANSI_S
        globalHotKeyModifiers: UInt32 = 0x0D00, // cmd + shift + option
        taskSourceType: TaskSourceType = .obsidianTasks,
        taskDestinationType: TaskDestinationType = .appleReminders,
        things3AuthToken: String = "",
        taskNotesFolder: String = "",
        taskNotesIntegrationMode: String = "cli",
        taskNotesApiPort: Int = 8080
    ) {
        self.vaultPath = vaultPath
        self.syncIntervalMinutes = syncIntervalMinutes
        self.enableAutoSync = enableAutoSync
        self.syncOnLaunch = syncOnLaunch
        self.listMappings = listMappings
        self.defaultList = defaultList
        self.taskFilesPattern = taskFilesPattern
        self.excludedFolders = excludedFolders
        self.includedFolders = includedFolders
        self.syncCompletedTasks = syncCompletedTasks
        self.deleteCompletedAfterDays = deleteCompletedAfterDays
        self.conflictResolution = conflictResolution
        self.includeDueTime = includeDueTime
        self.hideDockIcon = hideDockIcon
        self.forceDarkIcon = forceDarkIcon
        self.dryRunMode = dryRunMode
        self.enableCompletionWriteback = enableCompletionWriteback
        self.enableDueDateWriteback = enableDueDateWriteback
        self.enableStartDateWriteback = enableStartDateWriteback
        self.enablePriorityWriteback = enablePriorityWriteback
        self.enableNewTaskWriteback = enableNewTaskWriteback
        self.inboxFilePath = inboxFilePath
        self.enableFileWatcher = enableFileWatcher
        self.enableNotifications = enableNotifications
        self.globalHotKeyEnabled = globalHotKeyEnabled
        self.globalHotKeyCode = globalHotKeyCode
        self.globalHotKeyModifiers = globalHotKeyModifiers
        self.taskSourceType = taskSourceType
        self.taskDestinationType = taskDestinationType
        self.things3AuthToken = things3AuthToken
        self.taskNotesFolder = taskNotesFolder
        self.taskNotesIntegrationMode = taskNotesIntegrationMode
        self.taskNotesApiPort = taskNotesApiPort
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vaultPath = try container.decode(String.self, forKey: .vaultPath)
        syncIntervalMinutes = try container.decode(Int.self, forKey: .syncIntervalMinutes)
        enableAutoSync = try container.decode(Bool.self, forKey: .enableAutoSync)
        syncOnLaunch = try container.decode(Bool.self, forKey: .syncOnLaunch)
        listMappings = try container.decode([ListMapping].self, forKey: .listMappings)
        defaultList = try container.decode(String.self, forKey: .defaultList)
        taskFilesPattern = try container.decode(String.self, forKey: .taskFilesPattern)
        excludedFolders = try container.decode([String].self, forKey: .excludedFolders)
        includedFolders = try container.decodeIfPresent([String].self, forKey: .includedFolders) ?? []
        syncCompletedTasks = try container.decode(Bool.self, forKey: .syncCompletedTasks)
        deleteCompletedAfterDays = try container.decodeIfPresent(Int.self, forKey: .deleteCompletedAfterDays)
        conflictResolution = try container.decode(ConflictResolution.self, forKey: .conflictResolution)
        includeDueTime = try container.decodeIfPresent(Bool.self, forKey: .includeDueTime) ?? false
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        forceDarkIcon = try container.decodeIfPresent(Bool.self, forKey: .forceDarkIcon) ?? false
        dryRunMode = try container.decodeIfPresent(Bool.self, forKey: .dryRunMode) ?? false
        enableCompletionWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableCompletionWriteback) ?? true
        enableDueDateWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableDueDateWriteback) ?? false
        enableStartDateWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableStartDateWriteback) ?? false
        enablePriorityWriteback = try container.decodeIfPresent(Bool.self, forKey: .enablePriorityWriteback) ?? false
        enableNewTaskWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableNewTaskWriteback) ?? false
        inboxFilePath = try container.decodeIfPresent(String.self, forKey: .inboxFilePath) ?? "Inbox.md"
        enableFileWatcher = try container.decodeIfPresent(Bool.self, forKey: .enableFileWatcher) ?? false
        enableNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableNotifications) ?? true
        globalHotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalHotKeyEnabled) ?? false
        globalHotKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .globalHotKeyCode) ?? 1
        globalHotKeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .globalHotKeyModifiers) ?? 0x0D00
        taskSourceType = try container.decodeIfPresent(TaskSourceType.self, forKey: .taskSourceType) ?? .obsidianTasks
        taskDestinationType = try container.decodeIfPresent(TaskDestinationType.self, forKey: .taskDestinationType) ?? .appleReminders
        things3AuthToken = try container.decodeIfPresent(String.self, forKey: .things3AuthToken) ?? ""
        taskNotesFolder = try container.decodeIfPresent(String.self, forKey: .taskNotesFolder) ?? ""
        taskNotesIntegrationMode = try container.decodeIfPresent(String.self, forKey: .taskNotesIntegrationMode) ?? "cli"
        if let decodedPort = try container.decodeIfPresent(Int.self, forKey: .taskNotesApiPort),
           (1...65535).contains(decodedPort) {
            taskNotesApiPort = decodedPort
        } else if
            let legacyApiBaseUrl = try container.decodeIfPresent(String.self, forKey: .taskNotesApiBaseUrl),
            let url = URL(string: legacyApiBaseUrl),
            let legacyPort = url.port,
            (1...65535).contains(legacyPort) {
            taskNotesApiPort = legacyPort
        } else {
            taskNotesApiPort = 8080
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vaultPath, forKey: .vaultPath)
        try container.encode(syncIntervalMinutes, forKey: .syncIntervalMinutes)
        try container.encode(enableAutoSync, forKey: .enableAutoSync)
        try container.encode(syncOnLaunch, forKey: .syncOnLaunch)
        try container.encode(listMappings, forKey: .listMappings)
        try container.encode(defaultList, forKey: .defaultList)
        try container.encode(taskFilesPattern, forKey: .taskFilesPattern)
        try container.encode(excludedFolders, forKey: .excludedFolders)
        try container.encode(includedFolders, forKey: .includedFolders)
        try container.encode(syncCompletedTasks, forKey: .syncCompletedTasks)
        try container.encode(deleteCompletedAfterDays, forKey: .deleteCompletedAfterDays)
        try container.encode(conflictResolution, forKey: .conflictResolution)
        try container.encode(includeDueTime, forKey: .includeDueTime)
        try container.encode(hideDockIcon, forKey: .hideDockIcon)
        try container.encode(forceDarkIcon, forKey: .forceDarkIcon)
        try container.encode(dryRunMode, forKey: .dryRunMode)
        try container.encode(enableCompletionWriteback, forKey: .enableCompletionWriteback)
        try container.encode(enableDueDateWriteback, forKey: .enableDueDateWriteback)
        try container.encode(enableStartDateWriteback, forKey: .enableStartDateWriteback)
        try container.encode(enablePriorityWriteback, forKey: .enablePriorityWriteback)
        try container.encode(enableNewTaskWriteback, forKey: .enableNewTaskWriteback)
        try container.encode(inboxFilePath, forKey: .inboxFilePath)
        try container.encode(enableFileWatcher, forKey: .enableFileWatcher)
        try container.encode(enableNotifications, forKey: .enableNotifications)
        try container.encode(globalHotKeyEnabled, forKey: .globalHotKeyEnabled)
        try container.encode(globalHotKeyCode, forKey: .globalHotKeyCode)
        try container.encode(globalHotKeyModifiers, forKey: .globalHotKeyModifiers)
        try container.encode(taskSourceType, forKey: .taskSourceType)
        try container.encode(taskDestinationType, forKey: .taskDestinationType)
        try container.encode(things3AuthToken, forKey: .things3AuthToken)
        try container.encode(taskNotesFolder, forKey: .taskNotesFolder)
        try container.encode(taskNotesIntegrationMode, forKey: .taskNotesIntegrationMode)
        try container.encode(taskNotesApiPort, forKey: .taskNotesApiPort)
    }

    // MARK: - Persistence

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("Remindian", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("config.json")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.configURL)
        } catch {
            print("Failed to save configuration: \(error)")
        }
    }

    static func load() -> SyncConfiguration {
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(SyncConfiguration.self, from: data)
        } catch {
            return SyncConfiguration()
        }
    }

    // MARK: - Helpers

    /// Map an Obsidian tag to a Reminders list name.
    /// Priority: 1) Explicit mapping from settings, 2) Auto-map by capitalizing the tag name.
    /// Falls back to defaultList only if the tag is empty.
    func remindersListForTag(_ tag: String) -> String {
        let cleanTag = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        guard !cleanTag.isEmpty else { return defaultList }

        // 1. Check explicit mappings first
        if let mapping = listMappings.first(where: { $0.obsidianTag.lowercased() == cleanTag.lowercased() }) {
            return mapping.remindersList
        }

        // 2. Auto-map: capitalize first letter (e.g., "work" → "Work", "family" → "Family")
        return cleanTag.prefix(1).uppercased() + cleanTag.dropFirst()
    }

    func obsidianTagForList(_ listName: String) -> String? {
        return listMappings.first { $0.remindersList.lowercased() == listName.lowercased() }?.obsidianTag
    }
}
