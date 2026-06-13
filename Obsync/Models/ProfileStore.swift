import Foundation

/// One independent sync pipeline: a source → destination configuration with its
/// own mappings, filters, writeback toggles, and sync state. (multi-profile)
///
/// A profile *is* a `SyncConfiguration` plus identity/enable metadata — this is
/// deliberate: the active profile's config stays bound to the existing Settings
/// UI unchanged, so the proven single-profile UI keeps working verbatim.
struct SyncProfile: Codable, Identifiable {
    let id: String
    var name: String
    var enabled: Bool
    /// The profile migrated from the pre-multi-profile install. It reuses the
    /// historical `sync_state.json` (empty state key) so existing mappings are
    /// untouched. There is always exactly one default profile.
    var isDefault: Bool
    var config: SyncConfiguration

    /// State-file key for this profile. The default profile uses "" (the legacy
    /// `sync_state.json`); others use their id → `sync_state_<id>.json`.
    var stateKey: String { isDefault ? "" : id }

    init(id: String = UUID().uuidString, name: String, enabled: Bool = true, isDefault: Bool = false, config: SyncConfiguration) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.isDefault = isDefault
        self.config = config
    }
}

/// Persisted collection of sync profiles + which one is active in the UI.
/// Stored as `profiles.json` alongside the legacy `config.json`. On first run
/// after upgrading, the legacy `config.json` is migrated into a single default
/// profile (see `load()`), so existing users see exactly their current setup.
struct ProfileStore: Codable {
    var profiles: [SyncProfile]
    var activeProfileId: String
    var version: Int

    static let currentVersion = 1

    init(profiles: [SyncProfile], activeProfileId: String, version: Int = ProfileStore.currentVersion) {
        self.profiles = profiles
        self.activeProfileId = activeProfileId
        self.version = version
    }

    // MARK: - Construction

    /// Wrap a single configuration as the default profile (used for migration
    /// and for a fresh install). `id` is injectable for deterministic tests.
    static func makeDefault(from config: SyncConfiguration, name: String = "Default", id: String = UUID().uuidString) -> ProfileStore {
        let profile = SyncProfile(id: id, name: name, enabled: true, isDefault: true, config: config)
        return ProfileStore(profiles: [profile], activeProfileId: id)
    }

    // MARK: - Queries

    var activeProfile: SyncProfile? {
        profiles.first { $0.id == activeProfileId } ?? profiles.first
    }

    var enabledProfiles: [SyncProfile] {
        profiles.filter { $0.enabled }
    }

    // MARK: - Invariants

    /// Guarantee the store is well-formed: at least one profile, exactly one
    /// default, and a valid active id. Returns a corrected copy.
    func normalized() -> ProfileStore {
        var store = self
        if store.profiles.isEmpty {
            return ProfileStore.makeDefault(from: SyncConfiguration())
        }
        // Exactly one default: if none, make the first default; if several, keep
        // the first and demote the rest.
        if !store.profiles.contains(where: { $0.isDefault }) {
            store.profiles[0].isDefault = true
        } else {
            var seenDefault = false
            for i in store.profiles.indices {
                if store.profiles[i].isDefault {
                    if seenDefault { store.profiles[i].isDefault = false }
                    seenDefault = true
                }
            }
        }
        // Valid active id.
        if !store.profiles.contains(where: { $0.id == store.activeProfileId }) {
            store.activeProfileId = store.profiles.first!.id
        }
        return store
    }

    /// Propagate app-wide singleton settings (hotkey, login item, notifications,
    /// auto-sync timer, appearance) from the active profile to all others so
    /// they never diverge. Per-profile fields are left untouched.
    func propagateGlobalSettings() {
        guard let active = activeProfile else { return }
        for profile in profiles where profile.id != active.id {
            profile.config.applyGlobalSettings(from: active.config)
        }
    }

    // MARK: - Persistence

    private static var storeURL: URL? {
        guard let appFolder = remindianAppSupportDir() else { return nil }
        return appFolder.appendingPathComponent("profiles.json")
    }

    func save() {
        guard let url = Self.storeURL else { return }
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save profile store: \(error)")
        }
    }

    /// Load the profile store, migrating the legacy single `config.json` into a
    /// default profile on first run. Always returns a normalized store with ≥1
    /// profile — never throws, never empties.
    static func load() -> ProfileStore {
        if let url = storeURL, let data = try? Data(contentsOf: url),
           let store = try? JSONDecoder().decode(ProfileStore.self, from: data),
           !store.profiles.isEmpty {
            return store.normalized()
        }
        // Migration / fresh install: the existing config.json becomes the
        // Default profile (which keeps using the legacy sync_state.json).
        let legacy = SyncConfiguration.load()
        let migrated = makeDefault(from: legacy)
        migrated.save()
        return migrated
    }
}
