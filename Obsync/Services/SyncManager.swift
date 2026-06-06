import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// Safe application support directory — returns nil instead of crashing.
/// All persistence code should use this instead of force-unwrapping `.first!`.
func remindianAppSupportDir() -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = appSupport.appendingPathComponent("Remindian", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Write diagnostic logs to a file (since print/NSLog may not be visible from sandboxed GUI apps)
func debugLog(_ message: String) {
    guard let appDir = remindianAppSupportDir() else { return }
    let logFile = appDir.appendingPathComponent("debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Main coordinator that manages sync operations and exposes state to UI
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    // MARK: - Published State

    @Published var config: SyncConfiguration
    @Published var isSyncing = false
    @Published var lastSyncResult: SyncEngine.SyncResult?
    @Published var lastSyncDate: Date?
    @Published var hasDestinationAccess = false
    @Published var pendingConflicts: [SyncEngine.SyncConflict] = []
    @Published var availableLists: [String] = []
    @Published var statusMessage: String = "Ready"
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var syncLog: SyncLog

    // MARK: - Private

    private var syncEngine: SyncEngine
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isFirstSync = true
    private var appearanceObservation: NSKeyValueObservation?
    private var currentSyncTask: Task<Void, Never>?

    // Protocol-based source and destination
    private(set) var taskSource: TaskSource
    private(set) var taskDestination: TaskDestination

    // MARK: - Initialization

    private init() {
        // Per-step instrumentation so if we ever crash during init again we'll see
        // exactly which step failed in the debug log (see #58). Each step is
        // self-contained — if one does something unexpected on a user's machine,
        // the previous debugLog will still have been flushed.
        debugLog("[SyncManager.init] start")

        let loadedConfig = SyncConfiguration.load()
        debugLog("[SyncManager.init] config loaded: source=\(loadedConfig.taskSourceType), destination=\(loadedConfig.taskDestinationType), vaultPath='\(loadedConfig.vaultPath)'")
        self.config = loadedConfig

        self.syncLog = SyncLog.load()
        debugLog("[SyncManager.init] sync log loaded")

        // Initialize source and destination from config
        let src = SyncManager.createSource(for: loadedConfig.taskSourceType, config: loadedConfig)
        let dst = SyncManager.createDestination(for: loadedConfig.taskDestinationType, config: loadedConfig)
        self.taskSource = src
        self.taskDestination = dst
        self.syncEngine = SyncEngine(source: src, destination: dst,
                                     stateLocation: loadedConfig.syncStateLocation,
                                     vaultPath: loadedConfig.vaultPath)
        debugLog("[SyncManager.init] engine ready")

        setupAutoSync()
        debugLog("[SyncManager.init] auto-sync configured")

        setupConfigObserver()
        debugLog("[SyncManager.init] config observer attached")

        setupAppearanceObserver()
        debugLog("[SyncManager.init] appearance observer attached")

        setupOAuthObserver()
        debugLog("[SyncManager.init] OAuth observer attached — init complete")
    }

    // MARK: - Source/Destination Factory

    static func createSource(for type: SyncConfiguration.TaskSourceType, config: SyncConfiguration? = nil) -> TaskSource {
        switch type {
        case .obsidianTasks:
            return ObsidianTasksSource()
        case .taskNotes:
            let source = TaskNotesSource()
            if let config = config {
                source.integrationMode = TaskNotesSource.IntegrationMode(rawValue: config.taskNotesIntegrationMode) ?? .cli
                source.mtnPath = config.taskNotesMtnPath
                if !config.taskNotesApiUrl.isEmpty {
                    source.apiBaseUrl = config.taskNotesApiUrl
                }
                // Custom status mapping (#10)
                source.completedStatuses = config.taskNotesCompletedStatuses
                source.openStatus = config.taskNotesOpenStatus
                source.doneStatus = config.taskNotesDoneStatus
                // Field mapping (#19) and list field (#20)
                source.fieldMapping = config.taskNotesFieldMapping
                source.listField = config.taskNotesListField
            }
            return source
        case .genericMarkdown:
            return GenericMarkdownSource()
        }
    }

    static func createDestination(for type: SyncConfiguration.TaskDestinationType, config: SyncConfiguration) -> TaskDestination {
        switch type {
        case .appleReminders:
            return RemindersDestination()
        case .things3:
            let destination = Things3Destination()
            destination.authToken = config.things3AuthToken
            return destination
        case .todoist:
            let destination = TodoistDestination()
            destination.apiToken = config.todoistApiToken
            return destination
        case .tickTick:
            let destination = TickTickDestination()
            destination.accessToken = config.tickTickAccessToken
            destination.refreshToken = config.tickTickRefreshToken
            destination.tokenExpiry = config.tickTickTokenExpiry
            return destination
        case .asana:
            let destination = AsanaDestination()
            destination.apiToken = config.asanaApiToken
            return destination
        case .linear:
            let destination = LinearDestination()
            destination.apiKey = config.linearApiKey
            return destination
        case .calendarFeed:
            let destination = CalendarFeedDestination()
            destination.outputPath = config.calendarFeedOutputPath
            destination.calendarName = config.calendarFeedName
            return destination
        }
    }

    /// Recreate source and destination when the user changes the type in settings.
    func updateSourceAndDestination() {
        taskSource = SyncManager.createSource(for: config.taskSourceType, config: config)
        taskDestination = SyncManager.createDestination(for: config.taskDestinationType, config: config)
        syncEngine = SyncEngine(source: taskSource, destination: taskDestination,
                                stateLocation: config.syncStateLocation,
                                vaultPath: config.vaultPath)
        debugLog("[SyncManager] Updated source=\(taskSource.sourceName), destination=\(taskDestination.destinationName)")

        // Re-request access for the new destination
        Task {
            await requestDestinationAccess()
        }
    }

    private func setupConfigObserver() {
        // Observe the config object being replaced
        $config
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] config in
                config.save()
                self?.setupAutoSync()
                self?.updateHotKey()
                self?.updateFileWatcher()
            }
            .store(in: &cancellables)

        // Observe internal @Published property changes within the config object
        // ($config only fires when the whole object is replaced, not when its
        // internal properties change — this catches settings edits)
        config.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.config.save()
                self?.setupAutoSync()
                self?.updateHotKey()
                self?.updateFileWatcher()
            }
            .store(in: &cancellables)
    }

    private func setupOAuthObserver() {
        OAuthCallbackHandler.shared.$tickTickAuthCode
            .compactMap { $0 }
            .sink { [weak self] code in
                self?.handleTickTickOAuthCode(code)
            }
            .store(in: &cancellables)
    }

    private func setupAppearanceObserver() {
        // Observe system appearance changes to update the dock icon.
        // Defer the KVO attachment to the next run loop: during initial launch,
        // SwiftUI can resolve the @StateObject very early in the app lifecycle,
        // and attaching KVO observers to NSApp before the delegate finishes
        // initializing has caused SIGTRAPs on some systems (#58).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshDockIcon()
                }
            }
        }
    }

    // MARK: - Access Request

    /// Check destination access and refresh available lists. Pure: never
    /// triggers a sync as a side effect. The launch-time auto-sync trigger
    /// lives in `performLaunchSyncIfReady()` and is invoked explicitly by
    /// the AppDelegate, NOT from this method. This separation prevents
    /// runtime config changes (e.g. switching TaskNotes integration mode)
    /// from accidentally firing a sync — see #62.5.
    func requestDestinationAccess() async {
        do {
            debugLog("[SyncManager] Requesting \(taskDestination.destinationName) access...")
            hasDestinationAccess = try await taskDestination.requestAccess()
            debugLog("[SyncManager] \(taskDestination.destinationName) access: \(hasDestinationAccess)")
            if hasDestinationAccess {
                refreshLists()
                debugLog("[SyncManager] Available lists: \(availableLists)")
            }
        } catch {
            hasDestinationAccess = false
            debugLog("[SyncManager] \(taskDestination.destinationName) access failed: \(error.localizedDescription)")
            // Don't show scary error for token-based destinations that just need configuration
            let isTokenBased = config.taskDestinationType == .todoist || config.taskDestinationType == .tickTick
            if !isTokenBased {
                showErrorMessage("Failed to get \(taskDestination.destinationName) access: \(error.localizedDescription)")
            }
        }
    }

    /// Launch-time auto-sync: requests destination access, then if everything
    /// is configured (onboarded + valid vault + `syncOnLaunch` enabled),
    /// triggers a sync. Called once from `AppDelegate.applicationDidFinishLaunching`.
    /// (#62.5)
    func performLaunchSyncIfReady() async {
        await requestDestinationAccess()

        guard hasDestinationAccess else { return }

        // Don't auto-sync before onboarding is complete (#25)
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        guard hasOnboarded else {
            debugLog("[SyncManager] Sync on launch skipped: onboarding not completed yet")
            return
        }

        guard config.syncOnLaunch, !config.vaultPath.isEmpty else {
            debugLog("[SyncManager] Sync on launch skipped: syncOnLaunch=\(config.syncOnLaunch), vaultPath='\(config.vaultPath)'")
            return
        }

        debugLog("[SyncManager] Sync on launch triggered")
        await performSync()
    }

    // MARK: - Sync Operations

    func performSync() async {
        guard !isSyncing else {
            debugLog("[SyncManager] Skipped: already syncing")
            return
        }
        // Ensure source/destination reflect latest config before each sync
        updateSourceAndDestination()
        guard hasDestinationAccess else {
            showErrorMessage("No access to \(taskDestination.destinationName). Please check your configuration in Settings.")
            return
        }
        guard !config.vaultPath.isEmpty else {
            showErrorMessage("Please configure your Obsidian vault path first.")
            return
        }

        debugLog("[SyncManager] Starting sync. Vault: \(config.vaultPath), dryRun: \(config.dryRunMode)")

        // Ensure we have file access to the vault (sandbox requires security-scoped bookmark)
        if !FileManager.default.isReadableFile(atPath: config.vaultPath) {
            debugLog("[SyncManager] Vault not readable, attempting to resolve bookmark...")
            if !resolveVaultBookmark() {
                debugLog("[SyncManager] Bookmark resolution failed, auto-prompting vault re-selection")
                // Automatically show file picker to re-grant access
                selectVaultPath()
                // Check if access was granted after re-selection
                if config.vaultPath.isEmpty || !FileManager.default.isReadableFile(atPath: config.vaultPath) {
                    showErrorMessage("Cannot read Obsidian vault. Please select your vault folder to restore access.")
                    return
                }
            }
        }

        isSyncing = true
        statusMessage = config.dryRunMode ? "Dry run..." : "Syncing..."

        let wasFirstSync = isFirstSync
        let result = await syncEngine.performSync(config: config) { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
        debugLog("[SyncManager] Sync result: \(result.summary), errors: \(result.errors.count), details: \(result.details.count)")

        lastSyncResult = result
        lastSyncDate = Date()
        pendingConflicts = result.conflicts
        isFirstSync = false

        // Log the sync operation
        syncLog.addEntry(from: result)

        // Send notifications if enabled
        if config.enableNotifications {
            if !result.errors.isEmpty {
                NotificationService.shared.sendNotification(
                    title: "Sync Error",
                    body: "\(result.errors.count) error(s) during sync. \(result.summary)",
                    category: .syncError
                )
            } else if wasFirstSync {
                NotificationService.shared.sendNotification(
                    title: "First Sync Complete",
                    body: result.summary,
                    category: .syncComplete
                )
            }
        }

        if result.errors.isEmpty {
            statusMessage = result.summary
        } else {
            // Deduplicate identical error messages (e.g. multiple -3002 errors)
            var seen = Set<String>()
            var uniqueMessages: [String] = []
            for error in result.errors {
                let msg = error.localizedDescription
                if seen.insert(msg).inserted {
                    uniqueMessages.append(msg)
                }
            }
            let errorSummary = uniqueMessages.joined(separator: "\n")
            let countNote = result.errors.count > uniqueMessages.count
                ? " (\(result.errors.count) total)"
                : ""
            showErrorMessage("Sync completed with errors\(countNote):\n\(errorSummary)")
            statusMessage = "Sync completed with \(result.errors.count) error\(result.errors.count == 1 ? "" : "s")"
        }

        isSyncing = false
    }

    /// Cancel a running sync operation (#26)
    func cancelSync() {
        guard isSyncing else { return }
        currentSyncTask?.cancel()
        syncEngine.requestCancellation()
        isSyncing = false
        statusMessage = "Sync cancelled"
        debugLog("[SyncManager] Sync cancelled by user")
    }

    // MARK: - Conflict Resolution

    func resolveConflict(_ conflict: SyncEngine.SyncConflict, choice: SyncEngine.SyncConflict.ConflictResolutionChoice) {
        Task {
            do {
                try await syncEngine.resolveConflict(conflict, with: choice, config: config)
                pendingConflicts.removeAll { $0.task.id == conflict.task.id }
            } catch {
                showErrorMessage("Failed to resolve conflict: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Auto Sync

    private func setupAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil

        guard config.enableAutoSync else { return }

        // Clamp to a sane minimum so a corrupt persisted config (e.g. 0 or negative)
        // can't schedule a timer that fires continuously and burns CPU (#58-adjacent).
        let minutes = max(1, config.syncIntervalMinutes)
        let interval = TimeInterval(minutes * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performSync()
            }
        }
    }

    // MARK: - Global Hotkey

    func updateHotKey() {
        if config.globalHotKeyEnabled {
            HotKeyService.shared.register(
                keyCode: config.globalHotKeyCode,
                modifiers: config.globalHotKeyModifiers
            ) { [weak self] in
                Task { @MainActor in
                    await self?.performSync()
                }
            }
        } else {
            HotKeyService.shared.unregister()
        }
    }

    // MARK: - File Watcher

    func updateFileWatcher() {
        if config.enableFileWatcher && !config.vaultPath.isEmpty {
            FileWatcherService.shared.startWatching(path: config.vaultPath) { [weak self] in
                Task { @MainActor in
                    debugLog("[SyncManager] File watcher triggered sync")
                    await self?.performSync()
                }
            }
        } else {
            FileWatcherService.shared.stopWatching()
        }
    }

    // MARK: - List Management

    func refreshLists() {
        Task {
            availableLists = await taskDestination.getAvailableLists()
            debugLog("[SyncManager] Refreshed lists: \(availableLists)")
        }
    }

    // MARK: - Configuration

    func selectVaultPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select Vault"

        if panel.runModal() == .OK, let url = panel.url {
            config.vaultPath = url.path

            // Save security-scoped bookmark for sandbox persistence
            do {
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(bookmark, forKey: "vaultBookmark")
                debugLog("[SyncManager] Saved vault bookmark for: \(url.path)")

                // Start accessing immediately
                if url.startAccessingSecurityScopedResource() {
                    debugLog("[SyncManager] Security-scoped access started for: \(url.path)")
                } else {
                    debugLog("[SyncManager] Warning: startAccessingSecurityScopedResource returned false")
                }
            } catch {
                debugLog("[SyncManager] Failed to save bookmark: \(error)")
                // Even without bookmark, NSOpenPanel grants temporary access
                // so the current session will work
            }

            // Trigger an initial sync after vault selection
            debugLog("[SyncManager] Vault selected, triggering initial sync...")
            Task {
                await performSync()
            }
        }
    }

    /// Resolve the saved bookmark on app launch to restore file access.
    func resolveVaultBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "vaultBookmark") else {
            debugLog("[SyncManager] No vault bookmark saved in UserDefaults")
            return false
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            debugLog("[SyncManager] Failed to resolve vault bookmark")
            return false
        }

        if isStale {
            debugLog("[SyncManager] Vault bookmark is stale")
            showErrorMessage("Vault access has expired. Please re-select your Obsidian vault in Settings.")
            return false
        }

        guard url.startAccessingSecurityScopedResource() else {
            debugLog("[SyncManager] Failed to start accessing security-scoped resource for: \(url.path)")
            return false
        }
        debugLog("[SyncManager] Security-scoped access granted for: \(url.path)")

        // Ensure config.vaultPath is set from the resolved bookmark
        if config.vaultPath.isEmpty || config.vaultPath != url.path {
            debugLog("[SyncManager] Updating vaultPath from bookmark: \(url.path)")
            config.vaultPath = url.path
        }

        return true
    }

    func addListMapping(obsidianTag: String, remindersList: String) {
        let mapping = SyncConfiguration.ListMapping(
            obsidianTag: obsidianTag,
            remindersList: remindersList
        )
        config.listMappings.append(mapping)
    }

    func removeListMapping(at index: Int) {
        guard index < config.listMappings.count else { return }
        config.listMappings.remove(at: index)
    }

    /// Remove by stable id. Preferred over `removeListMapping(at:)` because it
    /// pairs with a `ForEach(syncManager.config.listMappings)` (no enumerated
    /// snapshot), which lets SwiftUI observe the underlying @Published array
    /// and redraw immediately. See #62.3.
    func removeListMapping(id: UUID) {
        config.listMappings.removeAll { $0.id == id }
    }

    func addFileMapping(filePath: String, remindersList: String) {
        let mapping = SyncConfiguration.FileMapping(
            filePath: filePath,
            remindersList: remindersList
        )
        config.filePathMappings.append(mapping)
    }

    func removeFileMapping(at index: Int) {
        guard index < config.filePathMappings.count else { return }
        config.filePathMappings.remove(at: index)
    }

    func removeFileMapping(id: UUID) {
        config.filePathMappings.removeAll { $0.id == id }
    }

    func addFolderMapping(folderPath: String, remindersList: String) {
        let mapping = SyncConfiguration.FolderMapping(
            folderPath: folderPath,
            remindersList: remindersList
        )
        config.folderPathMappings.append(mapping)
    }

    func removeFolderMapping(at index: Int) {
        guard index < config.folderPathMappings.count else { return }
        config.folderPathMappings.remove(at: index)
    }

    func removeFolderMapping(id: UUID) {
        config.folderPathMappings.removeAll { $0.id == id }
    }

    func updateDockIconVisibility() {
        if config.hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func updateAppIcon() {
        if config.forceDarkIcon {
            // Force the entire app into dark mode appearance.
            // This gives a dark UI and the asset catalog automatically resolves
            // the dark variant of the app icon.
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else {
            // Reset so the system picks light/dark automatically
            NSApp.appearance = nil
        }
        // Also refresh the dock icon to match the current appearance
        refreshDockIcon()
    }

    /// Set the dock icon to match the current effective appearance (light/dark).
    /// In dark mode, we explicitly set the dark variant since AppIcon luminosity
    /// appearances in the asset catalog are not reliably resolved at runtime.
    /// In light mode, we reset to nil so macOS uses the default AppIcon natively.
    func refreshDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            if let icon = NSImage(named: "AppIconDark") {
                NSApp.applicationIconImage = paddedIcon(icon)
            }
        } else {
            // Let macOS handle it natively from the asset catalog
            NSApp.applicationIconImage = nil
        }
    }

    /// Add transparent padding around an icon image to match the standard macOS
    /// dock icon sizing. Without this, programmatically set icons appear larger
    /// than native asset catalog icons.
    private func paddedIcon(_ source: NSImage) -> NSImage {
        let canvasSize = NSSize(width: 1024, height: 1024)
        // macOS dock icons have ~10% inset on each side to match native sizing
        let inset: CGFloat = 100
        let iconRect = NSRect(
            x: inset, y: inset,
            width: canvasSize.width - inset * 2,
            height: canvasSize.height - inset * 2
        )
        let padded = NSImage(size: canvasSize)
        padded.lockFocus()
        source.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        padded.unlockFocus()
        return padded
    }

    // MARK: - mtn Binary Selection (Sandbox)

    func selectMtnBinary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = "Select the mtn binary (run 'which mtn' in Terminal to find it)"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            config.taskNotesMtnPath = url.path

            // Save security-scoped bookmark for persistent sandbox access
            TaskNotesSource.saveMtnBookmark(for: url)

            // Rebuild source with new path
            updateSourceAndDestination()

            debugLog("[SyncManager] Selected mtn binary: \(url.path)")
        }
    }

    // MARK: - Launch at Login

    func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    debugLog("[SyncManager] Registered launch at login")
                } else {
                    try SMAppService.mainApp.unregister()
                    debugLog("[SyncManager] Unregistered launch at login")
                }
            } catch {
                debugLog("[SyncManager] Launch at login failed: \(error)")
            }
        }
    }

    // MARK: - TickTick OAuth

    /// Initiate the TickTick OAuth flow by opening the browser.
    func connectTickTick() {
        guard let destination = taskDestination as? TickTickDestination else {
            // Create a temporary destination to start the flow
            let tmp = TickTickDestination()
            tmp.startOAuthFlow()
            return
        }
        destination.startOAuthFlow()
    }

    /// Exchange a TickTick OAuth authorization code for tokens.
    func handleTickTickOAuthCode(_ code: String) {
        Task {
            do {
                let destination: TickTickDestination
                if let existing = taskDestination as? TickTickDestination {
                    destination = existing
                } else {
                    destination = TickTickDestination()
                }
                try await destination.exchangeCodeForToken(code)

                // Store tokens in config
                config.tickTickAccessToken = destination.accessToken
                config.tickTickRefreshToken = destination.refreshToken
                config.tickTickTokenExpiry = destination.tokenExpiry
                config.save()

                // Recreate destination with new tokens
                updateSourceAndDestination()
                refreshLists()

                debugLog("[SyncManager] TickTick connected successfully")
            } catch {
                showErrorMessage("TickTick connection failed: \(error.localizedDescription)")
                debugLog("[SyncManager] TickTick OAuth error: \(error)")
            }
        }
    }

    /// Disconnect TickTick by clearing stored tokens.
    func disconnectTickTick() {
        config.tickTickAccessToken = ""
        config.tickTickRefreshToken = ""
        config.tickTickTokenExpiry = nil
        config.save()
        updateSourceAndDestination()
        debugLog("[SyncManager] TickTick disconnected")
    }

    func resetSyncState() {
        syncEngine.resetSyncState()
        lastSyncResult = nil
        lastSyncDate = nil
        pendingConflicts = []
        isFirstSync = true
        syncLog.clear()
        statusMessage = "Sync state reset — all mappings and history cleared"
        debugLog("[SyncManager] Full sync state reset: mappings, log, and history cleared")

        // Also clear the debug log to remove any stale references (#30)
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Remindian", isDirectory: true)
            .appendingPathComponent("debug.log")
        if let logURL = logURL {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func clearSyncLog() {
        syncLog.clear()
    }

    // MARK: - Error Handling

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
