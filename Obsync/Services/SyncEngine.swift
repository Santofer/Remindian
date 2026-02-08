import Foundation
import Combine

/// Core sync engine that handles synchronization.
/// IMPORTANT: Obsidian is the source of truth. We read from Obsidian and sync TO Reminders.
/// The only Obsidian write allowed is surgical completion status writeback (opt-in).
class SyncEngine {
    private let obsidianService = ObsidianService()
    private let remindersService = RemindersService()
    private let backupService = FileBackupService.shared
    private var syncState = SyncState.load()

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

    /// Perform sync: Obsidian -> Reminders (one-way, Obsidian is source of truth)
    /// Optionally writes completion status back to Obsidian (surgical edit only).
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

        let obsidianDir = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(".obsidian")
        guard FileManager.default.fileExists(atPath: obsidianDir.path) else {
            result.errors.append(SyncError.notAnObsidianVault(config.vaultPath))
            return result
        }

        // Capture file timestamps at sync start (for change detection during writes)
        let syncStartTimestamp = Date()

        do {
            // Step 1: Get all tasks from Obsidian
            debugLog("[SyncEngine] Scanning vault at: \(config.vaultPath)")
            debugLog("[SyncEngine] Excluded folders: \(config.excludedFolders)")
            let obsidianTasks = try obsidianService.scanVault(
                at: config.vaultPath,
                excludedFolders: config.excludedFolders
            )
            debugLog("[SyncEngine] Found \(obsidianTasks.count) Obsidian tasks")
            for (i, task) in obsidianTasks.prefix(5).enumerated() {
                debugLog("[SyncEngine]   Task \(i): \"\(task.title)\" completed=\(task.isCompleted) file=\(task.obsidianSource?.filePath ?? "?")")
            }
            if obsidianTasks.count > 5 {
                debugLog("[SyncEngine]   ... and \(obsidianTasks.count - 5) more")
            }

            // Step 2: Get all reminders
            debugLog("[SyncEngine] Fetching all reminders...")
            let remindersTasks = try await remindersService.fetchAllReminders()
            debugLog("[SyncEngine] Found \(remindersTasks.count) Reminders tasks")

            // Step 3: Build lookup maps
            var obsidianMap: [String: SyncTask] = [:]
            for task in obsidianTasks {
                let id = SyncState.generateObsidianId(task: task)
                obsidianMap[id] = task
            }
            debugLog("[SyncEngine] Obsidian map has \(obsidianMap.count) unique IDs (from \(obsidianTasks.count) tasks)")

            var remindersMap: [String: SyncTask] = [:]
            for task in remindersTasks {
                if let id = task.remindersId {
                    remindersMap[id] = task
                }
            }
            debugLog("[SyncEngine] Existing mappings: \(syncState.mappings.count)")

            // Step 4: Process existing mappings
            var processedObsidianIds: Set<String> = []

            for mapping in syncState.mappings {
                let obsidianTask = obsidianMap[mapping.obsidianId]
                let remindersTask = remindersMap[mapping.remindersId]

                switch (obsidianTask, remindersTask) {
                case (.some(let oTask), .some(let rTask)):
                    // Both exist - check what changed
                    let oHash = SyncState.generateTaskHash(oTask)
                    let oChanged = mapping.hasObsidianChanged(currentHash: oHash)

                    // Check if completion status differs between Obsidian and Reminders.
                    // This should trigger writeback regardless of oChanged, because oChanged
                    // can be true due to metadata changes unrelated to completion.
                    let completionDiffers = rTask.isCompleted != oTask.isCompleted

                    // Debug: log completion status for tasks that differ
                    if completionDiffers {
                        debugLog("[SyncEngine] Completion diff for \"\(oTask.title)\": obsidian=\(oTask.isCompleted), reminders=\(rTask.isCompleted), oChanged=\(oChanged)")
                    }

                    if oChanged || completionDiffers {
                        do {
                            var taskForReminders = oTask

                            // If completed in Reminders but not in Obsidian, keep it completed
                            // and write back to Obsidian (including recurrence handling)
                            if completionDiffers && rTask.isCompleted && !oTask.isCompleted {
                                taskForReminders.isCompleted = true
                                taskForReminders.completedDate = rTask.completedDate
                                debugLog("[SyncEngine] Task completed in Reminders: \"\(oTask.title)\", writeback enabled=\(config.enableCompletionWriteback), vaultPath=\(config.vaultPath)")

                                // Write completion back to Obsidian (surgical edit)
                                if config.enableCompletionWriteback {
                                    if let source = oTask.obsidianSource {
                                        // Check file hasn't changed since sync started
                                        if obsidianService.hasFileChanged(
                                            filePath: source.filePath,
                                            since: syncStartTimestamp,
                                            vaultPath: config.vaultPath
                                        ) {
                                            result.errors.append(ObsidianError.fileModifiedDuringSync)
                                            result.details.append(SyncLogDetail(
                                                action: .error,
                                                taskTitle: oTask.title,
                                                filePath: source.filePath,
                                                errorMessage: "File modified during sync"
                                            ))
                                        } else if !config.dryRunMode {
                                            debugLog("[SyncEngine] Writing completion back to Obsidian: \"\(oTask.title)\" file=\(source.filePath) line=\(source.lineNumber)")
                                            try obsidianService.markTaskComplete(
                                                filePath: source.filePath,
                                                lineNumber: source.lineNumber,
                                                originalLine: source.originalLine,
                                                completionDate: rTask.completedDate ?? Date(),
                                                vaultPath: config.vaultPath
                                            )
                                            debugLog("[SyncEngine] Completion writeback succeeded for: \"\(oTask.title)\"")
                                            result.completionsWrittenBack += 1
                                            result.details.append(SyncLogDetail(
                                                action: .completionWriteback,
                                                taskTitle: oTask.title,
                                                filePath: source.filePath,
                                                errorMessage: nil
                                            ))
                                        } else {
                                            result.completionsWrittenBack += 1
                                            result.details.append(SyncLogDetail(
                                                action: .completionWriteback,
                                                taskTitle: "[DRY RUN] " + oTask.title,
                                                filePath: source.filePath,
                                                errorMessage: nil
                                            ))
                                        }
                                    }
                                }
                            }

                            // Handle un-completion: completed in Obsidian, un-completed in Reminders
                            if completionDiffers && !rTask.isCompleted && oTask.isCompleted {
                                taskForReminders.isCompleted = false
                                taskForReminders.completedDate = nil

                                if config.enableCompletionWriteback {
                                    if let source = oTask.obsidianSource {
                                        if !obsidianService.hasFileChanged(
                                            filePath: source.filePath,
                                            since: syncStartTimestamp,
                                            vaultPath: config.vaultPath
                                        ) && !config.dryRunMode {
                                            try obsidianService.markTaskIncomplete(
                                                filePath: source.filePath,
                                                lineNumber: source.lineNumber,
                                                originalLine: source.originalLine,
                                                vaultPath: config.vaultPath
                                            )
                                            result.completionsWrittenBack += 1
                                            result.details.append(SyncLogDetail(
                                                action: .completionWriteback,
                                                taskTitle: oTask.title,
                                                filePath: source.filePath,
                                                errorMessage: nil
                                            ))
                                        }
                                    }
                                }
                            }

                            if !config.dryRunMode {
                                try remindersService.updateReminder(
                                    withId: mapping.remindersId,
                                    from: taskForReminders,
                                    includeDueTime: config.includeDueTime
                                )

                                // Move to correct list if needed
                                let targetList = config.remindersListForTag(oTask.targetList ?? "")
                                if targetList != rTask.targetList {
                                    try remindersService.moveReminder(withId: mapping.remindersId, toList: targetList)
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
                    // Reminder was deleted - recreate it from Obsidian
                    do {
                        let listName = config.remindersListForTag(oTask.targetList ?? "")
                        if !config.dryRunMode {
                            let newId = try remindersService.createReminder(
                                from: oTask,
                                inList: listName,
                                includeDueTime: config.includeDueTime
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
                    processedObsidianIds.insert(mapping.obsidianId)

                case (.none, .some(_)):
                    // Task deleted from Obsidian - delete from Reminders too
                    do {
                        if !config.dryRunMode {
                            try remindersService.deleteReminder(withId: mapping.remindersId)
                            syncState.removeMapping(obsidianId: mapping.obsidianId)
                        }
                        result.deleted += 1
                        result.details.append(SyncLogDetail(
                            action: .deleted,
                            taskTitle: "Removed task",
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
                    remindersMap.removeValue(forKey: mapping.remindersId)

                case (.none, .none):
                    // Both deleted - clean up mapping
                    if !config.dryRunMode {
                        syncState.removeMapping(obsidianId: mapping.obsidianId)
                    }
                }
            }

            // Step 5: Handle new Obsidian tasks (create in Reminders)
            debugLog("[SyncEngine] Processed \(processedObsidianIds.count) existing mappings. New tasks to process: \(obsidianMap.count - processedObsidianIds.count)")
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

                do {
                    let listName = config.remindersListForTag(task.targetList ?? "")
                    debugLog("[SyncEngine] Creating: \"\(task.title)\" → list \"\(listName)\" (tag: \(task.targetList ?? "none"), client: \(task.clientName ?? "none"))")
                    if !config.dryRunMode {
                        let reminderId = try remindersService.createReminder(
                            from: task,
                            inList: listName,
                            includeDueTime: config.includeDueTime
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

            // Step 6: Save sync state (skip in dry run)
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
        guard let source = conflict.obsidianVersion.obsidianSource,
              let remindersId = conflict.remindersVersion.remindersId else {
            throw SyncError.missingSourceInfo
        }

        let obsidianId = SyncState.generateObsidianId(task: conflict.obsidianVersion)

        // Always use Obsidian version for Reminders
        try remindersService.updateReminder(
            withId: remindersId,
            from: conflict.obsidianVersion,
            includeDueTime: config.includeDueTime
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

    // MARK: - Utilities

    func requestRemindersAccess() async throws -> Bool {
        return try await remindersService.requestAccess()
    }

    func getReminderLists() -> [String] {
        return remindersService.getAllLists().map { $0.title }
    }

    func getLastSyncDate() -> Date? {
        return syncState.lastSyncDate
    }

    func resetSyncState() {
        syncState = SyncState()
        syncState.save()
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case noVaultConfigured
    case missingSourceInfo
    case conflictNotResolved
    case syncAlreadyInProgress
    case vaultPathNotFound(String)
    case notAnObsidianVault(String)

    var errorDescription: String? {
        switch self {
        case .noVaultConfigured:
            return "No Obsidian vault path configured"
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
        }
    }
}
