import Foundation

/// Tracks the relationship between Obsidian tasks and Apple Reminders.
/// Used to detect changes and handle conflicts.
class SyncState: Codable {
    /// On-disk source of truth. Preserved verbatim in `sync_state.json` so
    /// existing state files keep loading unchanged. Direct array access
    /// (iteration, `.count`, `.map`) by the sync engine still works.
    var mappings: [TaskMapping]
    var lastSyncDate: Date?
    var stateVersion: Int

    // MARK: - In-memory acceleration indexes (not persisted)
    //
    // The sync engine looks up mappings by id inside per-task loops. With a
    // plain array those lookups were O(n) linear scans → O(n²) overall on big
    // vaults. These dictionaries map id → array index for O(1) find/has.
    // Rebuilt from `mappings` on decode and after structural removals;
    // maintained incrementally on add/update. They are NOT encoded — only
    // `mappings` is. (perf)
    //
    // Invariant: `obsidianId` is unique across mappings (addOrUpdate updates in
    // place rather than appending a duplicate). `remindersId` is intended
    // unique too; if a duplicate ever exists the index points at the
    // most-recently-written mapping (more correct than the old `.first`).
    private var idxByObsidianId: [String: Int] = [:]
    private var idxByRemindersId: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case mappings, lastSyncDate, stateVersion
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try c.decode([TaskMapping].self, forKey: .mappings)
        lastSyncDate = try c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        stateVersion = try c.decodeIfPresent(Int.self, forKey: .stateVersion) ?? Self.currentStateVersion
        rebuildIndexes()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mappings, forKey: .mappings)
        try c.encodeIfPresent(lastSyncDate, forKey: .lastSyncDate)
        try c.encode(stateVersion, forKey: .stateVersion)
    }

    /// Rebuild both id→index maps from `mappings`. O(n). Called on decode and
    /// after removals (which shift array indices).
    private func rebuildIndexes() {
        idxByObsidianId.removeAll(keepingCapacity: true)
        idxByRemindersId.removeAll(keepingCapacity: true)
        idxByObsidianId.reserveCapacity(mappings.count)
        idxByRemindersId.reserveCapacity(mappings.count)
        for (i, m) in mappings.enumerated() {
            idxByObsidianId[m.obsidianId] = i
            idxByRemindersId[m.remindersId] = i
        }
    }

    /// Current version of the ID generation scheme.
    /// Bump this when the ID format changes to trigger auto-reset.
    /// v2: content-hash IDs. v3: clean titles + client from frontmatter.
    /// v4: client from YAML frontmatter. v5: tags in notes + auto list mapping.
    /// v6: fixed recurrence start date from "on the Nth" rules.
    /// v7: stable IDs — removed mutable fields (dates, priority) from obsidianId
    ///     to prevent delete+recreate on metadata changes. Re-linking in sync engine
    ///     handles the migration gracefully.
    /// v8: recurring tasks include lineNumber in obsidianId so the completed copy
    ///     and the new-uncompleted copy that Obsidian Tasks plugin inserts get
    ///     distinct IDs. Fixes #57 scenarios 1 & 2 (duplicates / missed occurrences
    ///     when completing in Obsidian or Reminders). Non-recurring tasks keep
    ///     content-stable IDs (no lineNumber) so reordering still doesn't break
    ///     mappings.
    static let currentStateVersion = 8

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

    /// The state file's name for a given profile. (#multi-profile)
    ///
    /// An empty `profileKey` yields the historical `sync_state.json` — so the
    /// **Default profile keeps using the exact same file existing installs
    /// already have** (zero migration, zero risk). Additional profiles get
    /// `sync_state_<key>.json`. The key is sanitized to filename-safe chars.
    static func stateFileName(profileKey: String) -> String {
        let trimmed = profileKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "sync_state.json" }
        let safe = String(trimmed.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" })
        return "sync_state_\(safe).json"
    }

    /// Application Support location — the default, per-machine store.
    private static func appSupportURL(profileKey: String) -> URL? {
        guard let appFolder = remindianAppSupportDir() else { return nil }
        return appFolder.appendingPathComponent(stateFileName(profileKey: profileKey))
    }

    /// Resolve the on-disk path for a given storage location. (#15, multi-profile)
    ///
    /// For `.vault`, the file lives at `<vault>/.remindian/<stateFileName>` and
    /// the `.remindian` directory is created if needed. A dot-folder keeps it
    /// out of Obsidian's view, and our vault scanner only reads `.md` files in
    /// non-hidden folders, so the state file is never mistaken for a task note.
    /// Returns nil if the vault path is empty (caller falls back to App Support).
    static func stateURL(location: SyncConfiguration.SyncStateLocation, vaultPath: String, profileKey: String = "") -> URL? {
        switch location {
        case .applicationSupport:
            return appSupportURL(profileKey: profileKey)
        case .vault:
            let trimmed = vaultPath.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let dir = URL(fileURLWithPath: trimmed, isDirectory: true)
                .appendingPathComponent(".remindian", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(stateFileName(profileKey: profileKey))
        }
    }

    /// Back-compat convenience — saves to Application Support.
    func save() {
        save(location: .applicationSupport, vaultPath: "")
    }

    func save(location: SyncConfiguration.SyncStateLocation, vaultPath: String, profileKey: String = "") {
        // If a vault location was requested but couldn't be resolved (empty
        // vault path), fall back to App Support rather than silently dropping
        // the write — never lose mappings.
        let url = Self.stateURL(location: location, vaultPath: vaultPath, profileKey: profileKey) ?? Self.appSupportURL(profileKey: profileKey)
        guard let url = url else { return }
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save sync state: \(error)")
        }
    }

    /// Back-compat convenience — loads from Application Support.
    static func load() -> SyncState {
        return load(location: .applicationSupport, vaultPath: "")
    }

    /// Load the sync state from `location`. `seedFromAppSupportIfMissing`
    /// controls the first-use migration (see below); production keeps it on,
    /// tests turn it off for deterministic, App-Support-independent behavior.
    static func load(location: SyncConfiguration.SyncStateLocation, vaultPath: String, seedFromAppSupportIfMissing: Bool = true, profileKey: String = "") -> SyncState {
        guard let url = stateURL(location: location, vaultPath: vaultPath, profileKey: profileKey) else {
            // Couldn't resolve the requested location (e.g. vault path empty) —
            // fall back to App Support so we still reuse existing mappings.
            return loadFile(at: appSupportURL(profileKey: profileKey), persistMigrationTo: .applicationSupport, vaultPath: vaultPath, profileKey: profileKey)
        }

        // Seed-on-first-use: switching to vault storage when the vault has no
        // state file yet should inherit this machine's existing App Support
        // mappings instead of starting empty (which would force a full
        // reconnect-by-title pass). Only when the vault file is genuinely
        // absent — once it exists, it is the shared source of truth. Only the
        // *default* profile (empty key) seeds — additional profiles start fresh
        // so they don't inherit the default's mappings.
        if seedFromAppSupportIfMissing, profileKey.trimmingCharacters(in: .whitespaces).isEmpty,
           location == .vault, !FileManager.default.fileExists(atPath: url.path) {
            let seeded = loadFile(at: appSupportURL(profileKey: profileKey), persistMigrationTo: nil, vaultPath: vaultPath, profileKey: profileKey)
            if !seeded.mappings.isEmpty {
                print("Sync state: seeding vault store from existing Application Support mappings (\(seeded.mappings.count)).")
                seeded.save(location: .vault, vaultPath: vaultPath, profileKey: profileKey)
                return seeded
            }
        }

        return loadFile(at: url, persistMigrationTo: location, vaultPath: vaultPath, profileKey: profileKey)
    }

    /// Decode + migrate a state file at `url`. On a version-bump migration that
    /// keeps mappings, persists the bumped state back to `persistMigrationTo`
    /// (nil = don't persist, used for the read-only seed probe). Any failure
    /// (missing/corrupt file) degrades to a fresh empty state — same as before.
    private static func loadFile(at url: URL?, persistMigrationTo: SyncConfiguration.SyncStateLocation?, vaultPath: String, profileKey: String = "") -> SyncState {
        do {
            guard let url = url else { return SyncState() }
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(SyncState.self, from: data)

            // Handle state version migrations
            if state.stateVersion < currentStateVersion {
                if state.stateVersion == 6 || state.stateVersion == 7 {
                    // v6 → v7: ObsidianId format changed (removed mutable fields).
                    // v7 → v8: Recurring tasks now include lineNumber in their ID.
                    //   Non-recurring tasks keep stable IDs — only recurring ones
                    //   get new IDs, and those are rare. Re-linking in the sync
                    //   engine matches by title, so existing mappings gracefully
                    //   transition without deleting/recreating destination tasks.
                    print("Sync state v\(state.stateVersion) → v\(currentStateVersion): ID format migration. Keeping mappings for re-linking.")
                    state.stateVersion = currentStateVersion
                    if let target = persistMigrationTo {
                        state.save(location: target, vaultPath: vaultPath, profileKey: profileKey)
                    }
                } else {
                    // Older versions: full reset
                    print("Sync state version outdated (v\(state.stateVersion) → v\(currentStateVersion)). Resetting sync state for re-sync.")
                    let fresh = SyncState()
                    if let target = persistMigrationTo {
                        fresh.save(location: target, vaultPath: vaultPath, profileKey: profileKey)
                    }
                    return fresh
                }
            }

            return state
        } catch {
            return SyncState()
        }
    }

    // MARK: - Mapping Management

    func findMapping(obsidianId: String) -> TaskMapping? {
        guard let i = idxByObsidianId[obsidianId] else { return nil }
        return mappings[i]
    }

    func findMapping(remindersId: String) -> TaskMapping? {
        guard let i = idxByRemindersId[remindersId] else { return nil }
        return mappings[i]
    }

    /// O(1) existence check. Replaces `mappings.contains { $0.obsidianId == … }`
    /// in the dedup sort comparator (which was O(n) per comparison). (perf)
    func hasMapping(obsidianId: String) -> Bool {
        return idxByObsidianId[obsidianId] != nil
    }

    func addOrUpdateMapping(obsidianId: String, remindersId: String, obsidianHash: String, remindersHash: String) {
        let newMapping = TaskMapping(
            obsidianId: obsidianId,
            remindersId: remindersId,
            lastObsidianHash: obsidianHash,
            lastRemindersHash: remindersHash,
            lastSyncDate: Date()
        )

        if let i = idxByObsidianId[obsidianId] {
            // Update in place — array index is stable. If the remindersId
            // changed (reconnect), move its index entry to the new id.
            let oldRemindersId = mappings[i].remindersId
            if oldRemindersId != remindersId {
                // Only drop the old entry if it still points at this slot
                // (defensive against a duplicate remindersId elsewhere).
                if idxByRemindersId[oldRemindersId] == i {
                    idxByRemindersId.removeValue(forKey: oldRemindersId)
                }
                idxByRemindersId[remindersId] = i
            }
            mappings[i] = newMapping
        } else {
            mappings.append(newMapping)
            let i = mappings.count - 1
            idxByObsidianId[obsidianId] = i
            idxByRemindersId[remindersId] = i
        }
    }

    func removeMapping(obsidianId: String) {
        guard idxByObsidianId[obsidianId] != nil else { return }
        mappings.removeAll { $0.obsidianId == obsidianId }
        rebuildIndexes() // array indices shifted
    }

    func removeMapping(remindersId: String) {
        guard idxByRemindersId[remindersId] != nil else { return }
        mappings.removeAll { $0.remindersId == remindersId }
        rebuildIndexes()
    }

    // MARK: - Hash Generation

    /// Generate a stable ID from task content.
    ///
    /// - **Non-recurring tasks:** hash of `filePath + title + tags` (no line number).
    ///   Stable across line reordering. NOT including dates/priority/completion
    ///   (mutable fields that change independently and would cause delete+recreate
    ///   instead of in-place update).
    ///
    /// - **Recurring tasks (task.recurrenceRule != nil):** hash also includes the
    ///   `lineNumber`. The Obsidian Tasks plugin inserts a new line for each new
    ///   occurrence (e.g. after completing `- [x] Pay rent 🔁 every month` it adds
    ///   `- [ ] Pay rent 🔁 every month` above it). Without lineNumber in the hash,
    ///   both lines collide on the same obsidianId — the second one overwrites the
    ///   first in the obsidianMap, and sync misbehaves (scenarios 1 & 2 in #57).
    ///   Including lineNumber gives them distinct IDs; the same-file dedup pass
    ///   in SyncEngine then correctly keeps the uncompleted one and drops the
    ///   completed one.
    ///
    /// Reordering a recurring task changes its ID, which orphans the old mapping —
    /// the sync engine's re-linking logic reattaches it by title. This is an
    /// acceptable trade-off: recurring tasks get reordered rarely, and the
    /// alternative (missed occurrences + duplicate creation) is worse.
    static func generateObsidianId(task: SyncTask) -> String {
        guard let source = task.obsidianSource else {
            // Fallback: use title-based ID
            let components = [task.title, task.targetList ?? ""]
            return components.joined(separator: "|").data(using: .utf8)?.base64EncodedString() ?? ""
        }
        var components = [
            source.filePath,
            task.title,
            task.tags.sorted().joined(separator: ",")
        ]
        if task.recurrenceRule != nil {
            // Recurring: disambiguate by line so completed + new uncompleted copies
            // don't collapse to a single map entry. See #57.
            components.append("L\(source.lineNumber)")
        }
        return components.joined(separator: "|").data(using: .utf8)?.base64EncodedString() ?? ""
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
            task.tags.sorted().joined(separator: ","),
            // Include recurrence rule so changes to the rule (e.g. changing
            // "every week" to "every 2 weeks" on either side) trigger a
            // writeback to the other side. #57 Phase B.
            task.recurrenceRule ?? ""
        ]
        return components.joined(separator: "|").data(using: .utf8)?.base64EncodedString() ?? ""
    }
}
