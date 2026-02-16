import Foundation
import EventKit

/// Apple Reminders destination using EventKit.
/// Wraps the existing RemindersService behind the TaskDestination protocol.
class RemindersDestination: TaskDestination {
    let destinationName = "Apple Reminders"

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

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        let lists = eventStore.calendars(for: .reminder)
        var allTasks: [SyncTask] = []

        for list in lists {
            let predicate = eventStore.predicateForReminders(in: [list])
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    if let reminders = reminders {
                        continuation.resume(returning: reminders)
                    } else {
                        continuation.resume(throwing: RemindersError.fetchFailed)
                    }
                }
            }
            allTasks.append(contentsOf: reminders.map { SyncTask.fromReminder($0, listName: list.title) })
        }

        return allTasks
    }

    func getAvailableLists() -> [String] {
        return eventStore.calendars(for: .reminder).map { $0.title }
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) throws -> String {
        let list = try getOrCreateList(named: listName)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = list
        task.applyToReminder(reminder, includeDueTime: config.includeDueTime)
        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        task.applyToReminder(reminder, includeDueTime: config.includeDueTime)
        try eventStore.save(reminder, commit: true)
    }

    func moveTask(withId id: String, toList listName: String) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        let list = try getOrCreateList(named: listName)
        reminder.calendar = list
        try eventStore.save(reminder, commit: true)
    }

    func deleteTask(withId id: String) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        try eventStore.remove(reminder, commit: true)
    }

    func refresh() {
        eventStore.reset()
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
