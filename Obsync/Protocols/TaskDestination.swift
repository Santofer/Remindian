import Foundation

/// Protocol for task destinations — where tasks are synced to (Apple Reminders, Things 3, etc.)
/// Class-bound so mutable reference semantics (e.g. `progressCallback`) work
/// through the protocol type without forcing each conformer to be a struct.
protocol TaskDestination: AnyObject {
    /// Human-readable name for this destination (e.g., "Apple Reminders", "Things 3")
    var destinationName: String { get }

    /// Request access/authorization for this destination.
    /// Returns true if access was granted.
    func requestAccess() async throws -> Bool

    /// Fetch all tasks currently in the destination.
    func fetchAllTasks() async throws -> [SyncTask]

    /// Get all available lists/projects in the destination.
    func getAvailableLists() async -> [String]

    /// Create a new task in the destination.
    /// Returns the destination's identifier for the created task.
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String

    /// Update an existing task in the destination.
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws

    /// Move a task to a different list/project.
    func moveTask(withId id: String, toList listName: String) async throws

    /// Delete a task from the destination.
    func deleteTask(withId id: String) async throws

    /// Refresh the destination's internal state (e.g., after external changes).
    func refresh()

    /// Optional progress callback invoked during long-running operations (e.g.
    /// per-list fetching). Set by the sync engine before calling `fetchAllTasks`
    /// so the UI can show granular progress (e.g. "Fetching Things 3 (Today)…"
    /// then "Fetching Things 3 (Inbox)…"). Destinations that don't implement
    /// granular progress can ignore this.
    var progressCallback: ((String) -> Void)? { get set }

    /// The task as the destination holds it *right now*, in the same shape
    /// `fetchAllTasks` would report it. Used after a push to record what the
    /// destination actually stored instead of predicting it.
    ///
    /// Destinations are lossy — Apple Reminders drops the time-of-day when "Include
    /// due time" is off, rewrites recurrence rules, stamps its own completion date —
    /// so a predicted fingerprint can disagree with reality forever, and the engine
    /// then sees a phantom destination-side change on every sync (#99). Return nil
    /// when a cheap single-item read isn't available; the engine falls back to
    /// its prediction.
    func currentTask(withId id: String) async -> SyncTask?
}

/// Default no-op implementation so existing destinations don't need to opt in.
extension TaskDestination {
    var progressCallback: ((String) -> Void)? {
        get { nil }
        set { /* default no-op */ }
    }

    func currentTask(withId id: String) async -> SyncTask? { nil }
}
