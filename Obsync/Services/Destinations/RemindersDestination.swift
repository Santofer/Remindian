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

    // MARK: - Maintenance: de-duplicate reminders

    /// Remove duplicate reminders. Two reminders are "duplicates" only when they
    /// share title + due day + completion state + list — a conservative key, so
    /// genuinely-different reminders that happen to share a title are never
    /// touched. Within each duplicate group the copy carrying an `obsidian://`
    /// URL (the synced/canonical one) is kept, else the first. `dryRun` only
    /// counts what would be removed. Returns the count removed / removable.
    ///
    /// This cleans up the mess left by older buggy versions that created the same
    /// reminder many times. (cleanup tool)
    /// Find reminders that are duplicates of each other and delete all but one.
    /// Only groups Remindian has a hand in are considered — see `DuplicateReminders`.
    ///
    /// - Parameter ignoreDueDate: when true, copies of the same title in the same
    ///   list count as duplicates even when their due dates differ. Recurring
    ///   tasks accumulate exactly that way — one copy per occurrence, each with a
    ///   different date — so the default strict key can never see them. Off by
    ///   default because two same-titled reminders with different dates *can* be
    ///   deliberate; always show the caller a dry run first.
    /// - Returns: the titles affected (or that would be, for a dry run).
    func removeDuplicateReminders(dryRun: Bool, ignoreDueDate: Bool = false, mappedIds: Set<String> = []) async throws -> [String] {
        let lists = eventStore.calendars(for: .reminder)
        let all: [EKReminder] = try await withThrowingTaskGroup(of: [EKReminder].self) { group in
            for list in lists {
                group.addTask {
                    let predicate = self.eventStore.predicateForReminders(in: [list])
                    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[EKReminder], Error>) in
                        self.eventStore.fetchReminders(matching: predicate) { c.resume(returning: $0 ?? []) }
                    }
                }
            }
            var out: [EKReminder] = []
            for try await r in group { out.append(contentsOf: r) }
            return out
        }

        let byId = Dictionary(all.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = DuplicateReminders.plan(
            all.map { r in
                DuplicateReminders.Item(
                    id: r.calendarItemIdentifier,
                    title: (r.title ?? "").trimmingCharacters(in: .whitespaces),
                    listId: r.calendar?.calendarIdentifier ?? "?",
                    listName: r.calendar?.title ?? "?",
                    isCompleted: r.isCompleted,
                    due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    isLinked: r.url?.scheme == "obsidian")
            },
            mappedIds: mappedIds,
            ignoreDueDate: ignoreDueDate)

        // The whole plan goes to the log: the confirmation dialog can only show a
        // handful of titles, and a pile-up runs to thousands.
        let total = groups.reduce(0) { $0 + $1.remove.count }
        debugLog("[RemindersDestination] Duplicate \(dryRun ? "preview" : "removal"): \(total) reminder(s) in \(groups.count) group(s), of \(all.count) total (ignoreDueDate=\(ignoreDueDate), mapped=\(mappedIds.count)).")
        for g in groups.sorted(by: { $0.remove.count > $1.remove.count }).prefix(200) {
            debugLog("[RemindersDestination]   \"\(g.title)\" in \(g.listName): \(g.total) copies → remove \(g.remove.count) (\(g.removeOpen) open, \(g.remove.count - g.removeOpen) completed), keep \(g.total - g.remove.count)")
        }

        let toDelete = groups.flatMap { g in g.remove.compactMap { byId[$0] } }
        let titles = toDelete.map { $0.title ?? "(untitled)" }
        if dryRun { return titles }

        var removed = 0
        for (n, r) in toDelete.enumerated() {
            do { try eventStore.remove(r, commit: false); removed += 1 }
            catch { debugLog("[RemindersDestination] Failed to remove duplicate '\(r.title ?? "?")': \(error.localizedDescription)") }
            // Commit in batches so one failure can't lose thousands of removals.
            if (n + 1) % 500 == 0 { try? eventStore.commit() }
        }
        if removed > 0 { try? eventStore.commit() }
        debugLog("[RemindersDestination] Removed \(removed) duplicate reminder(s) of \(toDelete.count) candidates across \(all.count) total (ignoreDueDate=\(ignoreDueDate)).")
        return titles
    }

    /// The reminder as EventKit holds it now, shaped exactly like `fetchAllTasks`
    /// reports it, so the engine can fingerprint reality instead of a prediction.
    func currentTask(withId id: String) async -> SyncTask? {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return SyncTask.fromReminder(reminder, listName: reminder.calendar?.title ?? "")
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
            appendLinkToNotes: config.appendTaskLinkToNotes,
            addReminderAlarm: config.addReminderAlarm,
            allDayAlarmHour: config.reminderAlarmHour,
            writeTagsToNotes: config.writeTagsToReminderNotes,
            keepUserNotes: !(config.enableTagWriteback && config.writeTagsToReminderNotes)
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
            appendLinkToNotes: config.appendTaskLinkToNotes,
            addReminderAlarm: config.addReminderAlarm,
            allDayAlarmHour: config.reminderAlarmHour,
            writeTagsToNotes: config.writeTagsToReminderNotes,
            keepUserNotes: !(config.enableTagWriteback && config.writeTagsToReminderNotes)
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

/// Which reminders a duplicate cleanup may delete. Pure, so every rule is testable
/// without EventKit.
enum DuplicateReminders {
    struct Item {
        let id: String
        let title: String
        let listId: String
        let listName: String
        let isCompleted: Bool
        let due: Date?
        /// Carries an `obsidian://` link, i.e. Remindian wrote it.
        let isLinked: Bool
    }

    struct Group {
        let title: String
        let listName: String
        let total: Int
        /// Identifiers to delete.
        let remove: [String]
        let removeOpen: Int
    }

    /// - A group is the same title in the same list (and, unless `ignoreDueDate`,
    ///   the same due day and completion state).
    /// - **Scope:** a group is only touched when Remindian manages at least one of
    ///   its members — one is mapped to a vault task or carries an Obsidian link.
    ///   The cleanup used to consider every reminder in every list, so the
    ///   completion history of the user's own repeating reminders, shared lists
    ///   and anything another app created were all fair game.
    /// - **Kept:** every mapped reminder (deleting one would only make the next
    ///   sync re-create it), plus the one the user still acts on — open beats
    ///   completed, then the latest due date; in strict mode the linked copy.
    static func plan(_ items: [Item], mappedIds: Set<String>, ignoreDueDate: Bool, calendar: Calendar = .current) -> [Group] {
        func key(_ i: Item) -> String {
            if ignoreDueDate { return "\(i.title)|\(i.listId)" }
            let due = i.due.map { d -> String in
                let c = calendar.dateComponents([.year, .month, .day], from: d)
                return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
            } ?? "none"
            return "\(i.title)|\(due)|\(i.isCompleted)|\(i.listId)"
        }
        func outranks(_ a: Item, _ b: Item) -> Bool {      // is `a` a better keeper than `b`?
            let aMapped = mappedIds.contains(a.id), bMapped = mappedIds.contains(b.id)
            if ignoreDueDate {
                if a.isCompleted != b.isCompleted { return !a.isCompleted }
                // A mapped copy is kept anyway — let it be the keeper, so no
                // second copy in the same state survives alongside it.
                if aMapped != bMapped { return aMapped }
                return (a.due ?? .distantPast) > (b.due ?? .distantPast)
            }
            if aMapped != bMapped { return aMapped }
            return a.isLinked && !b.isLinked
        }

        var grouped: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let k = key(item)
            if grouped[k] == nil { order.append(k) }
            grouped[k, default: []].append(item)
        }

        var plan: [Group] = []
        for k in order {
            guard let members = grouped[k], members.count > 1,
                  members.contains(where: { $0.isLinked || mappedIds.contains($0.id) }) else { continue }
            var keeper = members[0]
            for m in members.dropFirst() where outranks(m, keeper) { keeper = m }
            let remove = members.filter { $0.id != keeper.id && !mappedIds.contains($0.id) }
            guard !remove.isEmpty else { continue }
            plan.append(Group(title: members[0].title, listName: members[0].listName, total: members.count,
                              remove: remove.map(\.id), removeOpen: remove.filter { !$0.isCompleted }.count))
        }
        return plan
    }
}
