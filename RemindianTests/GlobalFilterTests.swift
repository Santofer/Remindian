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
