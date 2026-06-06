import Foundation
import SwiftUI

/// Configurable YAML field name mapping for TaskNotes (#19).
/// Lets users specify which frontmatter field names map to Remindian properties.
struct TaskNotesFieldMapping: Codable, Equatable {
    var title: String = "title"
    var status: String = "status"
    var priority: String = "priority"
    var due: String = "due"
    var scheduled: String = "scheduled"
    var completedDate: String = "completedDate"
    var tags: String = "tags"
    var project: String = "project"
    var context: String = "context"

    /// Returns all custom field names as a lookup dictionary (lowercased key → property name).
    var fieldLookup: [String: String] {
        return [
            title.lowercased(): "title",
            status.lowercased(): "status",
            priority.lowercased(): "priority",
            due.lowercased(): "due",
            scheduled.lowercased(): "scheduled",
            completedDate.lowercased(): "completedDate",
            tags.lowercased(): "tags",
            project.lowercased(): "project",
            context.lowercased(): "context",
        ]
    }
}

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
    @Published var enableTagWriteback: Bool
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
    @Published var taskNotesMtnPath: String  // User-configured path to mtn binary
    @Published var taskNotesApiUrl: String  // HTTP API base URL (e.g., http://localhost:8080)
    @Published var launchAtLogin: Bool
    @Published var maxCompletedTaskAgeDays: Int  // 0 = no limit, >0 = skip completed tasks older than N days
    @Published var syncedRemindersLists: [String]  // Empty = sync all lists, non-empty = only these lists
    @Published var excludedRemindersLists: [String]  // Lists to always exclude from sync (e.g., Groceries)
    @Published var addTaskLinkToReminders: Bool  // Add obsidian:// link to Reminders URL field
    // Whether to ALSO append the obsidian:// URL into the reminder's notes
    // body. Pre-v5.10 always did this as a "fallback for clients that don't
    // show the URL field" — but Apple Reminders on macOS/iOS displays the URL
    // field as a clean clickable Obsidian icon, and the long percent-encoded
    // URL in notes was just visual clutter (#69). Defaults to `false`, so
    // existing users get the cleaner display on their next sync; users who
    // still want the notes-side fallback (e.g. for older clients) can re-enable.
    @Published var appendTaskLinkToNotes: Bool

    /// Where the sync-state mapping table is stored. (#15) See `SyncStateLocation`.
    @Published var syncStateLocation: SyncStateLocation

    /// Token dialect for the Generic Markdown source (#27). See `GenericMarkdownSettings`.
    @Published var genericMarkdown: GenericMarkdownSettings

    // MARK: - TaskNotes Custom Status Mapping (#10)
    @Published var taskNotesCompletedStatuses: [String]  // Statuses that mean "completed" (e.g., ["done", "completed", "cancelled"])
    @Published var taskNotesOpenStatus: String  // Status to write when marking incomplete (default: "open")
    @Published var taskNotesDoneStatus: String  // Status to write when marking complete (default: "done")

    // MARK: - Obsidian Tasks Custom Status Markers (#63)
    //
    // Single-character markers inside the checkbox brackets that classify a
    // task as "open" or "completed". Mirrors the TaskNotes status mapping above.
    //
    // Default `[" "]` open / `["x", "X"]` completed matches the v5.8.x
    // behavior exactly — existing users see no change. Users with the
    // Obsidian Task-Board plugin can add `/`, `?`, `<` for "in progress",
    // "waiting", "ready", and `-` for "cancelled" (typically mapped to
    // completed). Each entry must be a single character.
    @Published var obsidianTasksOpenMarkers: [String]
    @Published var obsidianTasksCompletedMarkers: [String]
    // Markers that mean "this isn't a task at all — ignore the entire line".
    // Used by plugin patterns like `[i]` for informational entries that look
    // like checkbox lines but shouldn't sync as reminders (#70). Default empty
    // — backwards-compatible. If a marker appears in both this list and one
    // of the open/completed lists, ignored wins (safer default — see the
    // tests in V5_10_1_IgnoredMarkersTests).
    @Published var obsidianTasksIgnoredMarkers: [String]

    // MARK: - TaskNotes Field Mapping (#19)
    @Published var taskNotesFieldMapping: TaskNotesFieldMapping  // Map YAML field names to Remindian properties

    // MARK: - TaskNotes List Field (#20)
    @Published var taskNotesListField: String  // Which field determines Reminders list ("tags", "project", "context", or custom)

    // MARK: - File Path Mappings (#37)
    @Published var filePathMappings: [FileMapping]  // Map specific files to specific destination lists

    // MARK: - Folder Path Mappings (#40)
    @Published var folderPathMappings: [FolderMapping]  // Map entire folders to specific destination lists

    // MARK: - Dataview Inline Fields (#41)
    @Published var enableDataviewFormat: Bool  // Also parse [key::value] inline fields from tasks

    // MARK: - Tag Exclusion (#47)
    @Published var excludedTags: [String]  // Tags to exclude from sync (e.g., ["Routine", "SomeDay"])

    // MARK: - Global Filter (#36)
    @Published var globalFilter: String  // Text that must appear in the file/section for tasks to be synced (e.g., "#task" for Obsidian Tasks global filter)

    // MARK: - Todoist
    @Published var todoistApiToken: String

    // MARK: - TickTick (OAuth)
    @Published var tickTickAccessToken: String
    @Published var tickTickRefreshToken: String
    @Published var tickTickTokenExpiry: Date?

    // MARK: - Asana
    @Published var asanaApiToken: String

    // MARK: - Linear
    @Published var linearApiKey: String

    // MARK: - Calendar Feed (.ics)
    @Published var calendarFeedOutputPath: String
    @Published var calendarFeedName: String

    enum TaskSourceType: String, Codable, CaseIterable {
        case obsidianTasks = "obsidianTasks"
        case taskNotes = "taskNotes"
        case genericMarkdown = "genericMarkdown"

        var displayName: String {
            switch self {
            case .obsidianTasks: return "Obsidian Tasks"
            case .taskNotes: return "TaskNotes"
            case .genericMarkdown: return "Generic Markdown (NotePlan, etc.)"
            }
        }
    }

    /// Configurable token dialect for the Generic Markdown source (#27).
    ///
    /// Lets Remindian read plain-markdown task tools that aren't Obsidian Tasks
    /// — NotePlan, and any tool that puts dates/priority on the task line with a
    /// configurable prefix. Defaults match NotePlan: due `>2025-01-20`, done
    /// `@done(2025-01-20)`, priority `!`, `!!`, `!!!`. Empty token = that field
    /// is disabled (not parsed, not written).
    ///
    /// Date tokens accept both bare (`>2025-01-20`) and parenthesized
    /// (`@done(2025-01-20)`) forms, so one model covers both styles.
    ///
    /// This is intentionally separate from the Obsidian-Tasks emoji parser: the
    /// proven Obsidian path is untouched, so adding dialect support carries no
    /// regression risk for existing users. Recurrence is not parsed in this
    /// dialect (varies too much between tools); completion, dates, priority and
    /// new-task writeback are supported.
    struct GenericMarkdownSettings: Codable, Equatable {
        var fileExtensions: [String]
        var openMarkers: [String]
        var completedMarkers: [String]
        var dueToken: String
        var startToken: String
        var scheduledToken: String
        var doneToken: String
        var priorityHighToken: String
        var priorityMediumToken: String
        var priorityLowToken: String

        init(
            fileExtensions: [String] = ["md", "txt"],
            openMarkers: [String] = [" "],
            completedMarkers: [String] = ["x", "X"],
            dueToken: String = ">",
            startToken: String = "",
            scheduledToken: String = "",
            doneToken: String = "@done",
            priorityHighToken: String = "!!!",
            priorityMediumToken: String = "!!",
            priorityLowToken: String = "!"
        ) {
            self.fileExtensions = fileExtensions
            self.openMarkers = openMarkers
            self.completedMarkers = completedMarkers
            self.dueToken = dueToken
            self.startToken = startToken
            self.scheduledToken = scheduledToken
            self.doneToken = doneToken
            self.priorityHighToken = priorityHighToken
            self.priorityMediumToken = priorityMediumToken
            self.priorityLowToken = priorityLowToken
        }
    }

    enum TaskDestinationType: String, Codable, CaseIterable {
        case appleReminders = "appleReminders"
        case things3 = "things3"
        case todoist = "todoist"
        case tickTick = "tickTick"
        case asana = "asana"
        case linear = "linear"
        case calendarFeed = "calendarFeed"

        var displayName: String {
            switch self {
            case .appleReminders: return "Apple Reminders"
            case .things3: return "Things 3"
            case .todoist: return "Todoist"
            case .tickTick: return "TickTick"
            case .asana: return "Asana"
            case .linear: return "Linear"
            case .calendarFeed: return "Calendar Feed (.ics)"
            }
        }
    }

    struct ListMapping: Codable, Identifiable, Equatable {
        var id = UUID()
        var obsidianTag: String
        var remindersList: String
    }

    struct FileMapping: Codable, Identifiable, Equatable {
        var id = UUID()
        var filePath: String        // Relative path within vault (e.g., "Projects/Work.md")
        var remindersList: String
    }

    struct FolderMapping: Codable, Identifiable, Equatable {
        var id = UUID()
        var folderPath: String      // Relative folder path within vault (e.g., "Projects/Work")
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

    /// Where `sync_state.json` (the Obsidian↔destination mapping table) is
    /// stored. (#15)
    ///
    /// - `.applicationSupport` (default): `~/Library/Application Support/Remindian`.
    ///   Per-machine — each Mac keeps its own mappings. The original behavior.
    /// - `.vault`: `<vault>/.remindian/sync_state.json`. Because the state file
    ///   lives inside the vault, whatever the user already uses to sync the
    ///   vault across machines (Obsidian Sync, iCloud Drive, Dropbox, git…)
    ///   also carries the mappings — so a second Mac reuses the existing
    ///   reminders instead of recreating duplicates. Requires no extra
    ///   entitlement: the app already writes task files into the vault.
    ///
    /// iCloud-container storage is intentionally NOT offered: it needs a paid
    /// Apple Developer membership and a provisioned ubiquity container, which
    /// can't be tested/shipped reliably right now. The `.vault` option achieves
    /// the same multi-device outcome through the user's existing vault sync.
    enum SyncStateLocation: String, Codable, CaseIterable {
        case applicationSupport = "appSupport"
        case vault

        var displayName: String {
            switch self {
            case .applicationSupport: return "Application Support (this Mac only)"
            case .vault: return "Inside vault (.remindian — shared across devices)"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case vaultPath, syncIntervalMinutes, enableAutoSync, syncOnLaunch
        case listMappings, defaultList, taskFilesPattern, excludedFolders, includedFolders
        case syncCompletedTasks, deleteCompletedAfterDays, conflictResolution
        case includeDueTime, hideDockIcon, forceDarkIcon, dryRunMode, enableCompletionWriteback
        case enableDueDateWriteback, enableStartDateWriteback, enablePriorityWriteback
        case enableNewTaskWriteback, enableTagWriteback, inboxFilePath, enableFileWatcher
        case enableNotifications, globalHotKeyEnabled, globalHotKeyCode, globalHotKeyModifiers
        case taskSourceType, taskDestinationType, things3AuthToken, taskNotesFolder, taskNotesIntegrationMode
        case taskNotesMtnPath, taskNotesApiUrl
        case launchAtLogin, maxCompletedTaskAgeDays, syncedRemindersLists, excludedRemindersLists, addTaskLinkToReminders, appendTaskLinkToNotes
        case syncStateLocation, genericMarkdown
        case taskNotesCompletedStatuses, taskNotesOpenStatus, taskNotesDoneStatus
        case obsidianTasksOpenMarkers, obsidianTasksCompletedMarkers, obsidianTasksIgnoredMarkers
        case taskNotesFieldMapping, taskNotesListField
        case filePathMappings
        case folderPathMappings
        case enableDataviewFormat
        case excludedTags
        case globalFilter
        case todoistApiToken
        case tickTickAccessToken, tickTickRefreshToken, tickTickTokenExpiry
        case asanaApiToken
        case linearApiKey
        case calendarFeedOutputPath, calendarFeedName
    }

    init(
        vaultPath: String = "",
        syncIntervalMinutes: Int = 5,
        // Default OFF so a fresh install doesn't start mass-creating destination
        // tasks before the user has reviewed mappings (#62.4). Existing users
        // keep whatever they had persisted in their config — only fresh installs
        // (or the in-memory default before first save) pick up the new default.
        enableAutoSync: Bool = false,
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
        enableTagWriteback: Bool = false,
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
        taskNotesMtnPath: String = "",
        taskNotesApiUrl: String = "http://localhost:8080",
        launchAtLogin: Bool = false,
        maxCompletedTaskAgeDays: Int = 0,
        syncedRemindersLists: [String] = [],
        excludedRemindersLists: [String] = [],
        excludedTags: [String] = [],
        addTaskLinkToReminders: Bool = true,
        appendTaskLinkToNotes: Bool = false,
        syncStateLocation: SyncStateLocation = .applicationSupport,
        genericMarkdown: GenericMarkdownSettings = GenericMarkdownSettings(),
        taskNotesCompletedStatuses: [String] = ["done", "completed", "cancelled"],
        taskNotesOpenStatus: String = "open",
        taskNotesDoneStatus: String = "done",
        obsidianTasksOpenMarkers: [String] = [" "],
        obsidianTasksCompletedMarkers: [String] = ["x", "X"],
        obsidianTasksIgnoredMarkers: [String] = [],
        taskNotesFieldMapping: TaskNotesFieldMapping = TaskNotesFieldMapping(),
        taskNotesListField: String = "tags",
        filePathMappings: [FileMapping] = [],
        folderPathMappings: [FolderMapping] = [],
        enableDataviewFormat: Bool = false,
        globalFilter: String = "",
        todoistApiToken: String = "",
        tickTickAccessToken: String = "",
        tickTickRefreshToken: String = "",
        tickTickTokenExpiry: Date? = nil,
        asanaApiToken: String = "",
        linearApiKey: String = "",
        calendarFeedOutputPath: String = "",
        calendarFeedName: String = "Remindian Tasks"
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
        self.enableTagWriteback = enableTagWriteback
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
        self.taskNotesMtnPath = taskNotesMtnPath
        self.taskNotesApiUrl = taskNotesApiUrl
        self.launchAtLogin = launchAtLogin
        self.maxCompletedTaskAgeDays = maxCompletedTaskAgeDays
        self.syncedRemindersLists = syncedRemindersLists
        self.excludedRemindersLists = excludedRemindersLists
        self.excludedTags = excludedTags
        self.addTaskLinkToReminders = addTaskLinkToReminders
        self.appendTaskLinkToNotes = appendTaskLinkToNotes
        self.syncStateLocation = syncStateLocation
        self.genericMarkdown = genericMarkdown
        self.taskNotesCompletedStatuses = taskNotesCompletedStatuses
        self.taskNotesOpenStatus = taskNotesOpenStatus
        self.taskNotesDoneStatus = taskNotesDoneStatus
        self.obsidianTasksOpenMarkers = obsidianTasksOpenMarkers
        self.obsidianTasksCompletedMarkers = obsidianTasksCompletedMarkers
        self.obsidianTasksIgnoredMarkers = obsidianTasksIgnoredMarkers
        self.taskNotesFieldMapping = taskNotesFieldMapping
        self.taskNotesListField = taskNotesListField
        self.filePathMappings = filePathMappings
        self.folderPathMappings = folderPathMappings
        self.enableDataviewFormat = enableDataviewFormat
        self.globalFilter = globalFilter
        self.todoistApiToken = todoistApiToken
        self.tickTickAccessToken = tickTickAccessToken
        self.tickTickRefreshToken = tickTickRefreshToken
        self.tickTickTokenExpiry = tickTickTokenExpiry
        self.asanaApiToken = asanaApiToken
        self.linearApiKey = linearApiKey
        self.calendarFeedOutputPath = calendarFeedOutputPath
        self.calendarFeedName = calendarFeedName
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
        enableTagWriteback = try container.decodeIfPresent(Bool.self, forKey: .enableTagWriteback) ?? false
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
        taskNotesMtnPath = try container.decodeIfPresent(String.self, forKey: .taskNotesMtnPath) ?? ""
        taskNotesApiUrl = try container.decodeIfPresent(String.self, forKey: .taskNotesApiUrl) ?? "http://localhost:8080"
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        maxCompletedTaskAgeDays = try container.decodeIfPresent(Int.self, forKey: .maxCompletedTaskAgeDays) ?? 0
        syncedRemindersLists = try container.decodeIfPresent([String].self, forKey: .syncedRemindersLists) ?? []
        excludedRemindersLists = try container.decodeIfPresent([String].self, forKey: .excludedRemindersLists) ?? []
        excludedTags = try container.decodeIfPresent([String].self, forKey: .excludedTags) ?? []
        addTaskLinkToReminders = try container.decodeIfPresent(Bool.self, forKey: .addTaskLinkToReminders) ?? true
        syncStateLocation = try container.decodeIfPresent(SyncStateLocation.self, forKey: .syncStateLocation) ?? .applicationSupport
        genericMarkdown = try container.decodeIfPresent(GenericMarkdownSettings.self, forKey: .genericMarkdown) ?? GenericMarkdownSettings()
        // Defaults to `false` for both fresh installs AND existing users
        // upgrading from v5.9.x — the whole point of #69 is that the noisy
        // URL-in-notes is opt-in going forward. Users who want it can toggle
        // back on; otherwise the next sync rewrites notes without it. (#69)
        appendTaskLinkToNotes = try container.decodeIfPresent(Bool.self, forKey: .appendTaskLinkToNotes) ?? false
        taskNotesCompletedStatuses = try container.decodeIfPresent([String].self, forKey: .taskNotesCompletedStatuses) ?? ["done", "completed", "cancelled"]
        taskNotesOpenStatus = try container.decodeIfPresent(String.self, forKey: .taskNotesOpenStatus) ?? "open"
        taskNotesDoneStatus = try container.decodeIfPresent(String.self, forKey: .taskNotesDoneStatus) ?? "done"
        // Pre-v5.9.0 configs don't have these keys; default to the historical
        // hardcoded behavior so existing users see zero behavior change. (#63)
        obsidianTasksOpenMarkers = try container.decodeIfPresent([String].self, forKey: .obsidianTasksOpenMarkers) ?? [" "]
        obsidianTasksCompletedMarkers = try container.decodeIfPresent([String].self, forKey: .obsidianTasksCompletedMarkers) ?? ["x", "X"]
        // Pre-v5.10.1 configs don't have this key; default to empty so they
        // continue parsing every checkbox marker as a task (back-compat).
        obsidianTasksIgnoredMarkers = try container.decodeIfPresent([String].self, forKey: .obsidianTasksIgnoredMarkers) ?? []
        taskNotesFieldMapping = try container.decodeIfPresent(TaskNotesFieldMapping.self, forKey: .taskNotesFieldMapping) ?? TaskNotesFieldMapping()
        taskNotesListField = try container.decodeIfPresent(String.self, forKey: .taskNotesListField) ?? "tags"
        filePathMappings = try container.decodeIfPresent([FileMapping].self, forKey: .filePathMappings) ?? []
        folderPathMappings = try container.decodeIfPresent([FolderMapping].self, forKey: .folderPathMappings) ?? []
        enableDataviewFormat = try container.decodeIfPresent(Bool.self, forKey: .enableDataviewFormat) ?? false
        globalFilter = try container.decodeIfPresent(String.self, forKey: .globalFilter) ?? ""
        todoistApiToken = try container.decodeIfPresent(String.self, forKey: .todoistApiToken) ?? ""
        tickTickAccessToken = try container.decodeIfPresent(String.self, forKey: .tickTickAccessToken) ?? ""
        tickTickRefreshToken = try container.decodeIfPresent(String.self, forKey: .tickTickRefreshToken) ?? ""
        tickTickTokenExpiry = try container.decodeIfPresent(Date.self, forKey: .tickTickTokenExpiry)
        asanaApiToken = try container.decodeIfPresent(String.self, forKey: .asanaApiToken) ?? ""
        linearApiKey = try container.decodeIfPresent(String.self, forKey: .linearApiKey) ?? ""
        calendarFeedOutputPath = try container.decodeIfPresent(String.self, forKey: .calendarFeedOutputPath) ?? ""
        calendarFeedName = try container.decodeIfPresent(String.self, forKey: .calendarFeedName) ?? "Remindian Tasks"
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
        try container.encode(enableTagWriteback, forKey: .enableTagWriteback)
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
        try container.encode(taskNotesMtnPath, forKey: .taskNotesMtnPath)
        try container.encode(taskNotesApiUrl, forKey: .taskNotesApiUrl)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(maxCompletedTaskAgeDays, forKey: .maxCompletedTaskAgeDays)
        try container.encode(syncedRemindersLists, forKey: .syncedRemindersLists)
        try container.encode(excludedRemindersLists, forKey: .excludedRemindersLists)
        try container.encode(excludedTags, forKey: .excludedTags)
        try container.encode(addTaskLinkToReminders, forKey: .addTaskLinkToReminders)
        try container.encode(appendTaskLinkToNotes, forKey: .appendTaskLinkToNotes)
        try container.encode(syncStateLocation, forKey: .syncStateLocation)
        try container.encode(genericMarkdown, forKey: .genericMarkdown)
        try container.encode(taskNotesCompletedStatuses, forKey: .taskNotesCompletedStatuses)
        try container.encode(taskNotesOpenStatus, forKey: .taskNotesOpenStatus)
        try container.encode(taskNotesDoneStatus, forKey: .taskNotesDoneStatus)
        try container.encode(obsidianTasksOpenMarkers, forKey: .obsidianTasksOpenMarkers)
        try container.encode(obsidianTasksCompletedMarkers, forKey: .obsidianTasksCompletedMarkers)
        try container.encode(obsidianTasksIgnoredMarkers, forKey: .obsidianTasksIgnoredMarkers)
        try container.encode(taskNotesFieldMapping, forKey: .taskNotesFieldMapping)
        try container.encode(taskNotesListField, forKey: .taskNotesListField)
        try container.encode(filePathMappings, forKey: .filePathMappings)
        try container.encode(folderPathMappings, forKey: .folderPathMappings)
        try container.encode(enableDataviewFormat, forKey: .enableDataviewFormat)
        try container.encode(globalFilter, forKey: .globalFilter)
        try container.encode(todoistApiToken, forKey: .todoistApiToken)
        try container.encode(tickTickAccessToken, forKey: .tickTickAccessToken)
        try container.encode(tickTickRefreshToken, forKey: .tickTickRefreshToken)
        try container.encodeIfPresent(tickTickTokenExpiry, forKey: .tickTickTokenExpiry)
        try container.encode(asanaApiToken, forKey: .asanaApiToken)
        try container.encode(linearApiKey, forKey: .linearApiKey)
        try container.encode(calendarFeedOutputPath, forKey: .calendarFeedOutputPath)
        try container.encode(calendarFeedName, forKey: .calendarFeedName)
    }

    // MARK: - Persistence

    private static var configURL: URL? {
        guard let appFolder = remindianAppSupportDir() else { return nil }
        return appFolder.appendingPathComponent("config.json")
    }

    func save() {
        guard let url = Self.configURL else { return }
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save configuration: \(error)")
        }
    }

    static func load() -> SyncConfiguration {
        guard let url = configURL else { return SyncConfiguration() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SyncConfiguration.self, from: data)
        } catch {
            return SyncConfiguration()
        }
    }

    // MARK: - Helpers

    /// Map an Obsidian tag to a Reminders list name.
    /// Priority: 1) Explicit mapping from settings, 2) Auto-map by capitalizing the tag name.
    /// Falls back to defaultList only if the tag is empty.
    /// Supports both # and + prefixes (e.g., #work, +Project).
    func remindersListForTag(_ tag: String) -> String {
        let cleanTag = (tag.hasPrefix("#") || tag.hasPrefix("+")) ? String(tag.dropFirst()) : tag
        guard !cleanTag.isEmpty else { return defaultList }

        // 1. Check explicit mappings first (compare without prefix)
        if let mapping = listMappings.first(where: {
            let mappingTag = ($0.obsidianTag.hasPrefix("#") || $0.obsidianTag.hasPrefix("+"))
                ? String($0.obsidianTag.dropFirst())
                : $0.obsidianTag
            return mappingTag.lowercased() == cleanTag.lowercased()
        }) {
            return mapping.remindersList
        }

        // 2. Auto-map: capitalize first letter (e.g., "work" → "Work", "family" → "Family")
        return cleanTag.prefix(1).uppercased() + cleanTag.dropFirst()
    }

    /// Resolve the destination list for a task, checking all mapping sources in priority order:
    /// 1. Explicit tag mapping (ListMapping) — tries the full hierarchical path
    ///    first (e.g. `task/work`), then progressively trims back toward the
    ///    root segment so a config for `task` still catches `#task/work` (#64).
    /// 2. File path mapping (FileMapping, #37)
    /// 3. Folder path mapping (FolderMapping, #40)
    /// 4. Auto-capitalize tag name
    /// 5. Default list
    ///
    /// - Parameters:
    ///   - tag: The first-segment tag from a task (e.g. `task` for `#task/work`).
    ///     This is what existing callers have historically passed. Used as the
    ///     fallback after `tags` matching.
    ///   - filePath: Vault-relative path of the source file.
    ///   - tags: The task's full `tags` array (e.g. `["#task/work", "#urgent"]`).
    ///     Used to try the most-specific hierarchical path first. Defaults to
    ///     empty for callers that don't have access — the old `tag`-only path
    ///     still works in that case. (#64)
    func resolveTargetList(tag: String?, filePath: String?, tags: [String] = []) -> String {
        let cleanTag = {
            guard let tag = tag else { return "" }
            return (tag.hasPrefix("#") || tag.hasPrefix("+")) ? String(tag.dropFirst()) : tag
        }()

        // 1a. Try most-specific hierarchical match across all of the task's
        // tags. For each tag we walk from the full path down to the root,
        // trimming `/<segment>` at a time. First mapping hit wins. (#64)
        //
        // Example: task with `tags = ["#task/work", "#urgent"]`
        //   Try in order:
        //     "task/work" → no match
        //     "task"      → matches → use that mapping
        //
        // Example: task with `tags = ["#work/clients/somfy"]` and a mapping
        // for `work/clients` → that exact mapping wins over the bare `work`.
        for fullTag in tags {
            let stripped = (fullTag.hasPrefix("#") || fullTag.hasPrefix("+"))
                ? String(fullTag.dropFirst())
                : fullTag
            var candidate = stripped
            while !candidate.isEmpty {
                if let mapping = listMappings.first(where: {
                    let mappingTag = ($0.obsidianTag.hasPrefix("#") || $0.obsidianTag.hasPrefix("+"))
                        ? String($0.obsidianTag.dropFirst())
                        : $0.obsidianTag
                    return mappingTag.lowercased() == candidate.lowercased()
                }) {
                    return mapping.remindersList
                }
                // Trim the trailing `/segment`. If there's no `/`, exit so
                // we don't infinite-loop on a single-segment tag (which is
                // already handled by step 1b's exact-match fallback below).
                if let slashIndex = candidate.lastIndex(of: "/") {
                    candidate = String(candidate[..<slashIndex])
                } else {
                    break
                }
            }
        }

        // 1b. Fall back to the legacy `tag`-only check. Catches callers that
        // didn't pass `tags` (test fixtures, edge paths) AND the case where
        // the task's first-segment targetList differs from any entry in its
        // tags array (shouldn't happen in practice, but defensive).
        if !cleanTag.isEmpty {
            if let mapping = listMappings.first(where: {
                let mappingTag = ($0.obsidianTag.hasPrefix("#") || $0.obsidianTag.hasPrefix("+"))
                    ? String($0.obsidianTag.dropFirst())
                    : $0.obsidianTag
                return mappingTag.lowercased() == cleanTag.lowercased()
            }) {
                return mapping.remindersList
            }
        }

        // 2. Check file path mappings (#37)
        if let filePath = filePath, !filePath.isEmpty {
            if let mapping = filePathMappings.first(where: {
                filePath.lowercased() == $0.filePath.lowercased()
                || filePath.lowercased().hasSuffix("/\($0.filePath.lowercased())")
            }) {
                return mapping.remindersList
            }
        }

        // 2b. Check folder path mappings (#40) — most specific folder wins
        if let filePath = filePath, !filePath.isEmpty {
            let normalizedPath = filePath.lowercased()
            // Sort by path length descending so more specific folders match first
            let sortedMappings = folderPathMappings.sorted { $0.folderPath.count > $1.folderPath.count }
            for mapping in sortedMappings {
                var folderPrefix = mapping.folderPath.lowercased()
                if !folderPrefix.hasSuffix("/") { folderPrefix += "/" }
                if normalizedPath.hasPrefix(folderPrefix) || normalizedPath.hasPrefix("/\(folderPrefix)") {
                    return mapping.remindersList
                }
            }
        }

        // 3. Auto-capitalize tag
        if !cleanTag.isEmpty {
            return cleanTag.prefix(1).uppercased() + cleanTag.dropFirst()
        }

        // 4. Default list
        return defaultList
    }

    func obsidianTagForList(_ listName: String) -> String? {
        return listMappings.first { $0.remindersList.lowercased() == listName.lowercased() }?.obsidianTag
    }

    /// Check if a TaskNotes status value represents a completed task.
    func isTaskNotesStatusCompleted(_ status: String) -> Bool {
        return taskNotesCompletedStatuses.contains { $0.lowercased() == status.lowercased() }
    }
}
