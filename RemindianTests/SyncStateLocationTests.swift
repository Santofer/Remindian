import XCTest
@testable import Remindian

/// Tests for multi-device sync-state storage (#15, v5.14.0).
///
/// The feature lets the sync-state mapping table live inside the vault
/// (`<vault>/.remindian/sync_state.json`) so a user who already syncs their
/// vault across Macs reuses the same reminders instead of creating duplicates.
/// The invariant that matters for "infallible": a vault-stored state round-trips
/// losslessly, each vault is isolated, an unresolvable location degrades safely,
/// and the on-disk JSON format is byte-compatible with the App-Support store
/// (only the *location* changes, never the schema).
///
/// These tests pass `seedFromAppSupportIfMissing: false` so they never read the
/// developer's real `~/Library/Application Support` — keeping them deterministic.
final class SyncStateLocationTests: XCTestCase {

    private var vaultURL: URL!

    override func setUp() {
        super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-state-loc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vaultURL)
        vaultURL = nil
        super.tearDown()
    }

    private func makeState(_ mappingCount: Int) -> SyncState {
        let state = SyncState()
        for i in 0..<mappingCount {
            state.addOrUpdateMapping(
                obsidianId: "obs-\(i)",
                remindersId: "rem-\(i)",
                obsidianHash: "oh-\(i)",
                remindersHash: "rh-\(i)"
            )
        }
        return state
    }

    // MARK: - URL resolution

    func test_vaultURL_isInsideRemindianDotFolder_andDirCreated() {
        let url = SyncState.stateURL(location: .vault, vaultPath: vaultURL.path)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "sync_state.json")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, ".remindian")
        // The .remindian directory must be created as a side effect so the
        // first save() can't fail on a missing parent.
        let dir = vaultURL.appendingPathComponent(".remindian")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_emptyVaultPath_resolvesToNil() {
        XCTAssertNil(SyncState.stateURL(location: .vault, vaultPath: ""))
        XCTAssertNil(SyncState.stateURL(location: .vault, vaultPath: "   "))
    }

    func test_appSupportURL_endsWithStateFile() {
        let url = SyncState.stateURL(location: .applicationSupport, vaultPath: vaultURL.path)
        XCTAssertEqual(url?.lastPathComponent, "sync_state.json")
    }

    // MARK: - Round-trip

    func test_vaultRoundTrip_preservesMappings() {
        let state = makeState(5)
        state.lastSyncDate = Date(timeIntervalSince1970: 1_700_000_000)
        state.save(location: .vault, vaultPath: vaultURL.path)

        // File physically lands in the vault's .remindian folder.
        let onDisk = vaultURL.appendingPathComponent(".remindian/sync_state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))

        let loaded = SyncState.load(location: .vault, vaultPath: vaultURL.path, seedFromAppSupportIfMissing: false)
        XCTAssertEqual(loaded.mappings.count, 5)
        XCTAssertEqual(Set(loaded.mappings.map { $0.obsidianId }), Set((0..<5).map { "obs-\($0)" }))
        XCTAssertEqual(loaded.lastSyncDate, Date(timeIntervalSince1970: 1_700_000_000))
        // Indexes must be rebuilt on decode → O(1) lookups still work.
        XCTAssertNotNil(loaded.findMapping(obsidianId: "obs-3"))
        XCTAssertNotNil(loaded.findMapping(remindersId: "rem-3"))
    }

    func test_eachVaultIsIsolated() {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-state-loc-other-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        makeState(3).save(location: .vault, vaultPath: vaultURL.path)

        // A different vault with no state file (seeding off) loads empty — no
        // cross-contamination between vaults.
        let loadedOther = SyncState.load(location: .vault, vaultPath: other.path, seedFromAppSupportIfMissing: false)
        XCTAssertEqual(loadedOther.mappings.count, 0)
    }

    func test_missingVaultFile_withoutSeed_loadsEmpty() {
        let loaded = SyncState.load(location: .vault, vaultPath: vaultURL.path, seedFromAppSupportIfMissing: false)
        XCTAssertEqual(loaded.mappings.count, 0)
        XCTAssertEqual(loaded.stateVersion, SyncState.currentStateVersion)
    }

    // MARK: - Format compatibility

    func test_onDiskFormatIsLocationAgnostic() throws {
        // The JSON written to the vault must be decodable as a plain SyncState —
        // i.e. the schema is identical to the App-Support store; only the path
        // differs. This guards against accidentally embedding location-specific
        // keys that would break a user switching back to App Support.
        let state = makeState(2)
        state.lastSyncDate = Date(timeIntervalSince1970: 1_700_000_000)
        state.save(location: .vault, vaultPath: vaultURL.path)
        let data = try Data(contentsOf: vaultURL.appendingPathComponent(".remindian/sync_state.json"))
        let decoded = try JSONDecoder().decode(SyncState.self, from: data)
        XCTAssertEqual(decoded.mappings.count, 2)

        // And the serialized keys are exactly the persisted triplet.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["mappings", "lastSyncDate", "stateVersion"])
    }

    // MARK: - Config backward compatibility

    func test_configDefaultsToApplicationSupport() {
        XCTAssertEqual(SyncConfiguration().syncStateLocation, .applicationSupport)
    }

    func test_legacyConfigWithoutLocationKeyDecodesToAppSupport() throws {
        // Simulate a real pre-#15 config.json: encode a current config, then
        // strip the new syncStateLocation key. Decoding must fall back to the
        // safe default rather than throwing.
        let data = try JSONEncoder().encode(SyncConfiguration())
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "syncStateLocation")
        XCTAssertNil(obj["syncStateLocation"], "Precondition: key removed.")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let cfg = try JSONDecoder().decode(SyncConfiguration.self, from: legacyData)
        XCTAssertEqual(cfg.syncStateLocation, .applicationSupport)
    }

    func test_configRoundTripPreservesVaultLocation() throws {
        let cfg = SyncConfiguration()
        cfg.syncStateLocation = .vault
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: data)
        XCTAssertEqual(decoded.syncStateLocation, .vault)
    }
}
