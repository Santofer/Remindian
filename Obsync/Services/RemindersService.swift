import Foundation
import EventKit

/// Service for interacting with Apple Reminders via EventKit
class RemindersService {
    private let eventStore = EKEventStore()
    private var hasAccess = false
    
    // MARK: - Authorization
    
    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            hasAccess = try await eventStore.requestFullAccessToReminders()
        } else {
            hasAccess = try await eventStore.requestAccess(to: .reminder)
        }
        return hasAccess
    }
    
    func checkAuthorizationStatus() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .reminder)
    }
    
    // MARK: - Lists Management
    
    /// Get all reminder lists
    func getAllLists() -> [EKCalendar] {
        return eventStore.calendars(for: .reminder)
    }
    
    /// Get or create a reminder list by name
    func getOrCreateList(named name: String) throws -> EKCalendar {
        // First try to find existing list
        if let existingList = eventStore.calendars(for: .reminder).first(where: { $0.title == name }) {
            return existingList
        }
        
        // Create new list
        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = name
        
        // Use default source
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
    
    // MARK: - Fetching Reminders
    
    /// Fetch all reminders from a specific list
    func fetchReminders(from listName: String) async throws -> [SyncTask] {
        guard let list = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
            return []
        }
        
        return try await fetchReminders(from: list)
    }
    
    /// Fetch all reminders from a calendar
    func fetchReminders(from calendar: EKCalendar) async throws -> [SyncTask] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        
        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: RemindersError.fetchFailed)
                }
            }
        }
        
        return reminders.map { SyncTask.fromReminder($0, listName: calendar.title) }
    }
    
    /// Fetch all reminders from all lists
    func fetchAllReminders() async throws -> [SyncTask] {
        let lists = getAllLists()
        var allTasks: [SyncTask] = []
        
        for list in lists {
            let tasks = try await fetchReminders(from: list)
            allTasks.append(contentsOf: tasks)
        }
        
        return allTasks
    }
    
    /// Fetch a specific reminder by ID
    func fetchReminder(withId id: String) -> EKReminder? {
        return eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }
    
    // MARK: - Creating Reminders
    
    /// Create a new reminder from a SyncTask
    func createReminder(from task: SyncTask, inList listName: String, includeDueTime: Bool = false) throws -> String {
        let list = try getOrCreateList(named: listName)
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = list
        task.applyToReminder(reminder, includeDueTime: includeDueTime)
        
        try eventStore.save(reminder, commit: true)
        
        return reminder.calendarItemIdentifier
    }
    
    // MARK: - Updating Reminders
    
    /// Update an existing reminder
    func updateReminder(withId id: String, from task: SyncTask, includeDueTime: Bool = false) throws {
        guard let reminder = fetchReminder(withId: id) else {
            throw RemindersError.reminderNotFound(id)
        }
        
        task.applyToReminder(reminder, includeDueTime: includeDueTime)
        try eventStore.save(reminder, commit: true)
    }
    
    /// Move a reminder to a different list
    func moveReminder(withId id: String, toList listName: String) throws {
        guard let reminder = fetchReminder(withId: id) else {
            throw RemindersError.reminderNotFound(id)
        }
        
        let list = try getOrCreateList(named: listName)
        reminder.calendar = list
        try eventStore.save(reminder, commit: true)
    }
    
    // MARK: - Deleting Reminders
    
    /// Delete a reminder
    func deleteReminder(withId id: String) throws {
        guard let reminder = fetchReminder(withId: id) else {
            throw RemindersError.reminderNotFound(id)
        }
        
        try eventStore.remove(reminder, commit: true)
    }
    
    // MARK: - Batch Operations
    
    /// Commit all pending changes
    func commitChanges() throws {
        try eventStore.commit()
    }
    
    /// Reset the event store (useful after external changes)
    func refreshStore() {
        eventStore.reset()
    }
}

// MARK: - Errors

enum RemindersError: LocalizedError {
    case accessDenied
    case noSourceAvailable
    case fetchFailed
    case reminderNotFound(String)
    case listNotFound(String)
    case saveFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to Reminders was denied. Please grant access in System Settings > Privacy & Security > Reminders."
        case .noSourceAvailable:
            return "No source available to create reminder lists."
        case .fetchFailed:
            return "Failed to fetch reminders."
        case .reminderNotFound(let id):
            return "Reminder not found with ID: \(id)"
        case .listNotFound(let name):
            return "Reminder list not found: \(name)"
        case .saveFailed(let error):
            return "Failed to save reminder: \(error.localizedDescription)"
        }
    }
}
