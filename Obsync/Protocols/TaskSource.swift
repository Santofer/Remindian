import Foundation

/// Protocol for task sources — where tasks are read from (Obsidian vault, TaskNotes, etc.)
/// The source is always the "source of truth" for task content.
protocol TaskSource {
    /// Human-readable name for this source (e.g., "Obsidian Tasks", "TaskNotes")
    var sourceName: String { get }

    /// Scan the source and return all tasks.
    /// - Parameters:
    ///   - config: The sync configuration
    /// - Returns: Array of tasks found in the source
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask]

    /// Generate a stable ID for a task from this source.
    /// IDs must be deterministic and stable across runs (same task → same ID).
    func generateTaskId(for task: SyncTask) -> String

    /// Surgically mark a task as completed in the source.
    /// Returns the number of lines/items inserted (for offset tracking).
    @discardableResult
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int

    /// Surgically mark a task as incomplete in the source.
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws

    /// Surgically update task metadata (due date, start date, priority) in the source.
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws

    /// Append a new task to the source's inbox/default location.
    /// Returns source info for mapping (file path, line number, line content).
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource

    /// Check if a source file has been modified since a given timestamp.
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool
}

/// Metadata changes to apply in a single atomic edit.
struct MetadataChanges {
    var newDueDate: Date?? = nil    // nil = no change, .some(nil) = remove, .some(date) = set
    var newStartDate: Date?? = nil
    var newPriority: SyncTask.Priority? = nil  // nil = no change

    var hasChanges: Bool {
        return newDueDate != nil || newStartDate != nil || newPriority != nil
    }
}
