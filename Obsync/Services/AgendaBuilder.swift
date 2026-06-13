import Foundation

/// Builds the menu-bar "Today" agenda from a task set. (Today list)
///
/// Pure and deterministic given a reference date: selects open tasks whose due
/// date is today or earlier (overdue + due-today), sorted soonest-first. A task
/// due today is *not* considered overdue. Tasks with no due date are excluded.
struct AgendaBuilder {

    /// Open tasks due today or earlier, sorted by due date ascending.
    static func build(from tasks: [SyncTask], now: Date, calendar: Calendar = .current) -> [SyncTask] {
        let startOfTomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        return tasks
            .filter { !$0.isCompleted }
            .filter { task in
                guard let due = task.dueDate else { return false }
                return due < startOfTomorrow
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    /// True if the task's due date is before the start of today (strictly past).
    static func isOverdue(_ task: SyncTask, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = task.dueDate else { return false }
        return due < calendar.startOfDay(for: now)
    }
}
