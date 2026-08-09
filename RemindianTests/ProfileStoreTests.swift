import XCTest
@testable import Remindian

/// Tests for the multi-profile data model (`ProfileStore` / `SyncProfile`).
///
/// These cover the pure, deterministic logic — migration shape, normalization
/// invariants, deep copy, global-settings propagation, state-key mapping, and
/// Codable round-trip — without touching the real Application Support directory.
final class ProfileStoreTests: XCTestCase {

    // MARK: - Default / migration shape

    func test_makeDefault_wrapsConfigAsSingleDefaultProfile() {
        let cfg = SyncConfiguration()
        cfg.vaultPath = "/tmp/vault"
        let store = ProfileStore.makeDefault(from: cfg, name: "Default", id: "id-1")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.activeProfileId, "id-1")
        let p = store.profiles[0]
        XCTAssertTrue(p.isDefault)
        XCTAssertTrue(p.enabled)
        XCTAssertEqual(p.name, "Default")
        XCTAssertEqual(p.config.vaultPath, "/tmp/vault")
    }

    func test_defaultProfile_usesLegacyStateKey() {
        // The whole zero-migration promise: the default profile's state key is
        // empty → it keeps using the historical sync_state.json.
        let store = ProfileStore.makeDefault(from: SyncConfiguration(), id: "abc")
        XCTAssertEqual(store.profiles[0].stateKey, "", "Default profile must reuse the legacy state file.")

        // A non-default profile keys its state by id.
        let other = SyncProfile(id: "xyz", name: "Work", isDefault: false, config: SyncConfiguration())
        XCTAssertEqual(other.stateKey, "xyz")
    }

    // MARK: - Normalization invariants

    func test_normalized_emptyProfiles_yieldsDefault() {
        let store = ProfileStore(profiles: [], activeProfileId: "nope").normalized()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(store.profiles[0].isDefault)
        XCTAssertEqual(store.activeProfileId, store.profiles[0].id)
    }

    func test_normalized_noDefault_promotesFirst() {
        let a = SyncProfile(id: "a", name: "A", isDefault: false, config: SyncConfiguration())
        let b = SyncProfile(id: "b", name: "B", isDefault: false, config: SyncConfiguration())
        let store = ProfileStore(profiles: [a, b], activeProfileId: "a").normalized()
        XCTAssertTrue(store.profiles[0].isDefault)
        XCTAssertFalse(store.profiles[1].isDefault)
    }

    func test_normalized_multipleDefaults_keepsOnlyFirst() {
        let a = SyncProfile(id: "a", name: "A", isDefault: true, config: SyncConfiguration())
        let b = SyncProfile(id: "b", name: "B", isDefault: true, config: SyncConfiguration())
        let store = ProfileStore(profiles: [a, b], activeProfileId: "b").normalized()
        XCTAssertEqual(store.profiles.filter { $0.isDefault }.count, 1)
        XCTAssertTrue(store.profiles[0].isDefault)
    }

    func test_normalized_invalidActiveId_resetsToFirst() {
        let a = SyncProfile(id: "a", name: "A", isDefault: true, config: SyncConfiguration())
        let store = ProfileStore(profiles: [a], activeProfileId: "ghost").normalized()
        XCTAssertEqual(store.activeProfileId, "a")
    }

    // MARK: - Deep copy

    func test_deepCopy_isIndependent() {
        let original = SyncConfiguration()
        original.vaultPath = "/one"
        original.listMappings = [.init(obsidianTag: "#work", remindersList: "Work")]
        let copy = original.deepCopy()
        copy.vaultPath = "/two"
        copy.listMappings = []

        XCTAssertEqual(original.vaultPath, "/one", "Mutating the copy must not affect the original.")
        XCTAssertEqual(original.listMappings.count, 1)
        XCTAssertEqual(copy.vaultPath, "/two")
    }

    // MARK: - Global settings propagation

    func test_propagateGlobalSettings_copiesGlobalsButNotPerPipeline() {
        let activeCfg = SyncConfiguration()
        activeCfg.launchAtLogin = true
        activeCfg.globalHotKeyEnabled = true
        activeCfg.syncIntervalMinutes = 42
        activeCfg.enableNotifications = false
        activeCfg.vaultPath = "/active-vault"          // per-pipeline — must NOT propagate
        activeCfg.defaultList = "ActiveList"           // per-pipeline — must NOT propagate

        let otherCfg = SyncConfiguration()
        otherCfg.vaultPath = "/other-vault"
        otherCfg.defaultList = "OtherList"
        otherCfg.syncIntervalMinutes = 7             // per-profile schedule — must NOT be overwritten

        let active = SyncProfile(id: "a", name: "A", isDefault: true, config: activeCfg)
        let other = SyncProfile(id: "b", name: "B", isDefault: false, config: otherCfg)
        let store = ProfileStore(profiles: [active, other], activeProfileId: "a")

        store.propagateGlobalSettings()

        // Globals copied:
        XCTAssertTrue(otherCfg.launchAtLogin)
        XCTAssertTrue(otherCfg.globalHotKeyEnabled)
        XCTAssertFalse(otherCfg.enableNotifications)
        // The sync schedule is per-profile since v5.28.0, so each pipeline can run
        // at its own cadence. It used to be forced identical everywhere.
        XCTAssertEqual(otherCfg.syncIntervalMinutes, 7,
                       "The auto-sync interval is per-profile and must not be propagated.")
        // Per-pipeline untouched:
        XCTAssertEqual(otherCfg.vaultPath, "/other-vault", "Vault path is per-profile and must not be propagated.")
        XCTAssertEqual(otherCfg.defaultList, "OtherList")
    }

    // MARK: - Codable round-trip

    func test_codableRoundTrip_preservesProfiles() throws {
        let c1 = SyncConfiguration(); c1.vaultPath = "/v1"; c1.taskDestinationType = .appleReminders
        let c2 = SyncConfiguration(); c2.vaultPath = "/v2"; c2.taskDestinationType = .todoist
        let store = ProfileStore(profiles: [
            SyncProfile(id: "1", name: "Perso", isDefault: true, config: c1),
            SyncProfile(id: "2", name: "Work", enabled: false, isDefault: false, config: c2),
        ], activeProfileId: "2")

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ProfileStore.self, from: data)

        XCTAssertEqual(decoded.profiles.count, 2)
        XCTAssertEqual(decoded.activeProfileId, "2")
        XCTAssertEqual(decoded.profiles[0].name, "Perso")
        XCTAssertEqual(decoded.profiles[0].config.vaultPath, "/v1")
        XCTAssertEqual(decoded.profiles[1].enabled, false)
        XCTAssertEqual(decoded.profiles[1].config.taskDestinationType, .todoist)
    }

    // MARK: - Queries

    func test_enabledProfiles_filters() {
        let a = SyncProfile(id: "a", name: "A", enabled: true, isDefault: true, config: SyncConfiguration())
        let b = SyncProfile(id: "b", name: "B", enabled: false, isDefault: false, config: SyncConfiguration())
        let store = ProfileStore(profiles: [a, b], activeProfileId: "a")
        XCTAssertEqual(store.enabledProfiles.map { $0.id }, ["a"])
        XCTAssertEqual(store.activeProfile?.id, "a")
    }
}
