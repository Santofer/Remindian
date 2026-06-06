import Foundation
import EventKit

/// Apple Reminders destination using EventKit.
/// Wraps the existing RemindersService behind the TaskDestination protocol.
class RemindersDestination: TaskDestination {
    let destinationName = "Apple Reminders"

    private let eventStore = EKEventStore()
    private var hasAccess = false

    /// Max retry attempts for transient EventKit failures.
    private let maxRetries = 3
    /// Base delay between retries (doubles each attempt).
    private let baseRetryDelay: TimeInterval = 0.5

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            hasAccess = try await eventStore.requestFullAccessToReminders()
        } else {
            hasAccess = try await eventStore.requestAccess(to: .reminder)
        }
        return hasAccess
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        let lists = eventStore.calendars(for: .reminder)

        // Fetch every list concurrently. EventKit's `fetchReminders` is
        // independent per-predicate and safe to run in parallel, so on an
        // account with several lists this collapses N sequential round-trips
        // into one concurrent batch. Result order is irrelevant — downstream
        // dedup/mapping keys on stable task identity, not array position.
        //
        // Error semantics are unchanged: if any list fails, the group cancels
        // the rest and the error propagates, exactly as the old sequential loop
        // aborted on the first failure.
        return try await withThrowingTaskGroup(of: [SyncTask].self) { group in
            for list in lists {
                group.addTask {
                    let predicate = self.eventStore.predicateForReminders(in: [list])
                    let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                        self.eventStore.fetchReminders(matching: predicate) { reminders in
                            if let reminders = reminders {
                                continuation.resume(returning: reminders)
                            } else {
                                continuation.resume(throwing: RemindersError.fetchFailed)
                            }
                        }
                    }
                    return reminders.map { SyncTask.fromReminder($0, listName: list.title) }
                }
            }

            var allTasks: [SyncTask] = []
            for try await listTasks in group {
                allTasks.append(contentsOf: listTasks)
            }
            return allTasks
        }
    }

    func getAvailableLists() async -> [String] {
        return eventStore.calendars(for: .reminder).map { $0.title }
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let list = try getOrCreateList(named: listName)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = list
        task.applyToReminder(
            reminder,
            includeDueTime: config.includeDueTime,
            addTaskLink: config.addTaskLinkToReminders,
            vaultPath: config.vaultPath,
            appendLinkToNotes: config.appendTaskLinkToNotes
        )
        try await retryEventKitOperation(label: "create '\(task.title)'") {
            try self.eventStore.save(reminder, commit: true)
        }
        return reminder.calendarItemIdentifier
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        task.applyToReminder(
            reminder,
            includeDueTime: config.includeDueTime,
            addTaskLink: config.addTaskLinkToReminders,
            vaultPath: config.vaultPath,
            appendLinkToNotes: config.appendTaskLinkToNotes
        )
        try await retryEventKitOperation(label: "update '\(task.title)'") {
            try self.eventStore.save(reminder, commit: true)
        }
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        let list = try getOrCreateList(named: listName)
        reminder.calendar = list
        try await retryEventKitOperation(label: "move to '\(listName)'") {
            try self.eventStore.save(reminder, commit: true)
        }
    }

    func deleteTask(withId id: String) async throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        try await retryEventKitOperation(label: "delete") {
            try self.eventStore.remove(reminder, commit: true)
        }
    }

    func refresh() {
        eventStore.reset()
    }

    // MARK: - Retry Logic

    /// Retry an EventKit save/remove operation with exponential backoff.
    /// Resets the event store between retries to clear stale cache state.
    private func retryEventKitOperation(label: String, operation: () throws -> Void) async throws {
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                try operation()
                return
            } catch {
                lastError = error
                let isTransient = Self.isTransientEventKitError(error)
                debugLog("[RemindersDestination] \(label) attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription) (transient: \(isTransient))")
                if !isTransient || attempt == maxRetries { break }
                // Reset store to clear stale cache, then wait before retry
                eventStore.reset()
                let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw EventKitSyncError.from(lastError!)
    }

    /// Determine if an EventKit error is transient and worth retrying.
    private static func isTransientEventKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // ReminderKit/EventKit internal errors (e.g. -3002 database sync issues)
        if nsError.domain == "com.apple.reminderkit" { return true }
        if nsError.domain == "EKErrorDomain" {
            // EKErrorInternalFailure (code 0) and similar transient codes
            return nsError.code == 0 || nsError.code == 1
        }
        return false
    }

    // MARK: - Private Helpers

    private func getOrCreateList(named name: String) throws -> EKCalendar {
        if let existingList = eventStore.calendars(for: .reminder).first(where: { $0.title == name }) {
            return existingList
        }

        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = name

        if let defaultSource = eventStore.defaultCalendarForNewReminders()?.source {
            newList.source = defaultSource
        } else if let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) {
            newList.source = localSource
        } else if let firstSource = eventStore.sources.first {
            newList.source = firstSource
        } else {
            throw RemindersError.noSourceAvailable
        }

        try eventStore.saveCalendar(newList, commit: true)
        return newList
    }
}

// MARK: - EventKit Error Translation

/// User-friendly wrapper for EventKit/ReminderKit errors with actionable messages.
struct EventKitSyncError: LocalizedError {
    let underlyingError: Error
    let userMessage: String

    var errorDescription: String? { userMessage }

    static func from(_ error: Error) -> EventKitSyncError {
        let nsError = error as NSError
        let userMessage: String

        if nsError.domain == "com.apple.reminderkit" {
            switch nsError.code {
            case -3002:
                userMessage = "Reminders database sync conflict. Try restarting Reminders.app or toggling iCloud Reminders off and on in System Settings."
            case -3999...(-3001):
                userMessage = "Reminders internal error (\(nsError.code)). Restarting Reminders.app or rebooting may help."
            default:
                userMessage = "Reminders error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        } else if nsError.domain == "EKErrorDomain" {
            switch nsError.code {
            case 0:
                userMessage = "EventKit internal failure. Try rebooting to reset the Reminders daemon."
            case 1:
                userMessage = "Reminder was modified by another app during sync. The next sync should resolve this."
            case 14:
                userMessage = "Calendar source is read-only. Check that your Reminders account allows modifications."
            default:
                userMessage = "EventKit error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        } else {
            userMessage = error.localizedDescription
        }

        return EventKitSyncError(underlyingError: error, userMessage: userMessage)
    }
}
