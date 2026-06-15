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

    /// The ACTIVE profile's configuration. All existing Settings bindings edit
    /// this object, so the single-profile UI works unchanged — it just edits
    /// whichever profile is selected. (multi-profile)
    @Published var config: SyncConfiguration
    /// All sync profiles + which one is active. The active profile's `config` is
    /// mirrored into `config` above. Persisted to profiles.json.
    @Published var profileStore: ProfileStore
    @Published var isSyncing = false
    /// Diff-preview state: a forced dry-run result the user can review before
    /// applying. (Diff preview + Undo)
    @Published var isPreviewing = false
    @Published var previewResult: SyncEngine.SyncResult?
    /// Number of vault files restorable via "Undo last sync" (0 = nothing to undo).
    @Published var lastSyncUndoCount: Int = 0
    /// Open tasks due today or earlier, for the menu-bar "Today" glance. (Today list)
    @Published var agenda: [SyncTask] = []
    @Published var isLoadingAgenda = false
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
    /// Subscription to the *active* config's per-property changes. Re-created on
    /// every profile switch so edits to the newly-active profile are observed.
    private var activeConfigCancellable: AnyCancellable?
    private var isFirstSync = true
    private var appearanceObservation: NSKeyValueObservation?
    private var currentSyncTask: Task<Void, Never>?
    /// Per-(last)-sync undo manifest: one earliest pre-sync backup per file.
    private var lastSyncUndoManifest: [FileBackupService.BackupRecord] = []
    /// Throttle for the Today-agenda refresh (menu `.task` can fire often).
    private var lastAgendaRefresh: Date?

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

        // Load profiles (migrates the legacy config.json into a Default profile
        // on first run). The active profile's config drives the UI + active engine.
        let store = ProfileStore.load()
        self.profileStore = store
        let activeProfile = store.activeProfile ?? store.profiles[0]
        let loadedConfig = activeProfile.config
        debugLog("[SyncManager.init] profiles loaded: \(store.profiles.count), active='\(activeProfile.name)', source=\(loadedConfig.taskSourceType), destination=\(loadedConfig.taskDestinationType), vaultPath='\(loadedConfig.vaultPath)'")
        self.config = loadedConfig

        self.syncLog = SyncLog.load()
        debugLog("[SyncManager.init] sync log loaded")

        // Initialize source and destination from the active profile's config
        let src = SyncManager.createSource(for: loadedConfig.taskSourceType, config: loadedConfig)
        let dst = SyncManager.createDestination(for: loadedConfig.taskDestinationType, config: loadedConfig)
        self.taskSource = src
        self.taskDestination = dst
        self.syncEngine = SyncEngine(source: src, destination: dst,
                                     stateLocation: loadedConfig.syncStateLocation,
                                     vaultPath: loadedConfig.vaultPath,
                                     profileKey: activeProfile.stateKey)
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

    nonisolated static func createSource(for type: SyncConfiguration.TaskSourceType, config: SyncConfiguration? = nil) -> TaskSource {
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
                                vaultPath: config.vaultPath,
                                profileKey: profileStore.activeProfile?.stateKey ?? "")
        debugLog("[SyncManager] Updated source=\(taskSource.sourceName), destination=\(taskDestination.destinationName)")

        // Re-request access for the new destination
        Task {
            await requestDestinationAccess()
        }
    }

    private func setupConfigObserver() {
        // Observe the config object being replaced (e.g. on profile switch).
        $config
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistAndApplyConfigChange()
            }
            .store(in: &cancellables)

        // And observe per-property edits within the *active* config object.
        subscribeToActiveConfig()
    }

    /// (Re)subscribe to the active config's `objectWillChange`. Called on init
    /// and on every profile switch so settings edits to the newly-active profile
    /// are observed (the old subscription is dropped).
    private func subscribeToActiveConfig() {
        activeConfigCancellable = config.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistAndApplyConfigChange()
            }
    }

    /// Persist a config change: keep global singleton settings identical across
    /// all profiles, save the whole profile store (and the active config.json as
    /// a back-compat backstop), then re-apply app-wide side effects.
    private func persistAndApplyConfigChange() {
        profileStore.propagateGlobalSettings()
        profileStore.save()
        config.save() // backstop: keeps config.json roughly current for the active profile
        setupAutoSync()
        updateHotKey()
        updateFileWatcher()
    }

    // MARK: - Profile management (multi-profile)

    /// Switch the active profile. Re-points `config` at the chosen profile's
    /// configuration (the UI rebinds automatically), rebuilds the active engine,
    /// and restarts the file watcher on the new vault.
    func switchProfile(to id: String) {
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else { return }
        profileStore.activeProfileId = id
        config = profile.config            // @Published → UI rebinds to this profile
        subscribeToActiveConfig()          // observe the newly-active config's edits
        updateSourceAndDestination()       // rebuild engine/source/destination for it
        updateFileWatcher()
        profileStore.save()
        debugLog("[SyncManager] Switched to profile '\(profile.name)'")
    }

    /// Add a new profile, seeded from a deep copy of the current active config
    /// (so tokens/vault carry over as a starting point), then switch to it.
    @discardableResult
    func addProfile(name: String) -> String {
        let newConfig = config.deepCopy()
        let profile = SyncProfile(name: name.isEmpty ? "New Profile" : name, enabled: true, isDefault: false, config: newConfig)
        profileStore.profiles.append(profile)
        profileStore.propagateGlobalSettings()
        profileStore.save()
        switchProfile(to: profile.id)
        return profile.id
    }

    func renameProfile(id: String, to name: String) {
        guard let idx = profileStore.profiles.firstIndex(where: { $0.id == id }) else { return }
        profileStore.profiles[idx].name = name
        profileStore.save()
    }

    func setProfileEnabled(id: String, enabled: Bool) {
        guard let idx = profileStore.profiles.firstIndex(where: { $0.id == id }) else { return }
        profileStore.profiles[idx].enabled = enabled
        profileStore.save()
    }

    /// Delete a profile. The default profile and the last remaining profile
    /// cannot be deleted. Also removes that profile's sync-state file. If the
    /// active profile is deleted, switches to the default.
    func deleteProfile(id: String) {
        guard profileStore.profiles.count > 1,
              let profile = profileStore.profiles.first(where: { $0.id == id }),
              !profile.isDefault else {
            debugLog("[SyncManager] Refusing to delete profile (default or last remaining).")
            return
        }
        // Remove its per-profile state file (best-effort; never the default's).
        if let url = SyncState.stateURL(location: profile.config.syncStateLocation,
                                        vaultPath: profile.config.vaultPath,
                                        profileKey: profile.stateKey) {
            try? FileManager.default.removeItem(at: url)
        }
        profileStore.profiles.removeAll { $0.id == id }
        if profileStore.activeProfileId == id {
            let fallback = profileStore.profiles.first(where: { $0.isDefault }) ?? profileStore.profiles[0]
            switchProfile(to: fallback.id)
        } else {
            profileStore.save()
        }
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

    /// Profile-scoped pre-sync failures (vault/destination access, config).
    private enum ProfileSyncIssue: LocalizedError {
        case notConfigured(String)
        case vaultAccess(String, String)
        case destinationAccess(String, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured(let name):
                return "Profile “\(name)”: no vault path configured."
            case .vaultAccess(let name, let path):
                return "Profile “\(name)”: can't read its vault (\(path)). Select this profile in Settings and re-choose its vault to grant access."
            case .destinationAccess(let name, let dest):
                return "Profile “\(name)”: no access to \(dest). Check its configuration in Settings."
            }
        }
    }

    /// Sync all enabled profiles (sequentially). The single-profile case is a
    /// loop of one and behaves exactly as before. (multi-profile)
    /// `interactive` controls whether a missing vault may pop a modal file
    /// picker. User-initiated syncs (menu "Sync Now", quick-add, complete,
    /// preview) pass true; unattended triggers (auto-sync timer, file watcher,
    /// hotkey, Shortcuts) pass false so they never steal focus with a dialog. (audit #14)
    func performSync(interactive: Bool = true) async {
        guard !isSyncing else {
            debugLog("[SyncManager] Skipped: already syncing")
            return
        }
        // Keep the active engine/source/destination current for the active
        // profile (also used by list pickers, reset, conflict resolution).
        updateSourceAndDestination()

        let enabled = profileStore.enabledProfiles
        guard !enabled.isEmpty else {
            showErrorMessage("No sync profiles are enabled. Enable a profile in Settings.")
            return
        }

        let activeId = profileStore.activeProfileId
        // Preserve the interactive vault re-selection flow for the active
        // profile (the common single-profile experience) — only when interactive.
        if interactive, enabled.contains(where: { $0.id == activeId }) {
            _ = ensureActiveVaultAccess()
        }

        isSyncing = true
        statusMessage = config.dryRunMode ? "Dry run..." : "Syncing..."
        let wasFirstSync = isFirstSync
        let multi = enabled.count > 1
        let syncStart = Date()

        var aggregate = SyncEngine.SyncResult()
        aggregate.isDryRun = config.dryRunMode
        for (index, profile) in enabled.enumerated() {
            if multi { statusMessage = "Syncing “\(profile.name)” (\(index + 1)/\(enabled.count))…" }
            let result = await syncSingleProfile(profile, isActive: profile.id == activeId)
            aggregate = SyncManager.mergeResults(aggregate, result)
            debugLog("[SyncManager] Profile '\(profile.name)' result: \(result.summary)")
        }

        // Build the undo manifest from backups taken during this sync (skip in
        // dry run — nothing was written). One earliest (pre-sync) backup per file.
        if !aggregate.isDryRun {
            captureUndoManifest(since: syncStart)
        }

        finalizeSyncResult(aggregate, wasFirstSync: wasFirstSync)
        isSyncing = false
    }

    /// Snapshot the vault backups made during the last sync into an undo
    /// manifest (earliest pre-sync copy per file).
    private func captureUndoManifest(since: Date) {
        let recent = FileBackupService.shared.sessionBackups(since: since)
        var earliestByPath: [String: FileBackupService.BackupRecord] = [:]
        for record in recent {
            if let existing = earliestByPath[record.originalPath] {
                if record.date < existing.date { earliestByPath[record.originalPath] = record }
            } else {
                earliestByPath[record.originalPath] = record
            }
        }
        lastSyncUndoManifest = Array(earliestByPath.values)
        lastSyncUndoCount = lastSyncUndoManifest.count
    }

    /// Restore the vault files changed by the last sync to their pre-sync
    /// content. Each restore backs up the current content first, so this is
    /// itself reversible. Returns the number of files restored. (Undo)
    @discardableResult
    func undoLastSyncVaultChanges() -> Int {
        guard !lastSyncUndoManifest.isEmpty else { return 0 }
        var restored = 0
        for record in lastSyncUndoManifest {
            do {
                try FileBackupService.shared.restoreFile(from: record.backupURL, to: record.originalPath)
                restored += 1
            } catch {
                debugLog("[SyncManager] Undo failed for \(record.originalPath): \(error.localizedDescription)")
            }
        }
        lastSyncUndoManifest = []
        lastSyncUndoCount = 0
        statusMessage = "Restored \(restored) vault file\(restored == 1 ? "" : "s") from before the last sync"
        debugLog("[SyncManager] Undo restored \(restored) vault file(s)")
        return restored
    }

    // MARK: - Quick add (Shortcuts + menu-bar capture)

    /// Parse a free-text quick-add string and append it to the active profile's
    /// source inbox (Obsidian is the source of truth), then optionally sync so
    /// it reaches the destination. Returns true on success. (Shortcuts + quick-add)
    @discardableResult
    func quickAddTask(_ text: String, triggerSync: Bool = true, interactive: Bool = true) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !config.vaultPath.isEmpty else {
            showErrorMessage("Set your Obsidian vault path in Settings before adding tasks.")
            return false
        }
        if !FileManager.default.isReadableFile(atPath: config.vaultPath) {
            // Never pop a modal picker from a Shortcut/background invocation. (audit #4)
            if !ensureActiveVaultAccess(interactive: interactive) {
                showErrorMessage("Vault access expired — open Remindian to re-select your vault.")
                return false
            }
        }

        // Append off the main actor — file I/O on @MainActor janks the UI. (audit #5)
        let task = QuickAddParser.parse(trimmed)
        let cfg = config.deepCopy()
        let type = cfg.taskSourceType
        let ok: Bool = await Task.detached(priority: .userInitiated) {
            let source = SyncManager.createSource(for: type, config: cfg)
            do { _ = try source.appendNewTask(task, config: cfg); return true }
            catch { return false }
        }.value
        guard ok else {
            showErrorMessage("Couldn't add task to your inbox.")
            return false
        }
        debugLog("[SyncManager] Quick-added task '\(task.title)'")

        if triggerSync {
            await syncActiveProfileOnly()
        }
        return true
    }

    /// Sync ONLY the active profile (used by single-task flows like quick-add and
    /// agenda-complete). Avoids a full all-profiles sweep + engine rebuild for one
    /// task, and reuses the warm active source/engine. (audit #9, #11)
    func syncActiveProfileOnly() async {
        guard !isSyncing else { return }
        guard let active = profileStore.activeProfile else { await performSync(interactive: false); return }
        updateSourceAndDestination()
        isSyncing = true
        statusMessage = config.dryRunMode ? "Dry run..." : "Syncing..."
        let wasFirstSync = isFirstSync
        let syncStart = Date()
        let result = await syncSingleProfile(active, isActive: true)
        if !result.isDryRun { captureUndoManifest(since: syncStart) }
        finalizeSyncResult(result, wasFirstSync: wasFirstSync)
        isSyncing = false
    }

    // MARK: - Today agenda (menu-bar glance)

    /// Scan the active profile's source and populate `agenda` with open tasks
    /// due today or earlier. (Today list)
    ///
    /// CRITICAL: the vault scan runs on a **background task**, never on the main
    /// actor — a full scan on `@MainActor` froze the whole app/menu on real
    /// vaults. Re-entrancy-guarded and throttled so the menu's `.task` can fire
    /// freely without ever stacking scans.
    func refreshAgenda(force: Bool = false) async {
        guard !isLoadingAgenda else { return }
        if !force, let last = lastAgendaRefresh, Date().timeIntervalSince(last) < 10 { return }
        guard !config.vaultPath.isEmpty,
              FileManager.default.isReadableFile(atPath: config.vaultPath) else {
            agenda = []
            return
        }
        isLoadingAgenda = true
        defer { isLoadingAgenda = false }

        // Snapshot config on the main actor, then scan off-main so the UI never
        // blocks. A fresh source is built inside the background task (createSource
        // is pure), so we never touch the main-actor `taskSource` from off-main.
        let cfg = config.deepCopy()
        let type = cfg.taskSourceType
        let scanned: [SyncTask] = await Task.detached(priority: .utility) {
            let source = SyncManager.createSource(for: type, config: cfg)
            return (try? source.scanTasks(config: cfg)) ?? []
        }.value
        agenda = AgendaBuilder.build(from: scanned, now: Date())
        lastAgendaRefresh = Date()
    }

    /// Mark an agenda task complete in the source (Obsidian = source of truth),
    /// drop it from the list immediately, then sync so the destination follows.
    /// The file mutation runs off the main actor so the menu never freezes. (audit #1)
    func completeAgendaItem(_ task: SyncTask) async {
        let cfg = config.deepCopy()
        let type = cfg.taskSourceType
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            let source = SyncManager.createSource(for: type, config: cfg)
            do { _ = try source.markTaskComplete(task: task, completionDate: Date(), config: cfg); return .success(()) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success:
            agenda.removeAll { $0.id == task.id } // optimistic UI on main
        case .failure(let error):
            showErrorMessage("Couldn't complete “\(task.title)”: \(error.localizedDescription)")
            return
        }
        await syncActiveProfileOnly()
        // The sync just rewrote vault lines, so every other Today row now holds a
        // stale line index. Force a re-scan so the next completion acts on fresh
        // positions (the content-relocation guard tolerates drift, but this keeps
        // the list itself accurate — e.g. tasks completed elsewhere disappear).
        await refreshAgenda(force: true)
    }

    // MARK: - Diff preview (forced dry-run)

    /// Run a forced dry-run across all enabled profiles and stash the aggregated
    /// result in `previewResult` for the UI to display. Mutates nothing on disk
    /// (dry-run skips every write and state save). (Diff preview)
    func startPreview() async {
        guard !isSyncing, !isPreviewing else { return }
        updateSourceAndDestination()
        let enabled = profileStore.enabledProfiles
        guard !enabled.isEmpty else {
            showErrorMessage("No sync profiles are enabled. Enable a profile in Settings.")
            return
        }
        if enabled.contains(where: { $0.id == profileStore.activeProfileId }) {
            _ = ensureActiveVaultAccess()
        }

        isPreviewing = true
        previewResult = nil
        statusMessage = "Previewing changes…"

        var aggregate = SyncEngine.SyncResult()
        aggregate.isDryRun = true
        for profile in enabled {
            let result = await previewSingleProfile(profile)
            aggregate = SyncManager.mergeResults(aggregate, result)
        }

        previewResult = aggregate
        isPreviewing = false
        statusMessage = "Preview ready: \(aggregate.summary)"
    }

    private func previewSingleProfile(_ profile: SyncProfile) async -> SyncEngine.SyncResult {
        let cfg = profile.config.deepCopy()
        cfg.dryRunMode = true
        var pre = SyncEngine.SyncResult()
        pre.isDryRun = true

        guard !cfg.vaultPath.isEmpty else {
            pre.errors.append(ProfileSyncIssue.notConfigured(profile.name)); return pre
        }
        if !FileManager.default.isReadableFile(atPath: cfg.vaultPath),
           !resolveVaultBookmark(forPath: cfg.vaultPath),
           !FileManager.default.isReadableFile(atPath: cfg.vaultPath) {
            pre.errors.append(ProfileSyncIssue.vaultAccess(profile.name, cfg.vaultPath)); return pre
        }
        let source = SyncManager.createSource(for: cfg.taskSourceType, config: cfg)
        let destination = SyncManager.createDestination(for: cfg.taskDestinationType, config: cfg)
        let access = (try? await destination.requestAccess()) ?? false
        guard access else {
            pre.errors.append(ProfileSyncIssue.destinationAccess(profile.name, destination.destinationName)); return pre
        }
        // Dry-run engine — never writes mappings or files (Step 7 + edits are
        // gated on !dryRunMode), so this is purely read-only.
        let engine = SyncEngine(source: source, destination: destination,
                                stateLocation: cfg.syncStateLocation, vaultPath: cfg.vaultPath,
                                profileKey: profile.stateKey)
        return await engine.performSync(config: cfg) { [weak self] message in
            Task { @MainActor in self?.statusMessage = "Preview: \(message)" }
        }
    }

    /// Ensure the active profile's vault is readable. When `interactive`, falls
    /// back to a modal vault-picker; otherwise resolves the bookmark silently
    /// and returns false on failure (never pops a dialog). (audit #14)
    @discardableResult
    private func ensureActiveVaultAccess(interactive: Bool = true) -> Bool {
        guard !config.vaultPath.isEmpty else { return false }
        if FileManager.default.isReadableFile(atPath: config.vaultPath) { return true }
        debugLog("[SyncManager] Active vault not readable, attempting to resolve bookmark...")
        if resolveVaultBookmark() { return true }
        guard interactive else {
            debugLog("[SyncManager] Vault not readable (non-interactive) — skipping picker.")
            return false
        }
        debugLog("[SyncManager] Bookmark resolution failed, auto-prompting vault re-selection")
        selectVaultPath()
        return !config.vaultPath.isEmpty && FileManager.default.isReadableFile(atPath: config.vaultPath)
    }

    /// Sync one profile, building (or reusing, for the active profile) its
    /// engine and verifying vault + destination access first.
    private func syncSingleProfile(_ profile: SyncProfile, isActive: Bool) async -> SyncEngine.SyncResult {
        let cfg = profile.config
        var pre = SyncEngine.SyncResult()
        pre.isDryRun = cfg.dryRunMode

        guard !cfg.vaultPath.isEmpty else {
            pre.errors.append(ProfileSyncIssue.notConfigured(profile.name)); return pre
        }
        if !FileManager.default.isReadableFile(atPath: cfg.vaultPath),
           !resolveVaultBookmark(forPath: cfg.vaultPath),
           !FileManager.default.isReadableFile(atPath: cfg.vaultPath) {
            pre.errors.append(ProfileSyncIssue.vaultAccess(profile.name, cfg.vaultPath)); return pre
        }

        let source = isActive ? taskSource : SyncManager.createSource(for: cfg.taskSourceType, config: cfg)
        let destination = isActive ? taskDestination : SyncManager.createDestination(for: cfg.taskDestinationType, config: cfg)

        let access = (try? await destination.requestAccess()) ?? false
        if isActive { hasDestinationAccess = access }
        guard access else {
            pre.errors.append(ProfileSyncIssue.destinationAccess(profile.name, destination.destinationName)); return pre
        }

        let engine = isActive
            ? syncEngine
            : SyncEngine(source: source, destination: destination,
                         stateLocation: cfg.syncStateLocation, vaultPath: cfg.vaultPath,
                         profileKey: profile.stateKey)
        return await engine.performSync(config: cfg) { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
    }

    /// Combine two sync results into one aggregate (counts summed, lists concatenated).
    private static func mergeResults(_ a: SyncEngine.SyncResult, _ b: SyncEngine.SyncResult) -> SyncEngine.SyncResult {
        var r = SyncEngine.SyncResult()
        r.created = a.created + b.created
        r.updated = a.updated + b.updated
        r.deleted = a.deleted + b.deleted
        r.completionsWrittenBack = a.completionsWrittenBack + b.completionsWrittenBack
        r.metadataWrittenBack = a.metadataWrittenBack + b.metadataWrittenBack
        r.conflicts = a.conflicts + b.conflicts
        r.errors = a.errors + b.errors
        r.details = a.details + b.details
        r.isDryRun = a.isDryRun || b.isDryRun
        r.duration = a.duration + b.duration
        return r
    }

    /// Apply the aggregated result to published state, logging, and notifications.
    private func finalizeSyncResult(_ result: SyncEngine.SyncResult, wasFirstSync: Bool) {
        debugLog("[SyncManager] Sync complete: \(result.summary), errors: \(result.errors.count), details: \(result.details.count)")
        lastSyncResult = result
        lastSyncDate = Date()
        pendingConflicts = result.conflicts
        isFirstSync = false
        syncLog.addEntry(from: result)

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
            var seen = Set<String>()
            var uniqueMessages: [String] = []
            for error in result.errors {
                let msg = error.localizedDescription
                if seen.insert(msg).inserted { uniqueMessages.append(msg) }
            }
            let errorSummary = uniqueMessages.joined(separator: "\n")
            let countNote = result.errors.count > uniqueMessages.count ? " (\(result.errors.count) total)" : ""
            showErrorMessage("Sync completed with errors\(countNote):\n\(errorSummary)")
            statusMessage = "Sync completed with \(result.errors.count) error\(result.errors.count == 1 ? "" : "s")"
        }
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
                await self?.performSync(interactive: false)
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
                    await self?.performSync(interactive: false)
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
                    await self?.performSync(interactive: false)
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
                // Also store keyed by path so other profiles pointing at this
                // same vault can resolve access without re-prompting. (multi-profile)
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey(forPath: url.path))
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

    /// UserDefaults key for a per-vault-path security-scoped bookmark.
    static func bookmarkKey(forPath path: String) -> String { "vaultBookmark::\(path)" }

    /// Resolve a security-scoped bookmark for a specific vault path (non-active
    /// profiles). Best-effort, no prompting. Returns true if access started.
    @discardableResult
    func resolveVaultBookmark(forPath path: String) -> Bool {
        let data = UserDefaults.standard.data(forKey: Self.bookmarkKey(forPath: path))
            ?? (path == config.vaultPath ? UserDefaults.standard.data(forKey: "vaultBookmark") : nil)
        guard let data = data else { return false }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale else { return false }
        return url.startAccessingSecurityScopedResource()
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
                persistAndApplyConfigChange() // writes profiles.json, not just the legacy config.json (audit #16)

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
        persistAndApplyConfigChange() // persist to profiles.json (audit #16)
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

    // MARK: - Maintenance: remove duplicate reminders (Apple Reminders only)

    /// Count duplicate reminders that "Remove Duplicate Reminders" would delete
    /// (a dry run). Returns 0 if the active destination isn't Apple Reminders.
    func previewDuplicateReminders() async -> Int {
        updateSourceAndDestination()
        guard let dest = taskDestination as? RemindersDestination else { return 0 }
        return (try? await dest.removeDuplicateReminders(dryRun: true)) ?? 0
    }

    /// Delete duplicate reminders. Returns the number removed.
    @discardableResult
    func removeDuplicateReminders() async -> Int {
        guard let dest = taskDestination as? RemindersDestination else { return 0 }
        let removed = (try? await dest.removeDuplicateReminders(dryRun: false)) ?? 0
        statusMessage = "Removed \(removed) duplicate reminder\(removed == 1 ? "" : "s")"
        debugLog("[SyncManager] Removed \(removed) duplicate reminders")
        return removed
    }

    // MARK: - Error Handling

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
