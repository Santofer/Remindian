import Foundation

/// Obsidian Tasks source — reads tasks from an Obsidian vault using the Tasks plugin format.
/// Wraps the existing ObsidianService behind the TaskSource protocol.
class ObsidianTasksSource: TaskSource {
    let sourceName = "Obsidian Tasks"

    private let obsidianService = ObsidianService()
    private let backupService = FileBackupService.shared

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        // Convert string-form marker config into Character sets the parser
        // expects. Empty entries and multi-char entries are ignored — the
        // settings UI validates input, but parser stays defensive. (#63, #70)
        let openMarkers = Set(config.obsidianTasksOpenMarkers.compactMap { $0.first })
        let completedMarkers = Set(config.obsidianTasksCompletedMarkers.compactMap { $0.first })
        let ignoredMarkers = Set(config.obsidianTasksIgnoredMarkers.compactMap { $0.first })

        var tasks = try obsidianService.scanVault(
            at: config.vaultPath,
            excludedFolders: config.excludedFolders,
            includedFolders: config.includedFolders,
            inboxRelativePath: config.inboxFilePath,
            openMarkers: openMarkers.isEmpty ? SyncTask.defaultOpenMarkers : openMarkers,
            completedMarkers: completedMarkers.isEmpty ? SyncTask.defaultCompletedMarkers : completedMarkers,
            ignoredMarkers: ignoredMarkers
        )

        // Apply global filter (#36) — only keep tasks whose original line contains the filter text
        let filter = config.globalFilter.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty {
            let before = tasks.count
            tasks = tasks.filter { task in
                guard let originalLine = task.obsidianSource?.originalLine else { return false }
                return originalLine.contains(filter)
            }
            debugLog("[ObsidianTasks] Global filter \"\(filter)\": \(before) → \(tasks.count) tasks")

            // Optionally drop the filter text from the title we hand to the
            // destination, so a non-tag filter like `TODO` doesn't ride along in
            // every reminder title. Done here (not at write time) so both sync
            // directions compare the same title. The source line is untouched. (#89)
            if config.stripGlobalFilterFromTitle {
                tasks = tasks.map { task in
                    var stripped = task
                    stripped.title = config.titleForDestination(task.title)
                    return stripped
                }
            }
        }

        // Parse dataview inline fields (#41) — augment tasks with [key::value] metadata
        if config.enableDataviewFormat {
            var augmented = 0
            tasks = tasks.map { task in
                var mutableTask = task
                if let originalLine = task.obsidianSource?.originalLine {
                    let beforeTitle = mutableTask.title
                    SyncTask.parseDataviewFields(from: originalLine, into: &mutableTask)
                    if mutableTask.title != beforeTitle || mutableTask.dueDate != task.dueDate || mutableTask.priority != task.priority {
                        augmented += 1
                    }
                }
                return mutableTask
            }
            if augmented > 0 {
                debugLog("[ObsidianTasks] Dataview fields: augmented \(augmented) tasks with inline field metadata")
            }
        }

        return tasks
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
        obsChanges.newTags = changes.newTags
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
            vaultPath: config.vaultPath,
            globalFilter: config.globalFilter
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
