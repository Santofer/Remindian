import AppIntents

/// macOS Shortcuts / Spotlight actions for Remindian. (Shortcuts + quick-add)
///
/// These expose Remindian to the Shortcuts app, Spotlight, and automations so
/// users can "Sync now" or capture a task from anywhere without opening the app.
/// AppIntents is a macOS 13+ framework, which matches the app's deployment floor.

struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Now"
    static var description = IntentDescription("Run a Remindian sync of all enabled profiles.")
    /// Surface the app while syncing isn't necessary — run quietly in the background.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SyncManager.shared.performSync()
        let summary = SyncManager.shared.lastSyncResult?.summary ?? "Done"
        return .result(dialog: "Remindian sync complete — \(summary)")
    }
}

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task to Obsidian"
    static var description = IntentDescription("Capture a task into your Obsidian inbox. Understands natural-language dates (\"friday\", \"tomorrow 3pm\"), priority (!, !!, !!!) and #tags.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task", description: "e.g. \"Pay rent friday !! #home\"")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = await SyncManager.shared.quickAddTask(text)
        return .result(dialog: added
            ? "Added “\(text)” to your Obsidian inbox."
            : "Couldn't add the task — open Remindian to check your vault setup.")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Obsidian")
    }
}

struct RemindianShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync \(.applicationName)", "Run a \(.applicationName) sync"],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: ["Add a task to \(.applicationName)", "Add a \(.applicationName) task"],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
    }
}
