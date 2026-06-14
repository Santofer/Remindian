import Foundation

/// Builds the menu-bar "Today" agenda from a task set. (Today list)
///
/// Pure and deterministic given a reference date: selects open tasks whose due
/// date is today or earlier (overdue + due-today), sorted soonest-first. A task
/// due today is *not* considered overdue. Tasks with no due date are excluded.
struct AgendaBuilder {

    /// Open tasks due today or earlier, sorted by due date ascending.
    ///
    /// De-duplicated for display: the same task can appear in several vault files
    /// (the sync engine maps only one copy, but a raw scan returns all), which
    /// otherwise showed the task multiple times in the menu. Collapse entries
    /// that share a normalized title + due day, keeping the first.
    static func build(from tasks: [SyncTask], now: Date, calendar: Calendar = .current) -> [SyncTask] {
        let startOfTomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let due = tasks
            .filter { !$0.isCompleted }
            .filter { task in
                guard let d = task.dueDate else { return false }
                return d < startOfTomorrow
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

        var seen = Set<String>()
        var deduped: [SyncTask] = []
        for task in due {
            let title = task.title.trimmingCharacters(in: .whitespaces).lowercased()
            let day = task.dueDate.map { Int(calendar.startOfDay(for: $0).timeIntervalSince1970) } ?? -1
            let key = "\(title)#\(day)"
            if seen.insert(key).inserted { deduped.append(task) }
        }
        return deduped
    }

    /// True if the task's due date is before the start of today (strictly past).
    static func isOverdue(_ task: SyncTask, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = task.dueDate else { return false }
        return due < calendar.startOfDay(for: now)
    }
}
