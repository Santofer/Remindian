import XCTest
import EventKit
@testable import Remindian

/// #99 — "Reminders changed" logged on every sync, forever, with nothing changing.
///
/// After pushing a task the engine used to store a *predicted* fingerprint of the
/// reminder ("what it should now look like"). A destination is lossy, though: with
/// "Include due time" off, a task due at 10:00 becomes an all-day reminder, so the
/// prediction (10:00) never matches what the next fetch returns (midnight). The
/// engine then saw a phantom Reminders-side change on every single sync — one
/// user logged it 16,500 times for one task and grew a 327 MB debug log.
final class PhantomChangeLoopTests: XCTestCase {

    private func dueAt(hour: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 14; c.hour = hour
        return Calendar.current.date(from: c)!
    }

    private func makeEngine(task: SyncTask) -> (SyncEngine, LossyDestination, SyncConfiguration, TempVaultPL) {
        let vault = try! TempVaultPL()
        let destination = LossyDestination()
        let engine = SyncEngine(source: FixedSource(scanned: [task]), destination: destination, syncState: SyncState())
        let config = SyncConfiguration()
        config.vaultPath = vault.path
        return (engine, destination, config, vault)
    }

    private func timedTask() -> SyncTask {
        SyncTask(
            title: "Dentist",
            isCompleted: false,
            dueDate: dueAt(hour: 10),
            obsidianSource: SyncTask.ObsidianSource(filePath: "/tasks/dentist.md", lineNumber: 1, originalLine: "due: 2026-10-14T10:00")
        )
    }

    func test_99_lossyDestinationSettlesInsteadOfLoopingForever() async {
        let (engine, destination, config, vault) = makeEngine(task: timedTask())
        defer { vault.cleanup() }

        _ = await engine.performSync(config: config)          // creates
        _ = await engine.performSync(config: config)          // may reconcile once
        let before = destination.updateCount

        for round in 3...6 {
            let result = await engine.performSync(config: config)
            XCTAssertEqual(result.updated, 0,
                           "Sync \(round): nothing changed on either side, so nothing may be reported as updated")
        }
        XCTAssertEqual(destination.updateCount, before,
                       "A settled task must not be pushed again on every sync")
    }

    func test_99_realReminderEditIsStillDetected() async throws {
        // The fix must not blind the engine: a genuine edit in Reminders still counts.
        let (engine, destination, config, vault) = makeEngine(task: timedTask())
        defer { vault.cleanup() }

        _ = await engine.performSync(config: config)
        _ = await engine.performSync(config: config)
        _ = await engine.performSync(config: config)

        destination.userEdits { $0.priority = .high }

        let result = await engine.performSync(config: config)
        XCTAssertEqual(result.updated, 1, "A real change made in Reminders must still be picked up")
    }
}

/// #98 — deleting tasks in Obsidian must delete their reminders, not wedge the sync.
final class SourceDeletionTests: XCTestCase {

    private func task(_ n: Int) -> SyncTask {
        SyncTask(title: "Task \(n)", isCompleted: false,
                 obsidianSource: SyncTask.ObsidianSource(filePath: "/tasks.md", lineNumber: n, originalLine: "- [ ] Task \(n)"))
    }

    private func syncedEngine(count: Int) async -> (SyncEngine, FixedSource, LossyDestination, SyncConfiguration, TempVaultPL) {
        let vault = try! TempVaultPL()
        let source = FixedSource(scanned: (1...count).map(task))
        let destination = LossyDestination()
        let engine = SyncEngine(source: source, destination: destination, syncState: SyncState())
        let config = SyncConfiguration()
        config.vaultPath = vault.path
        _ = await engine.performSync(config: config)
        return (engine, source, destination, config, vault)
    }

    func test_98_deletingMoreThanHalfTheTasksDeletesTheirReminders() async throws {
        let (engine, source, destination, config, vault) = await syncedEngine(count: 12)
        defer { vault.cleanup() }

        source.scanned = (1...5).map(task)          // 7 of 12 deleted in Obsidian
        let result = await engine.performSync(config: config)

        XCTAssertTrue(result.errors.isEmpty, "A plain deletion is not an error. Got: \(result.errors)")
        XCTAssertEqual(result.deleted, 7)
        let remaining = try await destination.fetchAllTasks()
        XCTAssertEqual(remaining.count, 5)

        // And the sync is not wedged afterwards.
        let next = await engine.performSync(config: config)
        XCTAssertTrue(next.errors.isEmpty)
        XCTAssertEqual(next.deleted, 0)
    }

    func test_98_anEmptyScanStillTouchesNothing() async throws {
        // The failure the old check existed for: the vault could not be read.
        let (engine, source, destination, config, vault) = await syncedEngine(count: 12)
        defer { vault.cleanup() }

        source.scanned = []
        let result = await engine.performSync(config: config)

        XCTAssertEqual(result.deleted, 0)
        XCTAssertFalse(result.errors.isEmpty, "An empty scan must be reported, not acted on")
        let remaining = try await destination.fetchAllTasks()
        XCTAssertEqual(remaining.count, 12)
    }

    func test_98_aNarrowedScanIsStillStoppedByTheDeletionLimit() async throws {
        let (engine, source, destination, config, vault) = await syncedEngine(count: 60)
        defer { vault.cleanup() }

        source.scanned = (1...20).map(task)          // 40 would go — over the default 25
        let result = await engine.performSync(config: config)

        XCTAssertEqual(result.deleted, 0)
        let remaining = try await destination.fetchAllTasks()
        XCTAssertEqual(remaining.count, 60, "Over the limit nothing is removed")
    }
}

/// Completed vault lines and natively recurring reminders.
///
/// Apple never stores "completed" on a recurring reminder: saving one rolls it
/// forward to its next occurrence (same identifier, new due date, incomplete) and
/// leaves a completed copy behind. Two things followed from that:
///
/// - A completed line that still carries its recurrence rule was pushed *with* the
///   rule, so whichever reminder received it became a new live recurring reminder
///   plus a completed copy.
/// - The reminder never ended up completed, so "vault says done, reminder says not
///   done" held forever and the push repeated on every sync.
///
/// One real vault reached 16,000 reminders this way.
final class RecurringReminderTests: XCTestCase {

    private func day(_ month: Int, _ d: Int = 1) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = d
        return Calendar.current.date(from: c)!
    }

    /// A vault line as the scanner produces it: the completed copy of a recurring
    /// task keeps its rule.
    private func line(completed: Bool, due: Date, rule: String? = "every month") -> SyncTask {
        SyncTask(title: "Pay rent", isCompleted: completed, dueDate: due,
                 completedDate: completed ? due : nil,
                 obsidianSource: SyncTask.ObsidianSource(filePath: "/Bills.md", lineNumber: 1, originalLine: "- [ ] Pay rent"),
                 recurrenceRule: rule)
    }

    private func makeEngine(vault tasks: [SyncTask], destination: EventKitLikeDestination, mappedTo remindersId: String? = nil)
        -> (SyncEngine, SyncState, SyncConfiguration, TempVaultPL) {
        let vault = try! TempVaultPL()
        let state = SyncState()
        if let remindersId, let first = tasks.first {
            state.addOrUpdateMapping(obsidianId: "fixed-\(first.title)", remindersId: remindersId,
                                     obsidianHash: SyncState.generateTaskHash(first), remindersHash: "")
        }
        let engine = SyncEngine(source: FixedSource(scanned: tasks), destination: destination, syncState: state)
        let config = SyncConfiguration()
        config.vaultPath = vault.path
        return (engine, state, config, vault)
    }

    // MARK: What is written to a reminder

    func test_aCompletedLineDoesNotCarryItsRecurrenceRuleIntoTheReminder() {
        let reminder = EKReminder(eventStore: EKEventStore())
        line(completed: true, due: day(6)).applyToReminder(reminder)
        XCTAssertTrue(reminder.isCompleted)
        XCTAssertFalse(reminder.hasRecurrenceRules, "Completed + recurring is what makes Apple spawn the next occurrence")
    }

    func test_anOpenRecurringLineStillMakesTheReminderRecurring() {
        let reminder = EKReminder(eventStore: EKEventStore())
        line(completed: false, due: day(12)).applyToReminder(reminder)
        XCTAssertTrue(reminder.hasRecurrenceRules)
    }

    func test_completingALiveRecurringReminderLeavesItsRuleInPlace() {
        // …so that Apple can still roll it forward to the next occurrence.
        let reminder = EKReminder(eventStore: EKEventStore())
        line(completed: false, due: day(12)).applyToReminder(reminder)
        line(completed: true, due: day(12), rule: nil).applyToReminder(reminder)
        XCTAssertTrue(reminder.hasRecurrenceRules)
    }

    func test_aCompletedCopyThatStillCarriesARuleIsMadePlainHistory() {
        // If a completed occurrence keeps its rule, touching it must not revive it.
        let reminder = EKReminder(eventStore: EKEventStore())
        line(completed: false, due: day(6)).applyToReminder(reminder)
        reminder.isCompleted = true
        XCTAssertTrue(reminder.hasRecurrenceRules, "precondition")

        line(completed: true, due: day(6)).applyToReminder(reminder)
        XCTAssertTrue(reminder.isCompleted)
        XCTAssertFalse(reminder.hasRecurrenceRules)
    }

    // MARK: Whole syncs against a destination that behaves like Reminders

    /// The reported shape: an old completed line tied to the live recurring reminder.
    func test_staleCompletedLineLeavesTheLiveReminderAlone() async {
        let destination = EventKitLikeDestination()
        let live = destination.seed(title: "Pay rent", completed: false, due: day(12), rule: "every month")
        let copy = destination.seed(title: "Pay rent", completed: true, due: day(6), rule: nil)
        let (engine, state, config, vault) = makeEngine(vault: [line(completed: true, due: day(6))], destination: destination, mappedTo: live)
        defer { vault.cleanup() }

        for round in 1...4 {
            _ = await engine.performSync(config: config)
            XCTAssertEqual(destination.count, 2, "Sync \(round): no copy may be spawned")
            XCTAssertEqual(destination.openCount, 1, "Sync \(round): no second live reminder")
            XCTAssertEqual(destination.due(live), day(12), "Sync \(round): the live reminder must not be advanced")
        }
        XCTAssertEqual(state.findMapping(obsidianId: "fixed-Pay rent")?.remindersId, copy,
                       "The line ends up tied to the completed copy, which is what it is")
        XCTAssertEqual(destination.rollovers, 0)
    }

    /// After a state reset every task is re-matched by title — the first sync on a
    /// new Mac. That match must not hand a completed line the live occurrence, nor
    /// turn a completed copy into a second live reminder.
    func test_reconnectAfterAStateResetCreatesNothingAndAdvancesNothing() async {
        let destination = EventKitLikeDestination()
        let live = destination.seed(title: "Pay rent", completed: false, due: day(12), rule: "every month")
        // Completed copies, with and without a leftover rule — both must stay history.
        let copies = (1...3).map { destination.seed(title: "Pay rent", completed: true, due: day($0), rule: $0 == 2 ? "every month" : nil) }
        let (engine, state, config, vault) = makeEngine(vault: [line(completed: true, due: day(6))], destination: destination)
        defer { vault.cleanup() }

        for round in 1...4 {
            _ = await engine.performSync(config: config)
            XCTAssertEqual(destination.count, 4, "Sync \(round)")
            XCTAssertEqual(destination.openCount, 1, "Sync \(round)")
            XCTAssertEqual(destination.due(live), day(12), "Sync \(round)")
        }
        XCTAssertTrue(copies.contains(state.findMapping(obsidianId: "fixed-Pay rent")?.remindersId ?? ""))
        XCTAssertEqual(destination.rollovers, 0)
    }

    /// With no completed copy to land on, the line gets its own completed reminder
    /// once — plain, not recurring — and still leaves the live one alone.
    func test_withNoCompletedCopyTheLineGetsOnePlainCompletedReminder() async {
        let destination = EventKitLikeDestination()
        let live = destination.seed(title: "Pay rent", completed: false, due: day(12), rule: "every month")
        let (engine, _, config, vault) = makeEngine(vault: [line(completed: true, due: day(6))], destination: destination)
        defer { vault.cleanup() }

        for _ in 1...4 { _ = await engine.performSync(config: config) }

        XCTAssertEqual(destination.count, 2, "One reminder for the history line, created once")
        XCTAssertEqual(destination.openCount, 1)
        XCTAssertEqual(destination.due(live), day(12))
        XCTAssertEqual(destination.rollovers, 0)
    }

    /// The guard must not swallow the real thing: finishing *this* occurrence in the
    /// vault completes it in Reminders — exactly once.
    func test_completingTheCurrentOccurrenceAdvancesTheReminderExactlyOnce() async {
        let destination = EventKitLikeDestination()
        let live = destination.seed(title: "Pay rent", completed: false, due: day(11), rule: "every month")
        let (engine, _, config, vault) = makeEngine(vault: [line(completed: true, due: day(11))], destination: destination, mappedTo: live)
        defer { vault.cleanup() }

        for _ in 1...4 { _ = await engine.performSync(config: config) }

        XCTAssertEqual(destination.rollovers, 1, "Completed once, not once per sync")
        XCTAssertEqual(destination.due(live), day(12), "Rolled forward one period")
        XCTAssertEqual(destination.count, 2, "The live next occurrence plus one completed copy")
        XCTAssertEqual(destination.openCount, 1)
    }

    func test_ordinaryRemindersAreStillCompletedFromTheVault() async {
        let destination = EventKitLikeDestination()
        let plain = destination.seed(title: "Pay rent", completed: false, due: day(6), rule: nil)
        let (engine, _, config, vault) = makeEngine(vault: [line(completed: true, due: day(6), rule: nil)], destination: destination, mappedTo: plain)
        defer { vault.cleanup() }

        _ = await engine.performSync(config: config)
        XCTAssertEqual(destination.openCount, 0)
        XCTAssertEqual(destination.count, 1)
    }

    // MARK: Candidate choice

    private func reminder(completed: Bool, list: String = "Reminders", recurring: Bool = false) -> SyncTask {
        SyncTask(title: "Pay rent", isCompleted: completed, dueDate: day(12), targetList: list,
                 recurrenceRule: recurring ? "every month" : nil)
    }

    func test_anOpenTaskPrefersAnOpenReminderOverACompletedCopy() {
        XCTAssertEqual(SyncEngine.reconnectCandidateIndex(
            for: line(completed: false, due: day(12)), targetList: "Reminders",
            candidates: [reminder(completed: true), reminder(completed: false)]), 1)
    }

    func test_completionStateOutranksTheList_tiesGoToTheFirst_andTheLiveOccurrenceIsOffLimits() {
        let task = line(completed: true, due: day(6))
        XCTAssertEqual(SyncEngine.reconnectCandidateIndex(
            for: task, targetList: "Reminders",
            candidates: [reminder(completed: false), reminder(completed: true, list: "Other")]), 1)
        XCTAssertEqual(SyncEngine.reconnectCandidateIndex(
            for: task, targetList: "Other",
            candidates: [reminder(completed: true, list: "Other"), reminder(completed: true, list: "Other")]), 0)
        XCTAssertNil(SyncEngine.reconnectCandidateIndex(
            for: task, targetList: "Reminders", candidates: [reminder(completed: false, recurring: true)]))
    }
}

// MARK: - Fixtures

private final class TempVaultPL {
    let url: URL
    var path: String { url.path }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-phantom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private final class FixedSource: TaskSource {
    let sourceName = "FixedSource"
    var scanned: [SyncTask]
    init(scanned: [SyncTask]) { self.scanned = scanned }
    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { scanned }
    func generateTaskId(for task: SyncTask) -> String { "fixed-\(task.title)" }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        SyncTask.ObsidianSource(filePath: "/Inbox.md", lineNumber: 1, originalLine: "- [ ] \(task.title)")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

/// Stores what it is given the way Apple Reminders does with "Include due time"
/// off: the time-of-day is dropped, so what comes back is not what went in.
private final class LossyDestination: TaskDestination {
    let destinationName = "LossyDestination"
    var progressCallback: ((String) -> Void)?
    private var stored: [String: SyncTask] = [:]
    private(set) var updateCount = 0

    private func lossy(_ task: SyncTask, id: String, list: String) -> SyncTask {
        var t = task
        t.remindersId = id
        t.targetList = list
        t.obsidianSource = nil
        if let due = t.dueDate { t.dueDate = Calendar.current.startOfDay(for: due) }
        // A real reminder carries the obsidian:// link once synced; without it the
        // engine would (rightly) keep trying to backfill it.
        t.url = URL(string: "obsidian://open?vault=v&file=f")
        return t
    }

    func userEdits(_ edit: (inout SyncTask) -> Void) {
        for id in stored.keys { edit(&stored[id]!) }
    }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { Array(stored.values) }
    func getAvailableLists() async -> [String] { ["Reminders"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let id = "rem-\(stored.count + 1)"
        stored[id] = lossy(task, id: id, list: listName)
        return id
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        updateCount += 1
        stored[id] = lossy(task, id: id, list: stored[id]?.targetList ?? "Reminders")
    }
    func moveTask(withId id: String, toList listName: String) async throws { stored[id]?.targetList = listName }
    func deleteTask(withId id: String) async throws { stored[id] = nil }
    func refresh() {}
    func currentTask(withId id: String) async -> SyncTask? { stored[id] }
}

/// A destination built on real (in-memory) `EKReminder`s, written through the
/// app's own `applyToReminder`, with the one Reminders behaviour that matters
/// here reproduced on save: a recurring reminder is never left completed — it
/// rolls forward and a completed copy stays behind.
private final class EventKitLikeDestination: TaskDestination {
    let destinationName = "EventKitLikeDestination"
    var progressCallback: ((String) -> Void)?
    private let store = EKEventStore()
    private var items: [String: EKReminder] = [:]
    private var lists: [String: String] = [:]
    private var nextId = 1
    private(set) var rollovers = 0

    private func add(_ reminder: EKReminder, list: String) -> String {
        let id = "rem-\(nextId)"; nextId += 1
        items[id] = reminder; lists[id] = list
        return id
    }

    /// Put a reminder straight into the "database", bypassing the app.
    @discardableResult
    func seed(title: String, completed: Bool, due: Date, rule: String?) -> String {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
        if let rule, let parsed = RecurrenceConverter.parse(ruleText: rule) { r.recurrenceRules = [parsed] }
        r.isCompleted = completed
        return add(r, list: "Reminders")
    }

    /// What Reminders does when a completed recurring reminder is saved.
    private func save(_ id: String) {
        guard let r = items[id], r.isCompleted, r.hasRecurrenceRules,
              let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps),
              let next = Calendar.current.date(byAdding: .month, value: 1, to: due) else { return }
        rollovers += 1
        let copy = EKReminder(eventStore: store)
        copy.title = r.title
        copy.dueDateComponents = comps
        copy.isCompleted = true
        _ = add(copy, list: lists[id] ?? "Reminders")
        r.isCompleted = false
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: next)
    }

    var count: Int { items.count }
    var openCount: Int { items.values.filter { !$0.isCompleted }.count }
    func due(_ id: String) -> Date? { items[id]?.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }

    private func task(_ id: String) -> SyncTask? {
        guard let r = items[id] else { return nil }
        var t = SyncTask.fromReminder(r, listName: lists[id] ?? "Reminders")
        t.remindersId = id
        return t
    }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { items.keys.compactMap { task($0) } }
    func getAvailableLists() async -> [String] { ["Reminders"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let r = EKReminder(eventStore: store)
        task.applyToReminder(r, addTaskLink: config.addTaskLinkToReminders, vaultPath: config.vaultPath)
        let id = add(r, list: listName)
        save(id)
        return id
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        guard let r = items[id] else { return }
        task.applyToReminder(r, addTaskLink: config.addTaskLinkToReminders, vaultPath: config.vaultPath)
        save(id)
    }
    func moveTask(withId id: String, toList listName: String) async throws { lists[id] = listName }
    func deleteTask(withId id: String) async throws { items[id] = nil; lists[id] = nil }
    func refresh() {}
    func currentTask(withId id: String) async -> SyncTask? { task(id) }
}
