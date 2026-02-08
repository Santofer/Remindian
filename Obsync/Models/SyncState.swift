import Foundation

/// Tracks the relationship between Obsidian tasks and Apple Reminders.
/// Used to detect changes and handle conflicts.
class SyncState: Codable {
    var mappings: [TaskMapping]
    var lastSyncDate: Date?
    var stateVersion: Int

    /// Current version of the ID generation scheme.
    /// Bump this when the ID format changes to trigger auto-reset.
    /// v2: content-hash IDs. v3: clean titles + client from frontmatter.
    /// v4: client from YAML frontmatter. v5: tags in notes + auto list mapping.
    /// v6: fixed recurrence start date from "on the Nth" rules.
    static let currentStateVersion = 6

    struct TaskMapping: Codable, Identifiable {
        var id: String { obsidianId }
        let obsidianId: String
        let remindersId: String
        var lastObsidianHash: String
        var lastRemindersHash: String
        var lastSyncDate: Date

        func hasObsidianChanged(currentHash: String) -> Bool {
            return currentHash != lastObsidianHash
        }

        func hasRemindersChanged(currentHash: String) -> Bool {
            return currentHash != lastRemindersHash
        }
    }

    init() {
        self.mappings = []
        self.lastSyncDate = nil
        self.stateVersion = Self.currentStateVersion
    }

    // MARK: - Persistence

    private static var stateURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("Obsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("sync_state.json")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.stateURL)
        } catch {
            print("Failed to save sync state: \(error)")
        }
    }

    static func load() -> SyncState {
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(SyncState.self, from: data)

            // Auto-reset if state version changed (ID scheme migration)
            if state.stateVersion < currentStateVersion {
                print("Sync state version outdated (v\(state.stateVersion) → v\(currentStateVersion)). Resetting sync state for re-sync.")
                let fresh = SyncState()
                fresh.save()
                return fresh
            }

            return state
        } catch {
            return SyncState()
        }
    }

    // MARK: - Mapping Management

    func findMapping(obsidianId: String) -> TaskMapping? {
        return mappings.first { $0.obsidianId == obsidianId }
    }

    func findMapping(remindersId: String) -> TaskMapping? {
        return mappings.first { $0.remindersId == remindersId }
    }

    func addOrUpdateMapping(obsidianId: String, remindersId: String, obsidianHash: String, remindersHash: String) {
        if let index = mappings.firstIndex(where: { $0.obsidianId == obsidianId }) {
            mappings[index] = TaskMapping(
                obsidianId: obsidianId,
                remindersId: remindersId,
                lastObsidianHash: obsidianHash,
                lastRemindersHash: remindersHash,
                lastSyncDate: Date()
            )
        } else {
            mappings.append(TaskMapping(
                obsidianId: obsidianId,
                remindersId: remindersId,
                lastObsidianHash: obsidianHash,
                lastRemindersHash: remindersHash,
                lastSyncDate: Date()
            ))
        }
    }

    func removeMapping(obsidianId: String) {
        mappings.removeAll { $0.obsidianId == obsidianId }
    }

    func removeMapping(remindersId: String) {
        mappings.removeAll { $0.remindersId == remindersId }
    }

    // MARK: - Hash Generation

    /// Generate a stable ID from task content rather than line position.
    /// Uses filePath + title + key metadata so the ID survives task reordering.
    static func generateObsidianId(task: SyncTask) -> String {
        guard let source = task.obsidianSource else {
            // Fallback: use title-based ID
            let components = [task.title, task.targetList ?? ""]
            return components.joined(separator: "|").data(using: .utf8)!.base64EncodedString()
        }
        let components = [
            source.filePath,
            task.title,
            task.dueDate?.ISO8601Format() ?? "",
            task.startDate?.ISO8601Format() ?? "",
            task.scheduledDate?.ISO8601Format() ?? "",
            task.tags.sorted().joined(separator: ","),
            String(task.priority.rawValue)
        ]
        return components.joined(separator: "|").data(using: .utf8)!.base64EncodedString()
    }

    /// Generate a hash of all task fields to detect any changes.
    static func generateTaskHash(_ task: SyncTask) -> String {
        let components = [
            task.title,
            String(task.isCompleted),
            String(task.priority.rawValue),
            task.dueDate?.ISO8601Format() ?? "",
            task.startDate?.ISO8601Format() ?? "",
            task.scheduledDate?.ISO8601Format() ?? "",
            task.completedDate?.ISO8601Format() ?? "",
            task.targetList ?? "",
            task.tags.sorted().joined(separator: ",")
        ]
        return components.joined(separator: "|").data(using: .utf8)!.base64EncodedString()
    }
}
