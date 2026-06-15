import Foundation

/// Groups open tasks into colored, ordered sections for the floating "pinned
/// tasks" window (the always-on-top mini task manager). Pure and deterministic
/// given a reference date — no SwiftUI, no side effects, fully unit-testable.
/// The view layer maps `SectionAccent` to a concrete `Color`.
struct PinnedTasksOrganizer {

    /// How the task list is grouped. Persisted as a raw string by the view.
    enum Grouping: String, CaseIterable, Identifiable {
        case date, priority, tag, recurrence
        var id: String { rawValue }
        var label: String {
            switch self {
            case .date: return "Date"
            case .priority: return "Priority"
            case .tag: return "Tag"
            case .recurrence: return "Recurring"
            }
        }
        var systemImage: String {
            switch self {
            case .date: return "calendar"
            case .priority: return "flag"
            case .tag: return "number"
            case .recurrence: return "repeat"
            }
        }
    }

    /// A semantic accent for a section header dot — mapped to a real color in the
    /// view so this stays UI-framework-free.
    enum SectionAccent: String {
        case red, orange, blue, green, purple, gray, accent
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let accent: SectionAccent
        let tasks: [SyncTask]
    }

    /// Build display sections from a raw open-task set.
    ///
    /// The input may contain the same task several times (one copy per vault file
    /// it appears in); we de-duplicate by normalized title + due day + recurrence
    /// first, matching `AgendaBuilder`'s menu behavior, then group.
    static func sections(
        from tasks: [SyncTask],
        grouping: Grouping,
        now: Date,
        query: String = "",
        calendar: Calendar = .current
    ) -> [Section] {
        let searched = tasks.filter { matches($0, query: query) }
        let open = dedup(searched.filter { !$0.isCompleted }, calendar: calendar)
        switch grouping {
        case .date:       return byDate(open, now: now, calendar: calendar)
        case .priority:   return byPriority(open, now: now, calendar: calendar)
        case .tag:        return byTag(open, now: now, calendar: calendar)
        case .recurrence: return byRecurrence(open, now: now, calendar: calendar)
        }
    }

    // MARK: - Search

    /// Case-insensitive match on the task title or any of its tags (the leading
    /// `#` is ignored). An empty/whitespace query matches everything.
    private static func matches(_ task: SyncTask, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if task.title.lowercased().contains(q) { return true }
        return task.tags.contains { tag in
            let t = (tag.hasPrefix("#") ? String(tag.dropFirst()) : tag).lowercased()
            return t.contains(q)
        }
    }

    // MARK: - De-duplication

    private static func dedup(_ tasks: [SyncTask], calendar: Calendar) -> [SyncTask] {
        var seen = Set<String>()
        var out: [SyncTask] = []
        for task in tasks {
            let title = task.title.trimmingCharacters(in: .whitespaces).lowercased()
            let day = task.dueDate.map { Int(calendar.startOfDay(for: $0).timeIntervalSince1970) } ?? -1
            let rec = task.recurrenceRule ?? ""
            let key = "\(title)#\(day)#\(rec)"
            if seen.insert(key).inserted { out.append(task) }
        }
        return out
    }

    // MARK: - Sorting

    /// Soonest due first (no-date last), then alphabetical by title.
    private static func sortedByDueThenTitle(_ tasks: [SyncTask]) -> [SyncTask] {
        tasks.sorted { a, b in
            let da = a.dueDate ?? .distantFuture
            let db = b.dueDate ?? .distantFuture
            if da != db { return da < db }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func nonEmpty(_ id: String, _ title: String, _ accent: SectionAccent, _ tasks: [SyncTask]) -> Section? {
        tasks.isEmpty ? nil : Section(id: id, title: title, accent: accent, tasks: sortedByDueThenTitle(tasks))
    }

    // MARK: - Groupings

    private static func byDate(_ tasks: [SyncTask], now: Date, calendar: Calendar) -> [Section] {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = startToday.addingTimeInterval(86_400)
        let startNextWeek = startToday.addingTimeInterval(7 * 86_400)

        var overdue: [SyncTask] = [], today: [SyncTask] = [], soon: [SyncTask] = [],
            later: [SyncTask] = [], noDate: [SyncTask] = []
        for t in tasks {
            guard let due = t.dueDate else { noDate.append(t); continue }
            if due < startToday { overdue.append(t) }
            else if due < startTomorrow { today.append(t) }
            else if due < startNextWeek { soon.append(t) }
            else { later.append(t) }
        }
        return [
            nonEmpty("overdue", "Overdue", .red, overdue),
            nonEmpty("today", "Today", .accent, today),
            nonEmpty("soon", "This week", .blue, soon),
            nonEmpty("later", "Later", .gray, later),
            nonEmpty("nodate", "No date", .gray, noDate),
        ].compactMap { $0 }
    }

    private static func byPriority(_ tasks: [SyncTask], now: Date, calendar: Calendar) -> [Section] {
        var high: [SyncTask] = [], med: [SyncTask] = [], low: [SyncTask] = [], none: [SyncTask] = []
        for t in tasks {
            switch t.priority {
            case .high: high.append(t)
            case .medium: med.append(t)
            case .low: low.append(t)
            case .none: none.append(t)
            }
        }
        return [
            nonEmpty("high", "High", .red, high),
            nonEmpty("medium", "Medium", .orange, med),
            nonEmpty("low", "Low", .blue, low),
            nonEmpty("none", "No priority", .gray, none),
        ].compactMap { $0 }
    }

    private static func byTag(_ tasks: [SyncTask], now: Date, calendar: Calendar) -> [Section] {
        // Group by the task's first tag (its primary list); tagless tasks fall
        // into a trailing "No tag" section. Tag sections are alphabetical.
        var buckets: [String: [SyncTask]] = [:]
        var noTag: [SyncTask] = []
        for t in tasks {
            if let raw = t.tags.first, !raw.isEmpty {
                let tag = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
                buckets[tag, default: []].append(t)
            } else {
                noTag.append(t)
            }
        }
        var sections = buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { tag in nonEmpty("tag-\(tag)", "#\(tag)", .accent, buckets[tag] ?? []) }
        if let last = nonEmpty("notag", "No tag", .gray, noTag) { sections.append(last) }
        return sections
    }

    private static func byRecurrence(_ tasks: [SyncTask], now: Date, calendar: Calendar) -> [Section] {
        let recurring = tasks.filter { ($0.recurrenceRule?.isEmpty == false) }
        let oneOff = tasks.filter { ($0.recurrenceRule?.isEmpty != false) }
        return [
            nonEmpty("recurring", "Recurring", .purple, recurring),
            nonEmpty("oneoff", "One-off", .gray, oneOff),
        ].compactMap { $0 }
    }
}
