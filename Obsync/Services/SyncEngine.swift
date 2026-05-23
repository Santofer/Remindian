import Foundation
import Combine

/// Core sync engine that handles synchronization.
/// Uses protocol-based TaskSource and TaskDestination for extensibility.
/// The source is always the source of truth. Writeback to the source is opt-in.
class SyncEngine {
    private let source: TaskSource
    private let destination: TaskDestination
    private let backupService = FileBackupService.shared
    private var syncState: SyncState

    /// Production init — loads sync state from disk.
    convenience init(source: TaskSource, destination: TaskDestination) {
        self.init(source: source, destination: destination, syncState: SyncState.load())
    }

    /// Designated init exposing the SyncState seam so tests can drive
    /// `performSync(...)` without touching the real Application Support
    /// directory. Production callers should use the convenience init above.
    init(source: TaskSource, destination: TaskDestination, syncState: SyncState) {
        self.source = source
        self.destination = destination
        self.syncState = syncState
    }

    // Mutex to prevent concurrent sync operations
    private let syncLock = NSLock()
    private var _isSyncing = false
    private var _cancellationRequested = false

    var isSyncing: Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return _isSyncing
    }

    /// Request cancellation of the current sync operation (#26).
    func requestCancellation() {
        syncLock.lock()
        _cancellationRequested = true
        syncLock.unlock()
    }

    /// Check if cancellation was requested.
    private var isCancelled: Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return _cancellationRequested
    }

    // MARK: - Result Types

    struct SyncResult {
        var created: Int = 0
        var updated: Int = 0
        var deleted: Int = 0
        var completionsWrittenBack: Int = 0
        var metadataWrittenBack: Int = 0
        var conflicts: [SyncConflict] = []
        var errors: [Error] = []
        var details: [SyncLogDetail] = []
        var isDryRun: Bool = false
        var duration: TimeInterval = 0

        var summary: String {
            var parts: [String] = []
            if isDryRun { parts.append("[DRY RUN]") }
            if created > 0 { parts.append("\(created) created") }
            if updated > 0 { parts.append("\(updated) updated") }
            if deleted > 0 { parts.append("\(deleted) deleted") }
            if completionsWrittenBack > 0 { parts.append("\(completionsWrittenBack) completed in Obsidian") }
            if metadataWrittenBack > 0 { parts.append("\(metadataWrittenBack) metadata written to Obsidian") }
            if conflicts.count > 0 { parts.append("\(conflicts.count) conflicts") }
            if errors.count > 0 { parts.append("\(errors.count) errors") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
        }
    }

    struct SyncLogDetail: Codable {
        let action: ActionType
        let taskTitle: String
        let filePath: String?
        let errorMessage: String?

        enum ActionType: String, Codable {
            case created
            case updated
            case deleted
            case completionWriteback
            case metadataWriteback
            case error
            case skipped
        }
    }

    struct SyncConflict {
        let task: SyncTask
        let obsidianVersion: SyncTask
        let remindersVersion: SyncTask
        var resolution: ConflictResolutionChoice?

        enum ConflictResolutionChoice {
            case useObsidian
            case useReminders
            case merge(SyncTask)
        }
    }

    // MARK: - Filters

    /// Compute the completed-task age cutoff for this sync. Returns nil when
    /// the filter is disabled (`maxCompletedTaskAgeDays <= 0`).
    ///
    /// Computed once per sync — callers pass the resulting cutoff into
    /// `isCompletedTaskTooOld(_:cutoff:)` for every task. This keeps the cutoff
    /// stable across all tasks evaluated in the same sync (rather than
    /// re-sampling `Date()` per task) and concentrates the calendar-arithmetic
    /// fallback in one place.
    ///
    /// The `.distantPast` fallback (used when `Calendar.current.date(byAdding:)`
    /// returns nil) means a calendar-arithmetic failure degrades to "keep
    /// everything" — anything compared against `distantPast` with `<=` is false.
    /// The earlier `?? Date()` fallback had the opposite effect: cutoff = now
    /// silently filtered every completed task.
    static func completedTaskCutoffDate(for config: SyncConfiguration) -> Date? {
        guard config.maxCompletedTaskAgeDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -config.maxCompletedTaskAgeDays, to: Date()) ?? .distantPast
    }

    /// True if a completed task is older than the supplied cutoff and should
    /// be excluded from sync. Uncompleted tasks and a nil cutoff (filter
    /// disabled) always return false. Falls back to `lastModified` when
    /// `completedDate` is missing — matches the legacy source-scan behavior.
    ///
    /// Used in two places: the source scan (Step 1) and the Reminders → Obsidian
    /// writeback loop (Step 6). Without applying it on both sides, a user with
    /// `enableNewTaskWriteback = true` and a long history of completed reminders
    /// gets every old completion written into the vault on next sync — exactly
    /// the symptom #11 was filed for.
    static func isCompletedTaskTooOld(_ task: SyncTask, cutoff: Date?) -> Bool {
        guard let cutoff, task.isCompleted else { return false }
        if let completedDate = task.completedDate {
            return completedDate <= cutoff
        }
        return task.lastModified <= cutoff
    }

    // MARK: - Main Sync

    /// Perform sync: Source -> Destination (source is the source of truth).
    /// Optionally writes completion status back to source (surgical edit only).
    func performSync(config: SyncConfiguration, onProgress: ((String) -> Void)? = nil) async -> SyncResult {
        let startTime = Date()
        var result = SyncResult()
        result.isDryRun = config.dryRunMode

        // Acquire sync lock
        syncLock.lock()
        guard !_isSyncing else {
            syncLock.unlock()
            result.errors.append(SyncError.syncAlreadyInProgress)
            return result
        }
        _isSyncing = true
        _cancellationRequested = false
        syncLock.unlock()

        defer {
            syncLock.lock()
            _isSyncing = false
            syncLock.unlock()
            result.duration = Date().timeIntervalSince(startTime)
        }

        // Validate vault path
        guard !config.vaultPath.isEmpty else {
            result.errors.append(SyncError.noVaultConfigured)
            return result
        }

        guard FileManager.default.fileExists(atPath: config.vaultPath) else {
            result.errors.append(SyncError.vaultPathNotFound(config.vaultPath))
            return result
        }

        // Only check for .obsidian directory when using Obsidian Tasks source
        if config.taskSourceType == .obsidianTasks {
            let obsidianDir = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(".obsidian")
            guard FileManager.default.fileExists(atPath: obsidianDir.path) else {
                result.errors.append(SyncError.notAnObsidianVault(config.vaultPath))
                return result
            }
        }

        // Reset the destination's internal cache before syncing to clear stale state
        // (prevents errors like ReminderKit -3002 from lingering across syncs)
        destination.refresh()
        debugLog("[SyncEngine] Destination cache refreshed")

        do {
            // Step 1: Get all tasks from source
            onProgress?("Scanning vault...")
            debugLog("[SyncEngine] Scanning source: \(source.sourceName)")
            debugLog("[SyncEngine] Vault: \(config.vaultPath), excluded: \(config.excludedFolders), included: \(config.includedFolders)")
            var obsidianTasks = try source.scanTasks(config: config)
            debugLog("[SyncEngine] Found \(obsidianTasks.count) source tasks")

            // Filter out old completed tasks if configured
            if let sourceCutoff = SyncEngine.completedTaskCutoffDate(for: config) {
                let beforeCount = obsidianTasks.count
                obsidianTasks = obsidianTasks.filter { !SyncEngine.isCompletedTaskTooOld($0, cutoff: sourceCutoff) }
                let filtered = beforeCount - obsidianTasks.count
                if filtered > 0 {
                    debugLog("[SyncEngine] Filtered out \(filtered) completed tasks older than \(config.maxCompletedTaskAgeDays) days")
                }
            }
            // Filter tasks with excluded tags (#47)
            if !config.excludedTags.isEmpty {
                let excludedLower = Set(config.excludedTags.map {
                    $0.hasPrefix("#") ? String($0.dropFirst()).lowercased() : $0.lowercased()
                })
                let beforeCount = obsidianTasks.count
                obsidianTasks = obsidianTasks.filter { task in
                    let taskTagsLower = task.tags.map {
                        $0.hasPrefix("#") ? String($0.dropFirst()).lowercased() : $0.lowercased()
                    }
                    return !taskTagsLower.contains(where: { excludedLower.contains($0) })
                }
                let filtered = beforeCount - obsidianTasks.count
                if filtered > 0 {
                    debugLog("[SyncEngine] Filtered \(filtered) tasks with excluded tags: \(config.excludedTags)")
                }
            }

            for (i, task) in obsidianTasks.prefix(5).enumerated() {
                debugLog("[SyncEngine]   Task \(i): \"\(task.title)\" completed=\(task.isCompleted) file=\(task.obsidianSource?.filePath ?? "?")")
            }
            if obsidianTasks.count > 5 {
                debugLog("[SyncEngine]   ... and \(obsidianTasks.count - 5) more")
            }

            // Check for cancellation (#26)
            if isCancelled {
                debugLog("[SyncEngine] Sync cancelled after source scan")
                result.errors.append(SyncError.syncCancelled)
                return result
            }

            // Capture file timestamps AFTER vault scan completes.
            // Any edits saved by Obsidian before/during the scan are already
            // reflected in our task data, so they shouldn't block writeback.
            let syncStartTimestamp = Date()

            // Step 2: Get all tasks from destination
            onProgress?("Fetching from \(destination.destinationName)...")
            debugLog("[SyncEngine] Fetching from destination: \(destination.destinationName)...")

            // Wire the granular progress callback so destinations that do
            // per-list fetching (e.g. Things 3, which iterates Today/Inbox/
            // Anytime/Upcoming/Someday/Logbook) can surface which list is in
            // flight. Cleared after fetch to avoid holding a stale closure. (#56)
            destination.progressCallback = onProgress
            defer { destination.progressCallback = nil }

            var remindersTasks = try await destination.fetchAllTasks()
            debugLog("[SyncEngine] Found \(remindersTasks.count) destination tasks")

            // Surface non-fatal per-list fetch warnings from the destination
            // (e.g. a single Things 3 list timed out but the rest succeeded).
            // These appear in the sync result errors so the user knows which
            // list was skipped without the sync being marked as a total failure.
            if let things3 = destination as? Things3Destination,
               !things3.lastFetchWarnings.isEmpty {
                for warning in things3.lastFetchWarnings {
                    result.errors.append(warning)
                    result.details.append(SyncLogDetail(
                        action: .skipped,
                        taskTitle: "List fetch",
                        filePath: nil,
                        errorMessage: warning.localizedDescription
                    ))
                }
            }

            // Build a set of already-mapped destination task IDs so we never
            // filter them out. This is important for completed tasks that moved
            // to a different list (e.g. Things 3 Logbook) — they must still be
            // visible to the sync engine for completion writeback to work.
            let mappedDestinationIds = Set(syncState.mappings.map { $0.remindersId })

            // Filter by synced Reminders lists if configured (whitelist)
            if !config.syncedRemindersLists.isEmpty {
                let allowedLists = Set(config.syncedRemindersLists.map { $0.lowercased() })
                let beforeCount = remindersTasks.count
                remindersTasks = remindersTasks.filter { task in
                    // Always keep already-mapped tasks (completion writeback needs them)
                    if let id = task.remindersId, mappedDestinationIds.contains(id) { return true }
                    guard let list = task.targetList else { return false }
                    return allowedLists.contains(list.lowercased())
                }
                debugLog("[SyncEngine] Filtered destination tasks to allowed lists: \(beforeCount) → \(remindersTasks.count)")
            }

            // Filter out excluded Reminders lists (#21)
            if !config.excludedRemindersLists.isEmpty {
                let excludedLists = Set(config.excludedRemindersLists.map { $0.lowercased() })
                let beforeCount = remindersTasks.count
                remindersTasks = remindersTasks.filter { task in
                    // Always keep already-mapped tasks (completion writeback needs them)
                    if let id = task.remindersId, mappedDestinationIds.contains(id) { return true }
                    guard let list = task.targetList else { return true }
                    return !excludedLists.contains(list.lowercased())
                }
                debugLog("[SyncEngine] Filtered out excluded lists: \(beforeCount) → \(remindersTasks.count)")
            }

            // Step 3: Build lookup maps
            onProgress?("Comparing \(obsidianTasks.count) tasks...")
            var obsidianMap: [String: SyncTask] = [:]
            for task in obsidianTasks {
                let id = source.generateTaskId(for: task)
                obsidianMap[id] = task
            }
            debugLog("[SyncEngine] Obsidian map has \(obsidianMap.count) unique IDs (from \(obsidianTasks.count) tasks)")

            // Build remindersMap early so pass (a) dedup can consult reminder state
            // (needed to detect recurring-task completion events — see #57).
            var remindersMap: [String: SyncTask] = [:]
            for task in remindersTasks {
                if let id = task.remindersId {
                    remindersMap[id] = task
                }
            }

            // Step 3b: Deduplicate tasks with the same title across the vault.
            //
            // Two dedup passes:
            //  (a) Same-file recurring: completed [x] + uncompleted [ ] with same title
            //      in the same file → drop the completed copy (it's just history).
            //  (b) Cross-file duplicates: identical title appears in multiple files
            //      (e.g. Inbox.md writeback + original file). Keep only one copy,
            //      preferring: uncompleted > completed, non-Inbox > Inbox, earlier mapping.
            var idsToRemove: Set<String> = []

            // --- Pass (a): same-file recurring pairs ---
            // The Obsidian Tasks plugin inserts a new uncompleted occurrence above
            // the just-completed copy (e.g. after marking "Pay rent 🔁 every month"
            // complete, the file has both `- [ ] Pay rent 🔁 …` and `- [x] Pay rent 🔁 …`).
            // Normally we drop the completed sibling so we don't try to sync it
            // separately. BUT if the completed copy has an existing mapping (i.e.
            // this is a brand-new completion event we haven't propagated yet), we
            // MUST keep it in the map so the mapping loop below detects the
            // completion and writes it to the destination. The Step 5 "new tasks"
            // loop has a matching recurring-sibling-inherit step that reuses the
            // mapping on the uncompleted copy, so no duplicate gets created. (#57)
            var activeTasksByFileAndTitle: [String: String] = [:]  // "file|title" → obsidianId
            for (id, task) in obsidianMap {
                if !task.isCompleted, let filePath = task.obsidianSource?.filePath {
                    let key = "\(filePath)|\(task.title)"
                    activeTasksByFileAndTitle[key] = id
                }
            }
            for (id, task) in obsidianMap {
                if task.isCompleted, let filePath = task.obsidianSource?.filePath {
                    let key = "\(filePath)|\(task.title)"
                    if activeTasksByFileAndTitle[key] != nil {
                        // For RECURRING tasks, keep the completed copy in the map.
                        // The mapping loop needs to see it to propagate the completion
                        // to the destination (scenario 1 in #57); Step 5's
                        // recurring-sibling inheritance then transfers the mapping
                        // to the new uncompleted occurrence without creating a dup.
                        // For non-recurring tasks (e.g. one-off tasks duplicated in
                        // the same file by mistake), keep the original dedup behavior.
                        if task.recurrenceRule != nil {
                            continue
                        }
                        idsToRemove.insert(id)
                        debugLog("[SyncEngine] Dedup: same-file pair → skipping completed \"\(task.title)\" in \(filePath)")
                    }
                }
            }

            // --- Pass (b): cross-file duplicates (same title, different files) ---
            // Only dedup when at least one copy is in Inbox.md (writeback artifact).
            // Identical titles in different non-Inbox files are intentional (#46)
            // and should each get their own destination task.
            let inboxSuffix = "/Inbox.md"
            var tasksByTitle: [String: [(id: String, task: SyncTask)]] = [:]
            for (id, task) in obsidianMap where !idsToRemove.contains(id) {
                tasksByTitle[task.title, default: []].append((id: id, task: task))
            }
            for (title, entries) in tasksByTitle where entries.count > 1 {
                // Only dedup if at least one entry is from Inbox.md
                let hasInboxCopy = entries.contains { ($0.task.obsidianSource?.filePath ?? "").hasSuffix(inboxSuffix) }
                guard hasInboxCopy else { continue }

                // Multiple copies including an Inbox copy — keep the non-Inbox one.
                // Scoring: uncompleted > completed, non-Inbox > Inbox, has existing mapping > no mapping
                let sorted = entries.sorted { a, b in
                    let aCompleted = a.task.isCompleted ? 1 : 0
                    let bCompleted = b.task.isCompleted ? 1 : 0
                    if aCompleted != bCompleted { return aCompleted < bCompleted }

                    let aInbox = (a.task.obsidianSource?.filePath ?? "").hasSuffix(inboxSuffix) ? 1 : 0
                    let bInbox = (b.task.obsidianSource?.filePath ?? "").hasSuffix(inboxSuffix) ? 1 : 0
                    if aInbox != bInbox { return aInbox < bInbox }

                    // Prefer the one that already has a sync mapping
                    let aHasMapping = syncState.mappings.contains { $0.obsidianId == a.id } ? 0 : 1
                    let bHasMapping = syncState.mappings.contains { $0.obsidianId == b.id } ? 0 : 1
                    return aHasMapping < bHasMapping
                }
                // Keep first (best), remove the Inbox duplicates
                for entry in sorted.dropFirst() {
                    idsToRemove.insert(entry.id)
                    debugLog("[SyncEngine] Dedup: cross-file → skipping \"\(title)\" in \(entry.task.obsidianSource?.filePath ?? "?")")
                }
            }

            // Remove all duplicates from the map
            for id in idsToRemove {
                obsidianMap.removeValue(forKey: id)
            }
            if !idsToRemove.isEmpty {
                debugLog("[SyncEngine] Removed \(idsToRemove.count) duplicate tasks total")
            }

            debugLog("[SyncEngine] Existing mappings: \(syncState.mappings.count)")

            // Safety check: if source task count dropped by >50% compared to
            // existing mappings, something might be wrong (vault unmounted, scan failure).
            // Abort to prevent mass deletion of destination tasks.
            let existingMappingCount = syncState.mappings.count
            if existingMappingCount > 10 && obsidianMap.count < existingMappingCount / 2 {
                debugLog("[SyncEngine] SAFETY: Source task count (\(obsidianMap.count)) is <50% of existing mappings (\(existingMappingCount)). Aborting to prevent mass deletion.")
                result.errors.append(SyncError.safetyAbort(
                    "Source returned \(obsidianMap.count) tasks but \(existingMappingCount) are mapped. This might indicate a scan failure. Sync aborted to protect your data."
                ))
                return result
            }

            // Check for cancellation (#26)
            if isCancelled {
                debugLog("[SyncEngine] Sync cancelled before processing")
                result.errors.append(SyncError.syncCancelled)
                return result
            }

            // Step 4: Process existing mappings
            var processedObsidianIds: Set<String> = []
            var relinkedRemindersIds: Set<String> = []  // Track re-linked reminders to prevent duplicate deletion

            // Track recurrence insertions per file: when markTaskComplete inserts a
            // recurrence line, tasks BELOW that point shift down by 1. We record the
            // original line number of each insertion so we can compute position-aware
            // offsets (only tasks at or below the insertion point are affected).
            var fileInsertions: [String: [Int]] = [:]

            // Tasks that had completion writeback in this cycle. Their vault line
            // content changed (- [ ] → - [x] + ✅), making originalLine stale for
            // any subsequent metadata writeback on the same task.
            var completionWritebackIds: Set<String> = Set()

            for mapping in syncState.mappings {
                let obsidianTask = obsidianMap[mapping.obsidianId]
                let remindersTask = remindersMap[mapping.remindersId]

                switch (obsidianTask, remindersTask) {
                case (.some(let oTask), .some(let rTask)):
                    // Both exist - check what changed
                    let oHash = SyncState.generateTaskHash(oTask)
                    let rHash = SyncState.generateTaskHash(rTask)
                    let oChanged = mapping.hasObsidianChanged(currentHash: oHash)
                    let rChanged = mapping.hasRemindersChanged(currentHash: rHash)

                    // Check if completion status differs between Obsidian and Reminders.
                    // This should trigger writeback regardless of oChanged, because oChanged
                    // can be true due to metadata changes unrelated to completion.
                    let completionDiffers = rTask.isCompleted != oTask.isCompleted

                    // Pre-check file modification for writeback safety
                    // (computed once before any writes to avoid false positives from our own edits)
                    let fileNotModifiedBeforeSync: Bool = {
                        return !source.hasFileChanged(
                            task: oTask,
                            since: syncStartTimestamp,
                            config: config
                        )
                    }()

                    // Debug: log changes
                    if completionDiffers {
                        debugLog("[SyncEngine] Completion diff for \"\(oTask.title)\": obsidian=\(oTask.isCompleted), reminders=\(rTask.isCompleted), oChanged=\(oChanged)")
                    }
                    if rChanged && !oChanged {
                        debugLog("[SyncEngine] Reminders changed for \"\(oTask.title)\": rChanged=\(rChanged), oChanged=\(oChanged)")
                    }

                    // Backfill obsidian:// URL if the setting is on but the reminder doesn't have one yet.
                    // This handles the case where addTaskLinkToReminders was enabled after tasks were already synced.
                    let needsURLBackfill = config.addTaskLinkToReminders
                        && oTask.obsidianSource != nil
                        && !config.vaultPath.isEmpty
                        && (rTask.url == nil || rTask.url?.scheme != "obsidian")

                    if oChanged || completionDiffers || rChanged || needsURLBackfill {
                        do {
                            var taskForReminders = oTask

                            // If only Reminders changed (not Obsidian), preserve the
                            // Reminders values so we don't revert the user's edits.
                            // The metadata writeback will selectively write enabled
                            // fields back to Obsidian.
                            if rChanged && !oChanged && !completionDiffers {
                                taskForReminders.dueDate = rTask.dueDate
                                taskForReminders.startDate = rTask.startDate
                                taskForReminders.priority = rTask.priority
                            }

                            // If completed in Reminders but not in Obsidian, keep it completed
                            // and write back to Obsidian (including recurrence handling)
                            if completionDiffers && rTask.isCompleted && !oTask.isCompleted {
                                taskForReminders.isCompleted = true
                                taskForReminders.completedDate = rTask.completedDate
                                debugLog("[SyncEngine] Task completed in Reminders: \"\(oTask.title)\", writeback enabled=\(config.enableCompletionWriteback), vaultPath=\(config.vaultPath)")

                                // Write completion back to Obsidian (surgical edit)
                                if config.enableCompletionWriteback {
                                        // Check file hasn't changed since sync started
                                    if !fileNotModifiedBeforeSync {
                                        result.errors.append(ObsidianError.fileModifiedDuringSync)
                                        result.details.append(SyncLogDetail(
                                            action: .error,
                                            taskTitle: oTask.title,
                                            filePath: oTask.obsidianSource?.filePath,
                                            errorMessage: "File modified during sync"
                                        ))
                                    } else if !config.dryRunMode {
                                        // Build an adjusted task: only count recurrence insertions
                                        // that occurred at or above this task's original line.
                                        var adjustedTask = oTask
                                        if let src = oTask.obsidianSource {
                                            let insertions = fileInsertions[src.filePath] ?? []
                                            let offset = insertions.filter { $0 <= src.lineNumber }.count
                                            adjustedTask.obsidianSource = SyncTask.ObsidianSource(
                                                filePath: src.filePath,
                                                lineNumber: src.lineNumber + offset,
                                                originalLine: src.originalLine
                                            )
                                        }
                                        debugLog("[SyncEngine] Writing completion back: \"\(oTask.title)\"")
                                        let inserted = try source.markTaskComplete(
                                            task: adjustedTask,
                                            completionDate: rTask.completedDate ?? Date(),
                                            config: config
                                        )
                                        if inserted > 0, let src = oTask.obsidianSource {
                                            fileInsertions[src.filePath, default: []].append(src.lineNumber)
                                        }
                                        completionWritebackIds.insert(mapping.obsidianId)
                                        debugLog("[SyncEngine] Completion writeback succeeded for: \"\(oTask.title)\" (lines inserted: \(inserted))")
                                        result.completionsWrittenBack += 1
                                        result.details.append(SyncLogDetail(
                                            action: .completionWriteback,
                                            taskTitle: oTask.title,
                                            filePath: oTask.obsidianSource?.filePath,
                                            errorMessage: nil
                                        ))
                                    } else {
                                        result.completionsWrittenBack += 1
                                        result.details.append(SyncLogDetail(
                                            action: .completionWriteback,
                                            taskTitle: "[DRY RUN] " + oTask.title,
                                            filePath: oTask.obsidianSource?.filePath,
                                            errorMessage: nil
                                        ))
                                    }
                                }
                            }

                            // Handle: completed in Obsidian, incomplete in Reminders.
                            // Obsidian is the source of truth — update Reminders to match.
                            // DO NOT revert Obsidian's completion state (#16).
                            if completionDiffers && !rTask.isCompleted && oTask.isCompleted {
                                taskForReminders.isCompleted = true
                                taskForReminders.completedDate = oTask.completedDate ?? Date()
                                debugLog("[SyncEngine] Task completed in Obsidian, updating Reminders: \"\(oTask.title)\"")
                            }

                            // MARK: Metadata writeback (due date, start date, priority)
                            // Write back when Reminders changed but Obsidian didn't
                            // (meaning the change originated from Reminders, not Obsidian).
                            // All changes are applied atomically in a single file write.
                            // Skip if completion writeback already modified this task's
                            // vault line — originalLine is stale and the task is done.
                            if rChanged && !oChanged && !completionWritebackIds.contains(mapping.obsidianId) {
                                if fileNotModifiedBeforeSync {
                                    var metadataChanges = MetadataChanges()
                                    var changeDescriptions: [String] = []

                                    // Due date writeback
                                    let dueDateDiffers = !datesAreEqualByDay(rTask.dueDate, oTask.dueDate)
                                    if dueDateDiffers && config.enableDueDateWriteback {
                                        debugLog("[SyncEngine] Due date changed in destination for \"\(oTask.title)\"")
                                        metadataChanges.newDueDate = .some(rTask.dueDate)
                                        taskForReminders.dueDate = rTask.dueDate
                                        changeDescriptions.append("Due date → \(rTask.dueDate.map { DateFormatter.obsidianDateFormatter.string(from: $0) } ?? "removed")")
                                    }

                                    // Start date writeback
                                    let startDateDiffers = !datesAreEqualByDay(rTask.startDate, oTask.startDate)
                                    if startDateDiffers && config.enableStartDateWriteback {
                                        debugLog("[SyncEngine] Start date changed in destination for \"\(oTask.title)\"")
                                        metadataChanges.newStartDate = .some(rTask.startDate)
                                        taskForReminders.startDate = rTask.startDate
                                        changeDescriptions.append("Start date → \(rTask.startDate.map { DateFormatter.obsidianDateFormatter.string(from: $0) } ?? "removed")")
                                    }

                                    // Priority writeback
                                    if rTask.priority != oTask.priority && config.enablePriorityWriteback {
                                        debugLog("[SyncEngine] Priority changed in destination for \"\(oTask.title)\"")
                                        metadataChanges.newPriority = rTask.priority
                                        taskForReminders.priority = rTask.priority
                                        changeDescriptions.append("Priority → \(rTask.priority.displayName)")
                                    }

                                    // Tag writeback (#17 — GoodTask support)
                                    if config.enableTagWriteback {
                                        let rTags = Set(rTask.tags)
                                        let oTags = Set(oTask.tags)
                                        if rTags != oTags {
                                            debugLog("[SyncEngine] Tags changed in destination for \"\(oTask.title)\": \(oTags) → \(rTags)")
                                            metadataChanges.newTags = rTask.tags
                                            taskForReminders.tags = rTask.tags
                                            changeDescriptions.append("Tags → \(rTask.tags.joined(separator: ", "))")
                                        }
                                    }

                                    // Apply all metadata changes atomically.
                                    // Wrapped in its own do/catch so a writeback failure
                                    // doesn't prevent the destination update below.
                                    if metadataChanges.hasChanges {
                                        if !config.dryRunMode {
                                            var adjustedTask = oTask
                                            if let src = oTask.obsidianSource {
                                                let insertions = fileInsertions[src.filePath] ?? []
                                                let offset = insertions.filter { $0 <= src.lineNumber }.count
                                                adjustedTask.obsidianSource = SyncTask.ObsidianSource(
                                                    filePath: src.filePath,
                                                    lineNumber: src.lineNumber + offset,
                                                    originalLine: src.originalLine
                                                )
                                            }
                                            do {
                                                try source.updateTaskMetadata(task: adjustedTask, changes: metadataChanges, config: config)
                                            } catch {
                                                debugLog("[SyncEngine] Metadata writeback failed for \"\(oTask.title)\": \(error)")
                                                result.errors.append(error)
                                                result.details.append(SyncLogDetail(
                                                    action: .error,
                                                    taskTitle: oTask.title,
                                                    filePath: oTask.obsidianSource?.filePath,
                                                    errorMessage: "Metadata writeback failed: \(error.localizedDescription)"
                                                ))
                                            }
                                        }
                                        result.metadataWrittenBack += changeDescriptions.count
                                        result.details.append(SyncLogDetail(
                                            action: .metadataWriteback,
                                            taskTitle: (config.dryRunMode ? "[DRY RUN] " : "") + oTask.title,
                                            filePath: oTask.obsidianSource?.filePath,
                                            errorMessage: changeDescriptions.joined(separator: "; ")
                                        ))
                                    }
                                }
                            }

                            // Skip the destination update when the only change was
                            // completion flowing FROM the destination (e.g. Things 3 Logbook).
                            // The task is already in its final state there; sending a redundant
                            // update can fail for tasks in the Logbook/archive.
                            let completionFromDestination = completionDiffers && rTask.isCompleted && !oTask.isCompleted
                            let needsDestinationUpdate = !completionFromDestination || oChanged

                            if !config.dryRunMode {
                                if needsDestinationUpdate {
                                    try await destination.updateTask(
                                        withId: mapping.remindersId,
                                        from: taskForReminders,
                                        config: config
                                    )

                                    // Move to correct list if needed
                                    let targetList = config.resolveTargetList(tag: oTask.targetList, filePath: oTask.obsidianSource?.filePath, tags: oTask.tags)
                                    if targetList != rTask.targetList {
                                        try await destination.moveTask(withId: mapping.remindersId, toList: targetList)
                                    }
                                }

                                syncState.addOrUpdateMapping(
                                    obsidianId: mapping.obsidianId,
                                    remindersId: mapping.remindersId,
                                    obsidianHash: SyncState.generateTaskHash(taskForReminders),
                                    remindersHash: SyncState.generateTaskHash(taskForReminders)
                                )
                            }
                            result.updated += 1
                            result.details.append(SyncLogDetail(
                                action: .updated,
                                taskTitle: oTask.title,
                                filePath: oTask.obsidianSource?.filePath,
                                errorMessage: nil
                            ))
                        } catch {
                            result.errors.append(error)
                            result.details.append(SyncLogDetail(
                                action: .error,
                                taskTitle: oTask.title,
                                filePath: oTask.obsidianSource?.filePath,
                                errorMessage: error.localizedDescription
                            ))
                        }
                    }

                    processedObsidianIds.insert(mapping.obsidianId)
                    remindersMap.removeValue(forKey: mapping.remindersId)

                case (.some(let oTask), .none):
                    // Reminder mapping broken — before recreating, check if there's
                    // already an existing reminder with the same title (e.g., after
                    // a previous delete+recreate cycle that changed the remindersId).
                    var reconnected = false
                    for (existingRemindersId, existingRTask) in remindersMap {
                        if existingRTask.title == oTask.title {
                            // Found an existing reminder — reconnect instead of recreating
                            debugLog("[SyncEngine] Reconnecting \"\(oTask.title)\" to existing reminder (id changed)")
                            if !config.dryRunMode {
                                syncState.addOrUpdateMapping(
                                    obsidianId: mapping.obsidianId,
                                    remindersId: existingRemindersId,
                                    obsidianHash: SyncState.generateTaskHash(oTask),
                                    remindersHash: SyncState.generateTaskHash(existingRTask)
                                )
                            }
                            remindersMap.removeValue(forKey: existingRemindersId)
                            reconnected = true
                            result.details.append(SyncLogDetail(
                                action: .updated,
                                taskTitle: oTask.title,
                                filePath: oTask.obsidianSource?.filePath,
                                errorMessage: "Reconnected to existing reminder"
                            ))
                            break
                        }
                    }

                    if !reconnected {
                        // Truly deleted — recreate from Obsidian
                        do {
                            let listName = config.resolveTargetList(tag: oTask.targetList, filePath: oTask.obsidianSource?.filePath, tags: oTask.tags)
                            if !config.dryRunMode {
                                let newId = try await destination.createTask(
                                    from: oTask,
                                    inList: listName,
                                    config: config
                                )
                                syncState.addOrUpdateMapping(
                                    obsidianId: mapping.obsidianId,
                                    remindersId: newId,
                                    obsidianHash: SyncState.generateTaskHash(oTask),
                                    remindersHash: SyncState.generateTaskHash(oTask)
                                )
                            }
                            result.created += 1
                            result.details.append(SyncLogDetail(
                                action: .created,
                                taskTitle: oTask.title,
                                filePath: oTask.obsidianSource?.filePath,
                                errorMessage: nil
                            ))
                        } catch {
                            result.errors.append(error)
                            result.details.append(SyncLogDetail(
                                action: .error,
                                taskTitle: oTask.title,
                                filePath: oTask.obsidianSource?.filePath,
                                errorMessage: error.localizedDescription
                            ))
                        }
                    }
                    processedObsidianIds.insert(mapping.obsidianId)

                case (.none, .some(let rTask)):
                    // Obsidian ID not found — could be a genuine deletion OR an ID
                    // format change (e.g., after dates/priority were removed from the ID).
                    // Before deleting, try to re-link to an unmatched Obsidian task.
                    //
                    // Matching strategy: find the best candidate by title + list/tags.
                    // Use a score-based approach so partial matches still work.
                    var relinked = false
                    var bestCandidateId: String? = nil
                    var bestCandidateTask: SyncTask? = nil
                    var bestScore = 0

                    for (candidateId, candidateTask) in obsidianMap {
                        guard !processedObsidianIds.contains(candidateId) else { continue }

                        var score = 0

                        // Title match is required (minimum bar)
                        guard candidateTask.title == rTask.title else { continue }
                        score += 10

                        // Bonus: same target list / tag
                        if candidateTask.targetList == rTask.targetList {
                            score += 5
                        }

                        // Bonus: same file path prefix in reminders notes
                        if let notes = rTask.notes,
                           let filePath = candidateTask.obsidianSource?.filePath,
                           notes.contains(filePath) {
                            score += 3
                        }

                        // Bonus: matching recurrence rule (#57 Phase B).
                        // When two tasks share the same title but only one is
                        // the actual recurring instance, the recurrence rule
                        // is a strong signal of identity. Compare semantically
                        // so e.g. "every week" matches "🔁 every week".
                        if RecurrenceConverter.rulesAreEquivalent(
                            candidateTask.recurrenceRule,
                            rTask.recurrenceRule
                        ) && (candidateTask.recurrenceRule != nil || rTask.recurrenceRule != nil) {
                            score += 7
                        }

                        if score > bestScore {
                            bestScore = score
                            bestCandidateId = candidateId
                            bestCandidateTask = candidateTask
                        }
                    }

                    if let candidateId = bestCandidateId, let candidateTask = bestCandidateTask {
                        // Found a matching Obsidian task — re-link the mapping
                        debugLog("[SyncEngine] Re-linking mapping for \"\(rTask.title)\": old obsidianId changed, remapping to new ID (score=\(bestScore))")
                        if !config.dryRunMode {
                            syncState.removeMapping(obsidianId: mapping.obsidianId)
                            syncState.addOrUpdateMapping(
                                obsidianId: candidateId,
                                remindersId: mapping.remindersId,
                                obsidianHash: SyncState.generateTaskHash(candidateTask),
                                remindersHash: SyncState.generateTaskHash(rTask)
                            )
                        }
                        processedObsidianIds.insert(candidateId)
                        relinkedRemindersIds.insert(mapping.remindersId)
                        relinked = true
                        result.details.append(SyncLogDetail(
                            action: .updated,
                            taskTitle: rTask.title,
                            filePath: candidateTask.obsidianSource?.filePath,
                            errorMessage: "Re-linked after ID change"
                        ))
                    }

                    if !relinked {
                        // Check if this reminder was already re-linked by a previous
                        // duplicate mapping (same remindersId, different stale obsidianId).
                        // If so, just clean up the stale mapping — don't delete the reminder.
                        if relinkedRemindersIds.contains(mapping.remindersId) {
                            debugLog("[SyncEngine] Skipping delete for \"\(rTask.title)\": already re-linked by another mapping")
                            if !config.dryRunMode {
                                syncState.removeMapping(obsidianId: mapping.obsidianId)
                            }
                        } else {
                            // Truly deleted from Obsidian — delete from Reminders too
                            do {
                                if !config.dryRunMode {
                                    try await destination.deleteTask(withId: mapping.remindersId)
                                    syncState.removeMapping(obsidianId: mapping.obsidianId)
                                }
                                result.deleted += 1
                                result.details.append(SyncLogDetail(
                                    action: .deleted,
                                    taskTitle: rTask.title,
                                    filePath: nil,
                                    errorMessage: nil
                                ))
                            } catch {
                                result.errors.append(error)
                                result.details.append(SyncLogDetail(
                                    action: .error,
                                    taskTitle: "Delete failed",
                                    filePath: nil,
                                    errorMessage: error.localizedDescription
                                ))
                            }
                        }
                    }
                    remindersMap.removeValue(forKey: mapping.remindersId)

                case (.none, .none):
                    // Both deleted - clean up mapping
                    if !config.dryRunMode {
                        syncState.removeMapping(obsidianId: mapping.obsidianId)
                    }
                }
            }

            // Step 5: Handle new Obsidian tasks (create in Reminders)
            // Build a title→[remindersId] index from the remaining unmatched reminders
            // so we can reconnect by title instead of creating duplicates.
            var unmatchedRemindersByTitle: [String: [(id: String, task: SyncTask)]] = [:]
            for (remId, remTask) in remindersMap {
                unmatchedRemindersByTitle[remTask.title, default: []].append((id: remId, task: remTask))
            }

            debugLog("[SyncEngine] Processed \(processedObsidianIds.count) existing mappings. New tasks to process: \(obsidianMap.count - processedObsidianIds.count). Unmatched reminders available for reconnect: \(remindersMap.count)")

            var newTasksToCreate: [(obsidianId: String, task: SyncTask, listName: String)] = []

            for (obsidianId, task) in obsidianMap {
                if processedObsidianIds.contains(obsidianId) {
                    continue
                }

                // Recurring-task next-occurrence handoff (#57 Phase A).
                // If this task has a recurrence rule AND is uncompleted AND a
                // processed sibling in the same file with the same title exists
                // (i.e. the completed copy of the previous occurrence which just
                // got its completion written back to the destination), transfer
                // that sibling's mapping here instead of creating a new
                // destination task. This prevents the duplicate accumulation
                // described in #57 scenarios 1 & 2.
                if task.recurrenceRule != nil, !task.isCompleted, let filePath = task.obsidianSource?.filePath {
                    let siblingId = processedObsidianIds.first { procId in
                        guard procId != obsidianId,
                              let procTask = obsidianMap[procId],
                              procTask.recurrenceRule != nil,
                              procTask.obsidianSource?.filePath == filePath,
                              procTask.title == task.title else { return false }
                        return true
                    }
                    if let siblingId = siblingId,
                       let siblingMapping = syncState.findMapping(obsidianId: siblingId) {
                        debugLog("[SyncEngine] Recurring next occurrence: inheriting mapping from sibling \(siblingId) → \(obsidianId) for \"\(task.title)\"")
                        if !config.dryRunMode {
                            syncState.removeMapping(obsidianId: siblingId)
                            syncState.addOrUpdateMapping(
                                obsidianId: obsidianId,
                                remindersId: siblingMapping.remindersId,
                                obsidianHash: SyncState.generateTaskHash(task),
                                remindersHash: siblingMapping.lastRemindersHash
                            )
                        }
                        processedObsidianIds.insert(obsidianId)
                        result.details.append(SyncLogDetail(
                            action: .updated,
                            taskTitle: task.title,
                            filePath: task.obsidianSource?.filePath,
                            errorMessage: "Recurring task: new occurrence inherited sibling mapping"
                        ))
                        continue
                    }
                }

                // Skip completed tasks if configured
                if task.isCompleted && !config.syncCompletedTasks {
                    result.details.append(SyncLogDetail(
                        action: .skipped,
                        taskTitle: task.title,
                        filePath: task.obsidianSource?.filePath,
                        errorMessage: "Completed task skipped"
                    ))
                    continue
                }

                // Skip tasks whose target list is not in the allowed lists
                if !config.syncedRemindersLists.isEmpty {
                    let targetList = config.resolveTargetList(tag: task.targetList, filePath: task.obsidianSource?.filePath, tags: task.tags)
                    let allowedLists = Set(config.syncedRemindersLists.map { $0.lowercased() })
                    if !allowedLists.contains(targetList.lowercased()) {
                        result.details.append(SyncLogDetail(
                            action: .skipped,
                            taskTitle: task.title,
                            filePath: task.obsidianSource?.filePath,
                            errorMessage: "List \"\(targetList)\" not in synced lists"
                        ))
                        continue
                    }
                }

                // Skip tasks whose target list is excluded (#21)
                if !config.excludedRemindersLists.isEmpty {
                    let targetList = config.resolveTargetList(tag: task.targetList, filePath: task.obsidianSource?.filePath, tags: task.tags)
                    let excludedLists = Set(config.excludedRemindersLists.map { $0.lowercased() })
                    if excludedLists.contains(targetList.lowercased()) {
                        result.details.append(SyncLogDetail(
                            action: .skipped,
                            taskTitle: task.title,
                            filePath: task.obsidianSource?.filePath,
                            errorMessage: "List \"\(targetList)\" is excluded"
                        ))
                        continue
                    }
                }

                // Before creating a new reminder, check if an unmatched reminder
                // with the same title already exists (prevents duplicates after
                // sync state reset or ID format migration).
                if var candidates = unmatchedRemindersByTitle[task.title], !candidates.isEmpty {
                    // Pick the best candidate — prefer one in the same list
                    let targetList = config.resolveTargetList(tag: task.targetList, filePath: task.obsidianSource?.filePath, tags: task.tags)
                    var bestIndex = 0
                    for (i, candidate) in candidates.enumerated() {
                        if candidate.task.targetList == targetList {
                            bestIndex = i
                            break
                        }
                    }

                    let matched = candidates.remove(at: bestIndex)
                    unmatchedRemindersByTitle[task.title] = candidates

                    debugLog("[SyncEngine] Reconnecting new task \"\(task.title)\" to existing reminder \(matched.id) (dedup)")

                    if !config.dryRunMode {
                        // Update the existing destination task with source data (source of truth)
                        try? await destination.updateTask(
                            withId: matched.id,
                            from: task,
                            config: config
                        )

                        let hash = SyncState.generateTaskHash(task)
                        syncState.addOrUpdateMapping(
                            obsidianId: obsidianId,
                            remindersId: matched.id,
                            obsidianHash: hash,
                            remindersHash: SyncState.generateTaskHash(matched.task)
                        )
                    }

                    // Remove from remindersMap so Step 6 doesn't treat it as a new Reminders task
                    remindersMap.removeValue(forKey: matched.id)

                    result.updated += 1
                    result.details.append(SyncLogDetail(
                        action: .updated,
                        taskTitle: task.title,
                        filePath: task.obsidianSource?.filePath,
                        errorMessage: "Reconnected to existing reminder (dedup)"
                    ))
                    continue
                }

                // Queue for batch creation
                let listName = config.resolveTargetList(tag: task.targetList, filePath: task.obsidianSource?.filePath, tags: task.tags)
                debugLog("[SyncEngine] Queuing: \"\(task.title)\" → list \"\(listName)\"")
                newTasksToCreate.append((obsidianId: obsidianId, task: task, listName: listName))
            }

            // Batch-create all new tasks (uses batch AppleScript for Things 3)
            if !newTasksToCreate.isEmpty {
                onProgress?("Creating \(newTasksToCreate.count) tasks in \(destination.destinationName)...")
                await createNewTasks(tasks: newTasksToCreate, config: config, result: &result)
            }

            // Step 6: New task writeback — Reminders → Obsidian Inbox
            // Any entries remaining in remindersMap were NOT matched to an Obsidian task
            // and have no existing mapping. These are new tasks created in Reminders.
            if config.enableNewTaskWriteback && !remindersMap.isEmpty {
                onProgress?("Writing back \(remindersMap.count) tasks to Obsidian...")
                debugLog("[SyncEngine] Found \(remindersMap.count) unmatched Reminders tasks for inbox writeback")

                // Build a title→obsidianId index of every task already in the vault.
                // Used to skip the inbox append for reminders whose title already
                // exists somewhere in Obsidian — this is the recurrence-history bug
                // fix described below. Cheap to compute once vs. per-iteration scans.
                var titleIndex: [String: String] = [:]
                for (id, task) in obsidianMap {
                    titleIndex[task.title] = id
                }

                // Cutoff computed once per sync — keeps filter decisions stable
                // across all reminders evaluated in the same writeback pass.
                let writebackCutoff = SyncEngine.completedTaskCutoffDate(for: config)

                // Counter for the age-filter log line below — mirrors the source-scan
                // "Filtered out N completed tasks older than N days" pattern.
                var skippedOldCount = 0

                for (remindersId, rTask) in remindersMap {
                    // Skip completed tasks unless configured to sync them
                    if rTask.isCompleted && !config.syncCompletedTasks { continue }

                    // CRITICAL: skip reminders whose title already exists anywhere in
                    // the vault. Without this, Apple Reminders' recurring-task history
                    // (each completed occurrence has a fresh calendarItemIdentifier)
                    // gets appended to /Inbox.md on every sync, creating runaway
                    // duplicate accumulation. The reminder is already represented in
                    // Obsidian — usually as a `🔁` recurring task in some other note —
                    // and re-appending it adds noise. We attach the existing
                    // obsidianId to the reminder's mapping instead so subsequent
                    // syncs treat it as already-mapped. (regression: 2026-04-30)
                    //
                    // This block runs BEFORE the age filter below so the mapping
                    // side-effect still fires for old-and-title-matched reminders —
                    // otherwise an old recurring-task occurrence whose title matches
                    // a vault task would skip via age every sync without ever getting
                    // a syncState mapping, and the noisy "Skipped N" count would
                    // include it perpetually.
                    if let existingObsidianId = titleIndex[rTask.title] {
                        if !config.dryRunMode,
                           let matchedObsidianTask = obsidianMap[existingObsidianId] {
                            syncState.addOrUpdateMapping(
                                obsidianId: existingObsidianId,
                                remindersId: remindersId,
                                obsidianHash: SyncState.generateTaskHash(matchedObsidianTask),
                                remindersHash: SyncState.generateTaskHash(rTask)
                            )
                        }
                        debugLog("[SyncEngine] Skipping inbox writeback for \"\(rTask.title)\": title already exists in vault (mapped to existing task)")
                        continue
                    }

                    // Honor maxCompletedTaskAgeDays in both directions. Without this,
                    // old completed reminders bypass the age cutoff via the writeback
                    // path — exactly the symptom #11 was filed for. Runs AFTER the
                    // title-dedup above so the dedup's mapping side-effect is
                    // preserved for old-and-title-matched reminders.
                    if SyncEngine.isCompletedTaskTooOld(rTask, cutoff: writebackCutoff) {
                        skippedOldCount += 1
                        continue
                    }

                    do {
                        if !config.dryRunMode {
                            let newSource = try source.appendNewTask(rTask, config: config)

                            // Re-parse the actual line we just wrote so the stored
                            // obsidianId matches what the next vault scan will produce.
                            // Without this, the tag we add to the line (`#<list>`) makes
                            // the reparsed task's id differ from rTask's id, orphaning
                            // the mapping immediately. (regression: 2026-04-30)
                            let parsedTask = SyncTask.fromObsidianLine(
                                newSource.originalLine,
                                filePath: newSource.filePath,
                                lineNumber: newSource.lineNumber
                            )

                            // Use the parsed task if available; otherwise fall back to
                            // rTask + source (preserves old behavior for edge cases
                            // where parsing fails — e.g. a hypothetical title that
                            // doesn't survive the round-trip).
                            let mappedTask: SyncTask = {
                                if let parsed = parsedTask {
                                    return parsed
                                }
                                var t = rTask
                                t.obsidianSource = newSource
                                return t
                            }()

                            let obsidianId = source.generateTaskId(for: mappedTask)
                            let hash = SyncState.generateTaskHash(mappedTask)
                            syncState.addOrUpdateMapping(
                                obsidianId: obsidianId,
                                remindersId: remindersId,
                                obsidianHash: hash,
                                remindersHash: hash
                            )
                        }

                        result.metadataWrittenBack += 1
                        result.details.append(SyncLogDetail(
                            action: .metadataWriteback,
                            taskTitle: (config.dryRunMode ? "[DRY RUN] " : "") + "→ Inbox: " + rTask.title,
                            filePath: config.inboxFilePath,
                            errorMessage: nil
                        ))
                    } catch {
                        result.errors.append(error)
                        result.details.append(SyncLogDetail(
                            action: .error,
                            taskTitle: rTask.title,
                            filePath: config.inboxFilePath,
                            errorMessage: "Inbox writeback failed: \(error.localizedDescription)"
                        ))
                    }
                }

                if skippedOldCount > 0 {
                    debugLog("[SyncEngine] Skipped \(skippedOldCount) old completed reminders from inbox writeback (older than \(config.maxCompletedTaskAgeDays) days)")
                }
            }

            // Step 7: Save sync state (skip in dry run)
            if !config.dryRunMode {
                syncState.lastSyncDate = Date()
                syncState.save()
            }

        } catch {
            debugLog("[SyncEngine] ERROR: \(error.localizedDescription)")
            result.errors.append(error)
            result.details.append(SyncLogDetail(
                action: .error,
                taskTitle: "Sync failed",
                filePath: nil,
                errorMessage: error.localizedDescription
            ))
        }

        debugLog("[SyncEngine] Sync complete: \(result.summary)")
        return result
    }

    // MARK: - Batch Task Creation

    /// Create multiple tasks in the destination, using batch AppleScript for Things 3.
    /// Extracted from performSync to avoid Swift compiler SIL ownership bug in Release mode.
    private func createNewTasks(
        tasks: [(obsidianId: String, task: SyncTask, listName: String)],
        config: SyncConfiguration,
        result: inout SyncResult
    ) async {
        guard !tasks.isEmpty else { return }

        if config.dryRunMode {
            for item in tasks {
                result.created += 1
                result.details.append(SyncLogDetail(
                    action: .created,
                    taskTitle: item.task.title,
                    filePath: item.task.obsidianSource?.filePath,
                    errorMessage: nil
                ))
            }
            return
        }

        // Try batch creation for Things 3
        if let things3 = destination as? Things3Destination {
            let batchSize = 20
            for batchStart in stride(from: 0, to: tasks.count, by: batchSize) {
                if isCancelled { break }
                let batchEnd = min(batchStart + batchSize, tasks.count)
                let batch = Array(tasks[batchStart..<batchEnd])
                let batchInput = batch.map { (task: $0.task, listName: $0.listName) }

                do {
                    let ids = try await things3.createTasksBatch(tasks: batchInput, config: config)
                    for (i, item) in batch.enumerated() {
                        let hash = SyncState.generateTaskHash(item.task)
                        syncState.addOrUpdateMapping(
                            obsidianId: item.obsidianId,
                            remindersId: ids[i],
                            obsidianHash: hash,
                            remindersHash: hash
                        )
                        result.created += 1
                        result.details.append(SyncLogDetail(
                            action: .created,
                            taskTitle: item.task.title,
                            filePath: item.task.obsidianSource?.filePath,
                            errorMessage: nil
                        ))
                    }
                    debugLog("[SyncEngine] Batch created \(batch.count) tasks in Things 3")
                } catch {
                    debugLog("[SyncEngine] Batch create failed, falling back to individual: \(error.localizedDescription)")
                    await createTasksSequentially(tasks: batch, config: config, result: &result)
                }
            }
        } else {
            await createTasksSequentially(tasks: tasks, config: config, result: &result)
        }
    }

    /// Create tasks one at a time (fallback for non-Things 3 destinations or batch failure).
    private func createTasksSequentially(
        tasks: [(obsidianId: String, task: SyncTask, listName: String)],
        config: SyncConfiguration,
        result: inout SyncResult
    ) async {
        for item in tasks {
            if isCancelled { break }
            do {
                let reminderId = try await destination.createTask(
                    from: item.task,
                    inList: item.listName,
                    config: config
                )
                let hash = SyncState.generateTaskHash(item.task)
                syncState.addOrUpdateMapping(
                    obsidianId: item.obsidianId,
                    remindersId: reminderId,
                    obsidianHash: hash,
                    remindersHash: hash
                )
                result.created += 1
                result.details.append(SyncLogDetail(
                    action: .created,
                    taskTitle: item.task.title,
                    filePath: item.task.obsidianSource?.filePath,
                    errorMessage: nil
                ))
            } catch {
                result.errors.append(error)
                result.details.append(SyncLogDetail(
                    action: .error,
                    taskTitle: item.task.title,
                    filePath: item.task.obsidianSource?.filePath,
                    errorMessage: error.localizedDescription
                ))
            }
        }
    }

    // MARK: - Conflict Resolution (simplified - Obsidian always wins)

    func resolveConflict(_ conflict: SyncConflict, with resolution: SyncConflict.ConflictResolutionChoice, config: SyncConfiguration) async throws {
        guard let remindersId = conflict.remindersVersion.remindersId else {
            throw SyncError.missingSourceInfo
        }

        let obsidianId = source.generateTaskId(for: conflict.obsidianVersion)

        // Always use source version for destination
        try await destination.updateTask(
            withId: remindersId,
            from: conflict.obsidianVersion,
            config: config
        )
        let hash = SyncState.generateTaskHash(conflict.obsidianVersion)
        syncState.addOrUpdateMapping(
            obsidianId: obsidianId,
            remindersId: remindersId,
            obsidianHash: hash,
            remindersHash: hash
        )

        syncState.save()
    }

    // MARK: - Date Comparison

    /// Compare two optional dates by day only (ignoring time components).
    /// Returns true if both are nil, or both represent the same calendar day.
    private func datesAreEqualByDay(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.some, .none), (.none, .some): return false
        case (.some(let d1), .some(let d2)):
            return Calendar.current.isDate(d1, inSameDayAs: d2)
        }
    }

    // MARK: - Utilities

    func getLastSyncDate() -> Date? {
        return syncState.lastSyncDate
    }

    func resetSyncState() {
        syncState = SyncState()
        syncState.save()
    }
}

// MARK: - DateFormatter Extension

extension DateFormatter {
    static let obsidianDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case noVaultConfigured
    case missingSourceInfo
    case conflictNotResolved
    case syncAlreadyInProgress
    case syncCancelled
    case vaultPathNotFound(String)
    case notAnObsidianVault(String)
    case safetyAbort(String)

    var errorDescription: String? {
        switch self {
        case .noVaultConfigured:
            return "No vault path configured"
        case .missingSourceInfo:
            return "Task is missing source information required for sync"
        case .conflictNotResolved:
            return "Conflict must be resolved before continuing"
        case .syncAlreadyInProgress:
            return "A sync operation is already in progress"
        case .syncCancelled:
            return "Sync was cancelled"
        case .vaultPathNotFound(let path):
            return "Vault path not found: \(path)"
        case .notAnObsidianVault(let path):
            return "Path does not appear to be an Obsidian vault (missing .obsidian directory): \(path)"
        case .safetyAbort(let message):
            return "Safety abort: \(message)"
        }
    }
}
