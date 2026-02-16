import Foundation

/// Obsidian Tasks source — reads tasks from an Obsidian vault using the Tasks plugin format.
/// Wraps the existing ObsidianService behind the TaskSource protocol.
class ObsidianTasksSource: TaskSource {
    let sourceName = "Obsidian Tasks"

    private let obsidianService = ObsidianService()
    private let backupService = FileBackupService.shared

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        return try obsidianService.scanVault(
            at: config.vaultPath,
            excludedFolders: config.excludedFolders,
            includedFolders: config.includedFolders
        )
    }

    func generateTaskId(for task: SyncTask) -> String {
        return SyncState.generateObsidianId(task: task)
    }

    @discardableResult
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }
        return try obsidianService.markTaskComplete(
            filePath: source.filePath,
            lineNumber: source.lineNumber,
            originalLine: source.originalLine,
            completionDate: completionDate,
            vaultPath: config.vaultPath
        )
    }

    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }
        try obsidianService.markTaskIncomplete(
            filePath: source.filePath,
            lineNumber: source.lineNumber,
            originalLine: source.originalLine,
            vaultPath: config.vaultPath
        )
    }

    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }
        // Convert protocol MetadataChanges to ObsidianService.MetadataChanges
        var obsChanges = ObsidianService.MetadataChanges()
        obsChanges.newDueDate = changes.newDueDate
        obsChanges.newStartDate = changes.newStartDate
        obsChanges.newPriority = changes.newPriority
        try obsidianService.updateTaskMetadata(
            filePath: source.filePath,
            lineNumber: source.lineNumber,
            originalLine: source.originalLine,
            changes: obsChanges,
            vaultPath: config.vaultPath
        )
    }

    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        let result = try obsidianService.appendTaskToInbox(
            task: task,
            inboxRelativePath: config.inboxFilePath,
            vaultPath: config.vaultPath
        )
        return SyncTask.ObsidianSource(
            filePath: result.filePath,
            lineNumber: result.lineNumber,
            originalLine: result.lineContent
        )
    }

    func hasFileChanged(task: SyncTask, since timestamp: Date, config: SyncConfiguration) -> Bool {
        guard let source = task.obsidianSource else { return true }
        return obsidianService.hasFileChanged(
            filePath: source.filePath,
            since: timestamp,
            vaultPath: config.vaultPath
        )
    }
}
