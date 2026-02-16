import Foundation
import Combine

/// Core sync engine that handles synchronization.
/// Uses protocol-based TaskSource and TaskDestination for extensibility.
/// The source is always the source of truth. Writeback to the source is opt-in.
class SyncEngine {
    private let source: TaskSource
    private let destination: TaskDestination
    private let backupService = FileBackupService.shared
    private var syncState = SyncState.load()

    init(source: TaskSource, destination: TaskDestination) {
        self.source = source
        self.destination = destination
    }

    // Mutex to prevent concurrent sync operations
    private let syncLock = NSLock()
    private var _isSyncing = false

    var isSyncing: Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return _isSyncing
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

    // MARK: - Main Sync

    /// Perform sync: Source -> Destination (source is the source of truth).
    /// Optionally writes completion status back to source (surgical edit only).
    func performSync(config: SyncConfiguration) async -> SyncResult {
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

        // Capture file timestamps at sync start (for change detection during writes)
        let syncStartTimestamp = Date()

        do {
            // Step 1: Get all tasks from source
            debugLog("[SyncEngine] Scanning source: \(source.sourceName)")
            debugLog("[SyncEngine] Vault: \(config.vaultPath), excluded: \(config.excludedFolders), included: \(config.includedFolders)")
            let obsidianTasks = try source.scanTasks(config: config)
            debugLog("[SyncEngine] Found \(obsidianTasks.count) source tasks")
            for (i, task) in obsidianTasks.prefix(5).enumerated() {
                debugLog("[SyncEngine]   Task \(i): \"\(task.title)\" completed=\(task.isCompleted) file=\(task.obsidianSource?.filePath ?? "?")")
            }
            if obsidianTasks.count > 5 {
                debugLog("[SyncEngine]   ... and \(obsidianTasks.count - 5) more")
            }

            // Step 2: Get all tasks from destination
            debugLog("[SyncEngine] Fetching from destination: \(destination.destinationName)...")
            let remindersTasks = try await destination.fetchAllTasks()
            debugLog("[SyncEngine] Found \(remindersTasks.count) destination tasks")

            // Step 3: Build lookup maps
            var obsidianMap: [String: SyncTask] = [:]
            for task in obsidianTasks {
                let id = source.generateTaskId(for: task)
                obsidianMap[id] = task
            }
            debugLog("[SyncEngine] Obsidian map has \(obsidianMap.count) unique IDs (from \(obsidianTasks.count) tasks)")

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
                        idsToRemove.insert(id)
                        debugLog("[SyncEngine] Dedup: same-file recurring → skipping completed \"\(task.title)\" in \(filePath)")
                    }
                }
            }

            // --- Pass (b): cross-file duplicates (same title, different files) ---
            // Group remaining tasks by title
            var tasksByTitle: [String: [(id: String, task: SyncTask)]] = [:]
            for (id, task) in obsidianMap where !idsToRemove.contains(id) {
                tasksByTitle[task.title, default: []].append((id: id, task: task))
            }
            for (title, entries) in tasksByTitle where entries.count > 1 {
                // Multiple copies of the same title — pick the best one, drop the rest.
                // Scoring: uncompleted > completed, non-Inbox > Inbox, has existing mapping > no mapping
                let inboxSuffix = "/Inbox.md"
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
                // Keep first (best), remove the rest
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

            var remindersMap: [String: SyncTask] = [:]
            for task in remindersTasks {
                if let id = task.remindersId {
                    remindersMap[id] = task
                }
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

            // Step 4: Process existing mappings
            var processedObsidianIds: Set<String> = []
            var relinkedRemindersIds: Set<String> = []  // Track re-linked reminders to prevent duplicate deletion

            // Track line offsets per file: when markTaskComplete inserts a recurrence
            // line, all subsequent line numbers in that file shift down by 1.
            // Key = filePath, Value = cumulative lines inserted above.
            var fileLineOffsets: [String: Int] = [:]

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

                    if oChanged || completionDiffers || rChanged {
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
                                        // Build an adjusted task for line-offset tracking
                                        var adjustedTask = oTask
                                        if let src = oTask.obsidianSource {
                                            let adjustedLine = src.lineNumber + (fileLineOffsets[src.filePath] ?? 0)
                                            adjustedTask.obsidianSource = SyncTask.ObsidianSource(
                                                filePath: src.filePath,
                                                lineNumber: adjustedLine,
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
                                            fileLineOffsets[src.filePath, default: 0] += inserted
                                        }
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

                            // Handle un-completion: completed in Obsidian, un-completed in Reminders
                            if completionDiffers && !rTask.isCompleted && oTask.isCompleted {
                                taskForReminders.isCompleted = false
                                taskForReminders.completedDate = nil

                                if config.enableCompletionWriteback {
                                    if fileNotModifiedBeforeSync && !config.dryRunMode {
                                        var adjustedTask = oTask
                                        if let src = oTask.obsidianSource {
                                            let adjustedLine = src.lineNumber + (fileLineOffsets[src.filePath] ?? 0)
                                            adjustedTask.obsidianSource = SyncTask.ObsidianSource(
                                                filePath: src.filePath,
                                                lineNumber: adjustedLine,
                                                originalLine: src.originalLine
                                            )
                                        }
                                        try source.markTaskIncomplete(task: adjustedTask, config: config)
                                        result.completionsWrittenBack += 1
                                        result.details.append(SyncLogDetail(
                                            action: .completionWriteback,
                                            taskTitle: oTask.title + " (uncompleted)",
                                            filePath: oTask.obsidianSource?.filePath,
                                            errorMessage: nil
                                        ))
                                    }
                                }
                            }

                            // MARK: Metadata writeback (due date, start date, priority)
                            // Write back when Reminders changed but Obsidian didn't
                            // (meaning the change originated from Reminders, not Obsidian).
                            // All changes are applied atomically in a single file write.
                            if rChanged && !oChanged {
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

                                    // Apply all metadata changes atomically
                                    if metadataChanges.hasChanges {
                                        if !config.dryRunMode {
                                            var adjustedTask = oTask
                                            if let src = oTask.obsidianSource {
                                                let adjustedLine = src.lineNumber + (fileLineOffsets[src.filePath] ?? 0)
                                                adjustedTask.obsidianSource = SyncTask.ObsidianSource(
                                                    filePath: src.filePath,
                                                    lineNumber: adjustedLine,
                                                    originalLine: src.originalLine
                                                )
                                            }
                                            try source.updateTaskMetadata(task: adjustedTask, changes: metadataChanges, config: config)
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

                            if !config.dryRunMode {
                                try destination.updateTask(
                                    withId: mapping.remindersId,
                                    from: taskForReminders,
                                    config: config
                                )

                                // Move to correct list if needed
                                let targetList = config.remindersListForTag(oTask.targetList ?? "")
                                if targetList != rTask.targetList {
                                    try destination.moveTask(withId: mapping.remindersId, toList: targetList)
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
                            let listName = config.remindersListForTag(oTask.targetList ?? "")
                            if !config.dryRunMode {
                                let newId = try destination.createTask(
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
                                    try destination.deleteTask(withId: mapping.remindersId)
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
            for (obsidianId, task) in obsidianMap {
                if processedObsidianIds.contains(obsidianId) {
                    continue
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

                // Before creating a new reminder, check if an unmatched reminder
                // with the same title already exists (prevents duplicates after
                // sync state reset or ID format migration).
                if var candidates = unmatchedRemindersByTitle[task.title], !candidates.isEmpty {
                    // Pick the best candidate — prefer one in the same list
                    let targetList = config.remindersListForTag(task.targetList ?? "")
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
                        try? destination.updateTask(
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

                do {
                    let listName = config.remindersListForTag(task.targetList ?? "")
                    debugLog("[SyncEngine] Creating: \"\(task.title)\" → list \"\(listName)\" (tag: \(task.targetList ?? "none"), client: \(task.clientName ?? "none"))")
                    if !config.dryRunMode {
                        let reminderId = try destination.createTask(
                            from: task,
                            inList: listName,
                            config: config
                        )
                        let hash = SyncState.generateTaskHash(task)
                        syncState.addOrUpdateMapping(
                            obsidianId: obsidianId,
                            remindersId: reminderId,
                            obsidianHash: hash,
                            remindersHash: hash
                        )
                    }
                    result.created += 1
                    result.details.append(SyncLogDetail(
                        action: .created,
                        taskTitle: task.title,
                        filePath: task.obsidianSource?.filePath,
                        errorMessage: nil
                    ))
                } catch {
                    result.errors.append(error)
                    result.details.append(SyncLogDetail(
                        action: .error,
                        taskTitle: task.title,
                        filePath: task.obsidianSource?.filePath,
                        errorMessage: error.localizedDescription
                    ))
                }
            }

            // Step 6: New task writeback — Reminders → Obsidian Inbox
            // Any entries remaining in remindersMap were NOT matched to an Obsidian task
            // and have no existing mapping. These are new tasks created in Reminders.
            if config.enableNewTaskWriteback && !remindersMap.isEmpty {
                debugLog("[SyncEngine] Found \(remindersMap.count) unmatched Reminders tasks for inbox writeback")
                for (remindersId, rTask) in remindersMap {
                    // Skip completed tasks unless configured to sync them
                    if rTask.isCompleted && !config.syncCompletedTasks { continue }

                    do {
                        if !config.dryRunMode {
                            let newSource = try source.appendNewTask(rTask, config: config)

                            // Create a SyncTask with source info for mapping
                            var mappedTask = rTask
                            mappedTask.obsidianSource = newSource

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

    // MARK: - Conflict Resolution (simplified - Obsidian always wins)

    func resolveConflict(_ conflict: SyncConflict, with resolution: SyncConflict.ConflictResolutionChoice, config: SyncConfiguration) throws {
        guard let remindersId = conflict.remindersVersion.remindersId else {
            throw SyncError.missingSourceInfo
        }

        let obsidianId = source.generateTaskId(for: conflict.obsidianVersion)

        // Always use source version for destination
        try destination.updateTask(
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
        case .vaultPathNotFound(let path):
            return "Vault path not found: \(path)"
        case .notAnObsidianVault(let path):
            return "Path does not appear to be an Obsidian vault (missing .obsidian directory): \(path)"
        case .safetyAbort(let message):
            return "Safety abort: \(message)"
        }
    }
}
