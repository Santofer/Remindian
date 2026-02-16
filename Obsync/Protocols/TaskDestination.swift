import Foundation

/// Protocol for task destinations — where tasks are synced to (Apple Reminders, Things 3, etc.)
protocol TaskDestination {
    /// Human-readable name for this destination (e.g., "Apple Reminders", "Things 3")
    var destinationName: String { get }

    /// Request access/authorization for this destination.
    /// Returns true if access was granted.
    func requestAccess() async throws -> Bool

    /// Fetch all tasks currently in the destination.
    func fetchAllTasks() async throws -> [SyncTask]

    /// Get all available lists/projects in the destination.
    func getAvailableLists() -> [String]

    /// Create a new task in the destination.
    /// Returns the destination's identifier for the created task.
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) throws -> String

    /// Update an existing task in the destination.
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) throws

    /// Move a task to a different list/project.
    func moveTask(withId id: String, toList listName: String) throws

    /// Delete a task from the destination.
    func deleteTask(withId id: String) throws

    /// Refresh the destination's internal state (e.g., after external changes).
    func refresh()
}
