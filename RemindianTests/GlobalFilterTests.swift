import XCTest
@testable import Remindian

/// #88 / #89 — the global filter decides *which* tasks sync. It must not decide
/// *where* they go, and it shouldn't have to appear in the synced title.
final class GlobalFilterTests: XCTestCase {

    private func config(filter: String) -> SyncConfiguration {
        let c = SyncConfiguration()
        c.globalFilter = filter
        c.defaultList = "Reminders"
        return c
    }

    // MARK: - #88: the filter tag must not drive list routing

    func test_88_filterTagDoesNotInventAList() {
        // `#task` is the filter, so every synced task carries it. Auto-capitalising
        // it produced a "Task" list nobody asked for — and silently skipped tasks
        // when a synced-lists whitelist was configured.
        let c = config(filter: "#task")
        let list = c.resolveTargetList(tag: "task", filePath: "/Projects/plan.md", tags: ["#task"])
        XCTAssertNotEqual(list, "Task", "The filter tag must never become a list name")
        XCTAssertEqual(list, "Reminders", "With no other signal it falls back to the default list")
    }

    func test_88_pathMappingWinsOverFilterTag() {
        // The reporter's exact setup: filter `#task`, folder mapping Projects/ → Projects.
        let c = config(filter: "#task")
        c.folderPathMappings = [SyncConfiguration.FolderMapping(folderPath: "Projects", remindersList: "Projects")]
        let list = c.resolveTargetList(tag: "task", filePath: "/Projects/plan.md", tags: ["#task"])
        XCTAssertEqual(list, "Projects", "Path mapping must win — the filter tag isn't a category (#88)")
    }

    func test_88_explicitTagMappingStillWorksForRealTags() {
        // A genuine routing tag must keep working alongside the filter.
        let c = config(filter: "#task")
        c.listMappings = [SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work")]
        let list = c.resolveTargetList(tag: "task", filePath: "/Notes/a.md", tags: ["#task", "#work"])
        XCTAssertEqual(list, "Work", "Non-filter tags must still route normally")
    }

    func test_88_subTagOfFilterStillRoutes() {
        // Only the bare filter tag is ignored — `#task/work` is more specific and
        // remains a legitimate routing tag.
        let c = config(filter: "#task")
        c.listMappings = [SyncConfiguration.ListMapping(obsidianTag: "task/work", remindersList: "Work")]
        let list = c.resolveTargetList(tag: "task", filePath: "/Notes/a.md", tags: ["#task/work"])
        XCTAssertEqual(list, "Work", "A more specific sub-tag must still match")
    }

    func test_88_nonTagFilterLeavesRoutingUntouched() {
        // A plain-text filter like TODO never appears in tags, so routing is normal.
        let c = config(filter: "TODO")
        c.listMappings = [SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work")]
        XCTAssertEqual(c.resolveTargetList(tag: "work", filePath: nil, tags: ["#work"]), "Work")
    }

    func test_88_noFilterConfiguredKeepsLegacyAutoCapitalise() {
        // Without a global filter, the historical behaviour is unchanged.
        let c = config(filter: "")
        XCTAssertEqual(c.resolveTargetList(tag: "work", filePath: nil, tags: ["#work"]), "Work")
    }

    // MARK: - #89: keeping the filter out of synced titles

    func test_89_stripsFilterFromTitle() {
        let c = config(filter: "TODO")
        c.stripGlobalFilterFromTitle = true
        XCTAssertEqual(c.titleForDestination("Review the deployment plan TODO"),
                       "Review the deployment plan")
    }

    func test_89_offByDefaultLeavesTitleAlone() {
        let c = config(filter: "TODO")
        XCTAssertFalse(c.stripGlobalFilterFromTitle, "Must default off — existing titles shouldn't change silently")
        XCTAssertEqual(c.titleForDestination("Review the deployment plan TODO"),
                       "Review the deployment plan TODO")
    }

    func test_89_tidiesWhitespaceLeftBehind() {
        let c = config(filter: "TODO")
        c.stripGlobalFilterFromTitle = true
        XCTAssertEqual(c.titleForDestination("Review TODO the plan"), "Review the plan")
        XCTAssertEqual(c.titleForDestination("TODO Review the plan"), "Review the plan")
    }

    func test_89_titleWithoutFilterIsUnchanged() {
        let c = config(filter: "TODO")
        c.stripGlobalFilterFromTitle = true
        XCTAssertEqual(c.titleForDestination("Buy milk"), "Buy milk")
    }

    /// The sync identity includes the title, so enabling the option changes every
    /// affected task's id. The re-link gate compares filter-stripped titles so the
    /// mappings migrate instead of the reminders being deleted and recreated.
    func test_89_relinkComparisonIgnoresTheFilter() {
        let existingReminderTitle = "Review the deployment plan TODO"   // synced before the option
        let newObsidianTitle = "Review the deployment plan"             // after enabling it
        XCTAssertEqual(
            SyncConfiguration.removingGlobalFilter(existingReminderTitle, filter: "TODO"),
            SyncConfiguration.removingGlobalFilter(newObsidianTitle, filter: "TODO"),
            "Titles differing only by the filter must still be recognised as the same task"
        )
    }

    func test_89_emptyFilterIsANoOp() {
        XCTAssertEqual(SyncConfiguration.removingGlobalFilter("Buy milk", filter: ""), "Buy milk")
        XCTAssertEqual(SyncConfiguration.removingGlobalFilter("Buy milk", filter: "   "), "Buy milk")
    }

    // MARK: - Routing explainer: the reason must match the actual decision

    func test_explain_reportsTheWinningRule() {
        let c = config(filter: "#task")
        c.folderPathMappings = [SyncConfiguration.FolderMapping(folderPath: "Projects", remindersList: "Projects")]
        let explained = c.explainTargetList(tag: "task", filePath: "/Projects/plan.md", tags: ["#task"])
        XCTAssertEqual(explained.list, "Projects")
        XCTAssertTrue(explained.reason.contains("folder mapping"), "Reason should name the rule. Got: \(explained.reason)")
        XCTAssertTrue(explained.reason.contains("Projects"))
    }

    func test_explain_namesTagMappingWhenItWins() {
        let c = config(filter: "")
        c.listMappings = [SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work")]
        let explained = c.explainTargetList(tag: "work", filePath: nil, tags: ["#work"])
        XCTAssertEqual(explained.list, "Work")
        XCTAssertTrue(explained.reason.contains("tag mapping"), "Got: \(explained.reason)")
    }

    func test_explain_callsOutTheIgnoredFilterTag() {
        // The #88 confusion, made visible: the user sees *why* the tag didn't route.
        let c = config(filter: "#task")
        let explained = c.explainTargetList(tag: "task", filePath: nil, tags: ["#task"])
        XCTAssertEqual(explained.list, "Reminders")
        XCTAssertTrue(explained.reason.lowercased().contains("global filter"),
                      "Must explain that the filter tag isn't used for routing. Got: \(explained.reason)")
    }

    /// The explanation must never drift from the decision — same code path.
    func test_explain_agreesWithResolveTargetList() {
        let c = config(filter: "#task")
        c.listMappings = [SyncConfiguration.ListMapping(obsidianTag: "work", remindersList: "Work")]
        c.folderPathMappings = [SyncConfiguration.FolderMapping(folderPath: "Projects", remindersList: "Projects")]
        let cases: [(String?, String?, [String])] = [
            ("task", "/Projects/a.md", ["#task"]),
            ("work", "/Projects/a.md", ["#task", "#work"]),
            (nil, "/Elsewhere/b.md", []),
            ("solo", nil, ["#solo"]),
        ]
        for (tag, path, tags) in cases {
            XCTAssertEqual(
                c.explainTargetList(tag: tag, filePath: path, tags: tags).list,
                c.resolveTargetList(tag: tag, filePath: path, tags: tags),
                "Explainer and resolver disagreed for tag=\(tag ?? "nil") path=\(path ?? "nil")"
            )
        }
    }

    // MARK: - Round-trip: a new task must stay eligible on the next scan

    /// Without the filter on the appended line, the task we just wrote fails the
    /// eligibility check on the next scan, looks deleted, and the engine removes
    /// the reminder that created it.
    func test_newTaskWrittenToInboxKeepsTheGlobalFilter() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let result = try ObsidianService().appendTaskToInbox(
            task: SyncTask(title: "Buy milk"),
            inboxRelativePath: "Inbox.md",
            vaultPath: vault.path,
            globalFilter: "#task"
        )
        XCTAssertTrue(result.lineContent.contains("#task"),
                      "The appended line must carry the filter or it vanishes on the next sync. Got: \(result.lineContent)")

        let onDisk = try String(contentsOf: vault.appendingPathComponent("Inbox.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("#task"))
    }

    // MARK: - Inbox lines carry the filter once

    /// Writes `task` to a fresh inbox with `filter` and returns the line.
    private func appendedLine(_ task: SyncTask, filter: String) throws -> String {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        return try ObsidianService().appendTaskToInbox(
            task: task,
            inboxRelativePath: "Inbox.md",
            vaultPath: vault.path,
            globalFilter: filter
        ).lineContent
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    /// With `📅` as the filter, a dated task's `📅 2026-01-15` already satisfies
    /// it. The extra bare `📅` used to end up in the parsed title, so the
    /// reminder was renamed "Buy milk 📅" on the next sync.
    func test_datedTaskWithDateEmojiFilterGetsNoExtraMarker() throws {
        let line = try appendedLine(
            SyncTask(title: "Buy milk", dueDate: date("2026-01-15"), targetList: "Errands"),
            filter: "📅"
        )
        XCTAssertEqual(line, "- [ ] Buy milk 📅 2026-01-15 #Errands")

        let reparsed = SyncTask.fromObsidianLine(line, filePath: "/Inbox.md", lineNumber: 1)
        XCTAssertEqual(reparsed?.title, "Buy milk", "The filter must not leak into the title")
        XCTAssertTrue(line.contains("📅"), "Still eligible on the next scan")
    }

    func test_startDatedTaskWithDateEmojiFilterGetsNoExtraMarker() throws {
        let line = try appendedLine(
            SyncTask(title: "Go to Bevmo", dueDate: date("2026-11-10"), startDate: date("2026-11-10")),
            filter: "📅"
        )
        XCTAssertEqual(line, "- [ ] Go to Bevmo 🛫 2026-11-10 📅 2026-11-10")
    }

    /// Undated: the marker is still needed, or the task drops out of the scan
    /// and its reminder is deleted.
    func test_undatedTaskStillGetsTheMarker() throws {
        let line = try appendedLine(SyncTask(title: "Salads", targetList: "Groceries"), filter: "📅")
        XCTAssertEqual(line, "- [ ] Salads 📅 #Groceries")
    }

    /// A tag filter the task's own list tag already matches isn't repeated.
    func test_tagFilterAlreadyPresentAsListTagIsNotRepeated() throws {
        let line = try appendedLine(SyncTask(title: "Buy milk", targetList: "task"), filter: "#task")
        XCTAssertEqual(line, "- [ ] Buy milk #task")
    }

    /// `RecurrenceConverter.format` returns "🔁 every week"; the line used to
    /// read "🔁 🔁 every week".
    func test_recurrenceFromRemindersIsNotDoubled() throws {
        let line = try appendedLine(
            SyncTask(title: "Clear out podcasts", dueDate: date("2026-11-16"), recurrenceRule: "🔁 every week"),
            filter: ""
        )
        XCTAssertEqual(line, "- [ ] Clear out podcasts 🔁 every week 📅 2026-11-16")
        let reparsed = SyncTask.fromObsidianLine(line, filePath: "/Inbox.md", lineNumber: 1)
        XCTAssertEqual(reparsed?.title, "Clear out podcasts")
        XCTAssertNotNil(reparsed?.recurrenceRule)
    }

    func test_recurrenceWithoutEmojiStillGetsOne() throws {
        let line = try appendedLine(
            SyncTask(title: "Pay rent", dueDate: date("2026-12-01"), recurrenceRule: "every month"),
            filter: ""
        )
        XCTAssertEqual(line, "- [ ] Pay rent 🔁 every month 📅 2026-12-01")
    }

    func test_newTaskWithoutFilterConfiguredIsUnchanged() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let result = try ObsidianService().appendTaskToInbox(
            task: SyncTask(title: "Buy milk"),
            inboxRelativePath: "Inbox.md",
            vaultPath: vault.path
        )
        XCTAssertEqual(result.lineContent.trimmingCharacters(in: .whitespaces), "- [ ] Buy milk")
    }
}
