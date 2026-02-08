import Foundation
import SwiftUI
import Combine

/// Write diagnostic logs to a file (since print/NSLog may not be visible from sandboxed GUI apps)
func debugLog(_ message: String) {
    let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Obsync", isDirectory: true)
        .appendingPathComponent("debug.log")
    try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    @Published var hasRemindersAccess = false
    @Published var pendingConflicts: [SyncEngine.SyncConflict] = []
    @Published var availableLists: [String] = []
    @Published var statusMessage: String = "Ready"
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var syncLog: SyncLog

    // MARK: - Private

    private let syncEngine = SyncEngine()
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isFirstSync = true
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Initialization

    private init() {
        self.config = SyncConfiguration.load()
        self.syncLog = SyncLog.load()
        setupAutoSync()
        setupConfigObserver()
        setupAppearanceObserver()
    }

    private func setupConfigObserver() {
        $config
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] config in
                config.save()
                self?.setupAutoSync()
                self?.updateHotKey()
            }
            .store(in: &cancellables)
    }

    private func setupAppearanceObserver() {
        // Observe system appearance changes to update the dock icon
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDockIcon()
            }
        }
    }

    // MARK: - Access Request

    func requestRemindersAccess() async {
        do {
            debugLog("[SyncManager] Requesting Reminders access...")
            hasRemindersAccess = try await syncEngine.requestRemindersAccess()
            debugLog("[SyncManager] Reminders access: \(hasRemindersAccess)")
            if hasRemindersAccess {
                refreshLists()
                debugLog("[SyncManager] Available lists: \(availableLists)")
                if config.syncOnLaunch && !config.vaultPath.isEmpty {
                    debugLog("[SyncManager] Sync on launch triggered")
                    await performSync()
                } else {
                    debugLog("[SyncManager] Sync on launch skipped: syncOnLaunch=\(config.syncOnLaunch), vaultPath='\(config.vaultPath)'")
                }
            }
        } catch {
            hasRemindersAccess = false
            debugLog("[SyncManager] Reminders access failed: \(error.localizedDescription)")
            showErrorMessage("Failed to get Reminders access: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Operations

    func performSync() async {
        guard !isSyncing else {
            debugLog("[SyncManager] Skipped: already syncing")
            return
        }
        guard hasRemindersAccess else {
            showErrorMessage("No access to Reminders. Please grant permission in System Settings.")
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
        let result = await syncEngine.performSync(config: config)
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
            let errorMessages = result.errors.map { $0.localizedDescription }.joined(separator: "\n")
            showErrorMessage("Sync completed with errors:\n\(errorMessages)")
            statusMessage = "Sync completed with \(result.errors.count) errors"
        }

        isSyncing = false
    }

    // MARK: - Conflict Resolution

    func resolveConflict(_ conflict: SyncEngine.SyncConflict, choice: SyncEngine.SyncConflict.ConflictResolutionChoice) {
        do {
            try syncEngine.resolveConflict(conflict, with: choice, config: config)
            pendingConflicts.removeAll { $0.task.id == conflict.task.id }
        } catch {
            showErrorMessage("Failed to resolve conflict: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Sync

    private func setupAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil

        guard config.enableAutoSync else { return }

        let interval = TimeInterval(config.syncIntervalMinutes * 60)
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

    // MARK: - List Management

    func refreshLists() {
        availableLists = syncEngine.getReminderLists()
        debugLog("[SyncManager] Refreshed lists: \(availableLists)")
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

    func resetSyncState() {
        syncEngine.resetSyncState()
        lastSyncResult = nil
        lastSyncDate = nil
        pendingConflicts = []
        statusMessage = "Sync state reset"
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
