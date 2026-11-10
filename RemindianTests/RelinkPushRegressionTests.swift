import XCTest
@testable import Remindian

/// Regression tests for re-linked mappings never pushing the source's change.
///
/// **Bug.** A task's sync ID includes its title and tags. When either changes
/// in the source, the old mapping is re-linked to the new ID by title. The
/// re-link stored the new task's own hash, which recorded the change as
/// already pushed, so the reminder kept its old title or tags until some
/// unrelated edit. Turning on "strip global filter from titles" (#89) hits
/// this for every affected task: its help text promises existing reminders
/// are renamed on the next sync, but they never were.
///
/// **Fix.** When the re-linked task's title or tags differ from the reminder,
/// store an empty source hash so the next sync pushes the source state.
final class RelinkPushRegressionTests: XCTestCase {

    private func makeConfig(_ vault: RelinkTempVault) -> SyncConfiguration {
        let cfg = SyncConfiguration()
        cfg.vaultPath = vault.path
        cfg.addTaskLinkToReminders = false
        return cfg
    }

    /// #89: the reminder is "Salads 📅"; with the filter stripped the source
    /// title is now "Salads". The reminder must be renamed.
    func test_stripFilterSettingRenamesExistingReminder() async throws {
        let vault = try RelinkTempVault()
        defer { vault.cleanup() }

        let sourceTask = SyncTask(
            title: "Salads", tags: ["#Groceries"], targetList: "Groceries",
            obsidianSource: .init(filePath: "/Inbox.md", lineNumber: 3, originalLine: "- [ ] Salads 📅 #Groceries")
        )
        let reminder = SyncTask(title: "Salads 📅", tags: ["#Groceries"], targetList: "Groceries", remindersId: "r-salads")

        let source = RelinkMockSource(tasks: [sourceTask])
        let destination = RelinkMockDestination(tasks: [reminder])
        let state = SyncState()
        // Mapping made before the setting was on, under the old title.
        var old = sourceTask
        old.title = "Salads 📅"
        state.addOrUpdateMapping(
            obsidianId: source.generateTaskId(for: old), remindersId: "r-salads",
            obsidianHash: SyncState.generateTaskHash(old), remindersHash: SyncState.generateTaskHash(reminder)
        )

        let cfg = makeConfig(vault)
        cfg.globalFilter = "📅"
        cfg.stripGlobalFilterFromTitle = true
        let engine = SyncEngine(source: source, destination: destination, syncState: state)

        _ = await engine.performSync(config: cfg)   // re-links the mapping
        _ = await engine.performSync(config: cfg)   // pushes the new title

        XCTAssertEqual(destination.updatedTitles.last, "Salads",
                       "The reminder must be renamed. updates=\(destination.updatedTitles)")
        XCTAssertEqual(destination.deletedIds, [], "Renamed in place, never deleted")
        XCTAssertEqual(destination.createdTitles, [], "Renamed in place, never recreated")

        // Settles: a further sync pushes nothing.
        let before = destination.updatedTitles.count
        destination.tasks = [SyncTask(title: "Salads", tags: ["#Groceries"], targetList: "Groceries", remindersId: "r-salads")]
        _ = await engine.performSync(config: cfg)
        XCTAssertEqual(destination.updatedTitles.count, before, "No re-push once renamed")
    }

    /// Adding a tag in the vault changes the ID; the reminder must get the tag.
    func test_tagAddedInSourceReachesTheReminder() async throws {
        let vault = try RelinkTempVault()
        defer { vault.cleanup() }

        let sourceTask = SyncTask(
            title: "Pay rent", tags: ["#home", "#urgent"], targetList: "home",
            obsidianSource: .init(filePath: "/Home.md", lineNumber: 1, originalLine: "- [ ] Pay rent #home #urgent")
        )
        let reminder = SyncTask(title: "Pay rent", tags: ["#home"], targetList: "Home", remindersId: "r-rent")

        let source = RelinkMockSource(tasks: [sourceTask])
        let destination = RelinkMockDestination(tasks: [reminder])
        let state = SyncState()
        var old = sourceTask
        old.tags = ["#home"]
        state.addOrUpdateMapping(
            obsidianId: source.generateTaskId(for: old), remindersId: "r-rent",
            obsidianHash: SyncState.generateTaskHash(old), remindersHash: SyncState.generateTaskHash(reminder)
        )

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        let cfg = makeConfig(vault)
        _ = await engine.performSync(config: cfg)
        _ = await engine.performSync(config: cfg)

        XCTAssertEqual(destination.updatedTags.last.map { Set($0) }, ["#home", "#urgent"],
                       "The new tag must be pushed. updates=\(destination.updatedTags)")
        XCTAssertEqual(destination.deletedIds, [])
        XCTAssertEqual(destination.createdTitles, [])
    }

    /// Control: a re-link where nothing visible differs must not push.
    func test_relinkWithNothingToPushStaysQuiet() async throws {
        let vault = try RelinkTempVault()
        defer { vault.cleanup() }

        let sourceTask = SyncTask(
            title: "Water plants", tags: ["#home"], targetList: "home",
            obsidianSource: .init(filePath: "/Home.md", lineNumber: 1, originalLine: "- [ ] Water plants #home")
        )
        let reminder = SyncTask(title: "Water plants", tags: ["#home"], targetList: "Home", remindersId: "r-plants")
        let source = RelinkMockSource(tasks: [sourceTask])
        let destination = RelinkMockDestination(tasks: [reminder])
        let state = SyncState()
        // A stale mapping ID (e.g. an older ID format), same title and tags.
        state.addOrUpdateMapping(
            obsidianId: "legacy-id", remindersId: "r-plants",
            obsidianHash: SyncState.generateTaskHash(sourceTask), remindersHash: SyncState.generateTaskHash(reminder)
        )

        let engine = SyncEngine(source: source, destination: destination, syncState: state)
        let cfg = makeConfig(vault)
        _ = await engine.performSync(config: cfg)
        let afterRelink = destination.updatedTitles.count
        _ = await engine.performSync(config: cfg)

        XCTAssertEqual(destination.updatedTitles.count, afterRelink, "Nothing differs, so the re-link must not cause a push")
        XCTAssertEqual(destination.deletedIds, [])
    }
}

// MARK: - Fixtures

private final class RelinkTempVault {
    let url: URL
    var path: String { url.path }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-relink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// IDs include title and tags, like the real source.
private final class RelinkMockSource: TaskSource {
    let sourceName = "RelinkMockSource"
    var tasks: [SyncTask]
    init(tasks: [SyncTask]) { self.tasks = tasks }

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] { tasks }
    func generateTaskId(for task: SyncTask) -> String { "\(task.title)|\(task.tags.sorted().joined(separator: ","))" }
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int { 0 }
    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {}
    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {}
    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        XCTFail("appendNewTask must not be called: the reminder is mapped")
        return SyncTask.ObsidianSource(filePath: "Inbox.md", lineNumber: 1, originalLine: "")
    }
    func hasFileChanged(task: SyncTask, since: Date, config: SyncConfiguration) -> Bool { false }
}

private final class RelinkMockDestination: TaskDestination {
    let destinationName = "RelinkMockDestination"
    var tasks: [SyncTask]
    private(set) var updatedTitles: [String] = []
    private(set) var updatedTags: [[String]] = []
    private(set) var createdTitles: [String] = []
    private(set) var deletedIds: [String] = []
    init(tasks: [SyncTask]) { self.tasks = tasks }

    func requestAccess() async throws -> Bool { true }
    func fetchAllTasks() async throws -> [SyncTask] { tasks }
    func getAvailableLists() async -> [String] { ["Groceries", "Home"] }
    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        createdTitles.append(task.title); return "new-\(task.title)"
    }
    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        updatedTitles.append(task.title); updatedTags.append(task.tags)
    }
    func moveTask(withId id: String, toList listName: String) async throws {}
    func deleteTask(withId id: String) async throws { deletedIds.append(id) }
    func refresh() {}
}
