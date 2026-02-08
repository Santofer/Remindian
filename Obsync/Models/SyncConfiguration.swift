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
    @Published var syncCompletedTasks: Bool
    @Published var deleteCompletedAfterDays: Int?
    @Published var conflictResolution: ConflictResolution
    @Published var includeDueTime: Bool
    @Published var hideDockIcon: Bool
    @Published var forceDarkIcon: Bool
    @Published var dryRunMode: Bool
    @Published var enableCompletionWriteback: Bool
    @Published var enableNotifications: Bool
    @Published var globalHotKeyEnabled: Bool
    @Published var globalHotKeyCode: UInt32
    @Published var globalHotKeyModifiers: UInt32

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
        case listMappings, defaultList, taskFilesPattern, excludedFolders
        case syncCompletedTasks, deleteCompletedAfterDays, conflictResolution
        case includeDueTime, hideDockIcon, forceDarkIcon, dryRunMode, enableCompletionWriteback
        case enableNotifications, globalHotKeyEnabled, globalHotKeyCode, globalHotKeyModifiers
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
        syncCompletedTasks: Bool = true,
        deleteCompletedAfterDays: Int? = nil,
        conflictResolution: ConflictResolution = .obsidianWins,
        includeDueTime: Bool = false,
        hideDockIcon: Bool = false,
        dryRunMode: Bool = false,
        enableCompletionWriteback: Bool = true,
        enableNotifications: Bool = true,
        forceDarkIcon: Bool = false,
        globalHotKeyEnabled: Bool = false,
        globalHotKeyCode: UInt32 = 1, // kVK_ANSI_S
        globalHotKeyModifiers: UInt32 = 0x0D00 // cmd + shift + option
    ) {
        self.vaultPath = vaultPath
        self.syncIntervalMinutes = syncIntervalMinutes
        self.enableAutoSync = enableAutoSync
        self.syncOnLaunch = syncOnLaunch
        self.listMappings = listMappings
        self.defaultList = defaultList
        self.taskFilesPattern = taskFilesPattern
        self.excludedFolders = excludedFolders
        self.syncCompletedTasks = syncCompletedTasks
        self.deleteCompletedAfterDays = deleteCompletedAfterDays
        self.conflictResolution = conflictResolution
        self.includeDueTime = includeDueTime
        self.hideDockIcon = hideDockIcon
        self.forceDarkIcon = forceDarkIcon
        self.dryRunMode = dryRunMode
        self.enableCompletionWriteback = enableCompletionWriteback
        self.enableNotifications = enableNotifications
        self.globalHotKeyEnabled = globalHotKeyEnabled
        self.globalHotKeyCode = globalHotKeyCode
        self.globalHotKeyModifiers = globalHotKeyModifiers
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
        syncCompletedTasks = try container.decode(Bool.self, forKey: .syncCompletedTasks)
        deleteCompletedAfterDays = try container.decodeIfPresent(Int.self, forKey: .deleteCompletedAfterDays)
        conflictResolution = try container.decode(ConflictResolution.self, forKey: .conflictResolution)
        includeDueTime = try container.decodeIfPresent(Bool.self, forKey: .includeDueTime) ?? false
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        forceDarkIcon = try container.decodeIfPresent(Bool.self, forKey: .forceDarkIcon) ?? false
        dryRunMode = try container.decodeIfPresent(Bool.self, forKey: .dryRunMode) ?? false
        enableCompletionWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableCompletionWriteback) ?? true
        enableNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableNotifications) ?? true
        globalHotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalHotKeyEnabled) ?? false
        globalHotKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .globalHotKeyCode) ?? 1
        globalHotKeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .globalHotKeyModifiers) ?? 0x0D00
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
        try container.encode(syncCompletedTasks, forKey: .syncCompletedTasks)
        try container.encode(deleteCompletedAfterDays, forKey: .deleteCompletedAfterDays)
        try container.encode(conflictResolution, forKey: .conflictResolution)
        try container.encode(includeDueTime, forKey: .includeDueTime)
        try container.encode(hideDockIcon, forKey: .hideDockIcon)
        try container.encode(forceDarkIcon, forKey: .forceDarkIcon)
        try container.encode(dryRunMode, forKey: .dryRunMode)
        try container.encode(enableCompletionWriteback, forKey: .enableCompletionWriteback)
        try container.encode(enableNotifications, forKey: .enableNotifications)
        try container.encode(globalHotKeyEnabled, forKey: .globalHotKeyEnabled)
        try container.encode(globalHotKeyCode, forKey: .globalHotKeyCode)
        try container.encode(globalHotKeyModifiers, forKey: .globalHotKeyModifiers)
    }

    // MARK: - Persistence

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("Obsync", isDirectory: true)
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
