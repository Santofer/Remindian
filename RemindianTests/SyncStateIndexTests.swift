import XCTest
@testable import Remindian

/// Tests for the SyncState in-memory acceleration indexes (perf rearchitecture).
///
/// SyncState gained `idxByObsidianId` / `idxByRemindersId` dictionaries so the
/// sync engine's per-task lookups go from O(n) to O(1). The array `mappings`
/// stays the on-disk source of truth (backward-compatible JSON). These tests
/// lock in that the indexes stay perfectly consistent with the array across
/// every mutation, survive Codable round-trips, and that a legacy state file
/// (no index keys, which never existed on disk anyway) decodes cleanly.
final class SyncStateIndexTests: XCTestCase {

    func test_addThenFindByBothIds() {
        let s = SyncState()
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "r1", obsidianHash: "oh", remindersHash: "rh")

        XCTAssertEqual(s.findMapping(obsidianId: "o1")?.remindersId, "r1")
        XCTAssertEqual(s.findMapping(remindersId: "r1")?.obsidianId, "o1")
        XCTAssertTrue(s.hasMapping(obsidianId: "o1"))
        XCTAssertFalse(s.hasMapping(obsidianId: "nope"))
    }

    func test_updateInPlaceKeepsConsistency() {
        let s = SyncState()
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "r1", obsidianHash: "h1", remindersHash: "rh1")
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "r1", obsidianHash: "h2", remindersHash: "rh2")

        XCTAssertEqual(s.mappings.count, 1, "Same obsidianId updates in place, no duplicate row.")
        XCTAssertEqual(s.findMapping(obsidianId: "o1")?.lastObsidianHash, "h2")
        XCTAssertEqual(s.findMapping(obsidianId: "o1")?.lastRemindersHash, "rh2")
    }

    func test_reconnectChangesRemindersIdAndReindexes() {
        // The dedup/relink path updates an existing obsidianId to point at a
        // different remindersId. The old remindersId must stop resolving.
        let s = SyncState()
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "rOLD", obsidianHash: "h", remindersHash: "rh")
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "rNEW", obsidianHash: "h", remindersHash: "rh")

        XCTAssertEqual(s.mappings.count, 1)
        XCTAssertEqual(s.findMapping(obsidianId: "o1")?.remindersId, "rNEW")
        XCTAssertEqual(s.findMapping(remindersId: "rNEW")?.obsidianId, "o1")
        XCTAssertNil(s.findMapping(remindersId: "rOLD"), "Old remindersId must no longer resolve after reconnect.")
    }

    func test_removeByObsidianIdReindexesRemaining() {
        let s = SyncState()
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "r1", obsidianHash: "h", remindersHash: "rh")
        s.addOrUpdateMapping(obsidianId: "o2", remindersId: "r2", obsidianHash: "h", remindersHash: "rh")
        s.addOrUpdateMapping(obsidianId: "o3", remindersId: "r3", obsidianHash: "h", remindersHash: "rh")

        s.removeMapping(obsidianId: "o2") // middle removal shifts array indices

        XCTAssertEqual(s.mappings.count, 2)
        XCTAssertNil(s.findMapping(obsidianId: "o2"))
        XCTAssertNil(s.findMapping(remindersId: "r2"))
        // The survivors must still resolve correctly (indices were rebuilt).
        XCTAssertEqual(s.findMapping(obsidianId: "o1")?.remindersId, "r1")
        XCTAssertEqual(s.findMapping(obsidianId: "o3")?.remindersId, "r3")
        XCTAssertEqual(s.findMapping(remindersId: "r3")?.obsidianId, "o3")
    }

    func test_removeByRemindersId() {
        let s = SyncState()
        s.addOrUpdateMapping(obsidianId: "o1", remindersId: "r1", obsidianHash: "h", remindersHash: "rh")
        s.addOrUpdateMapping(obsidianId: "o2", remindersId: "r2", obsidianHash: "h", remindersHash: "rh")

        s.removeMapping(remindersId: "r1")

        XCTAssertNil(s.findMapping(remindersId: "r1"))
        XCTAssertNil(s.findMapping(obsidianId: "o1"))
        XCTAssertEqual(s.findMapping(remindersId: "r2")?.obsidianId, "o2")
    }

    func test_codableRoundtripRebuildsIndexes() throws {
        let s = SyncState()
        for i in 1...100 {
            s.addOrUpdateMapping(obsidianId: "o\(i)", remindersId: "r\(i)", obsidianHash: "h\(i)", remindersHash: "rh\(i)")
        }
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(SyncState.self, from: data)

        XCTAssertEqual(decoded.mappings.count, 100)
        // O(1) lookups must work immediately after decode (indexes rebuilt in init(from:)).
        XCTAssertEqual(decoded.findMapping(obsidianId: "o42")?.remindersId, "r42")
        XCTAssertEqual(decoded.findMapping(remindersId: "r77")?.obsidianId, "o77")
        XCTAssertTrue(decoded.hasMapping(obsidianId: "o1"))
        XCTAssertFalse(decoded.hasMapping(obsidianId: "o101"))
    }

    func test_legacyJSONWithoutIndexKeysDecodes() throws {
        // The on-disk format only ever had `mappings`/`lastSyncDate`/`stateVersion`.
        // Confirm a hand-written legacy payload decodes and indexes rebuild.
        let legacy = """
        {
          "mappings": [
            {"obsidianId":"oA","remindersId":"rA","lastObsidianHash":"x","lastRemindersHash":"y","lastSyncDate":0},
            {"obsidianId":"oB","remindersId":"rB","lastObsidianHash":"x","lastRemindersHash":"y","lastSyncDate":0}
          ],
          "stateVersion": 8
        }
        """
        let s = try JSONDecoder().decode(SyncState.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.mappings.count, 2)
        XCTAssertEqual(s.findMapping(obsidianId: "oB")?.remindersId, "rB")
        XCTAssertEqual(s.findMapping(remindersId: "rA")?.obsidianId, "oA")
    }

    func test_indexAgreesWithArrayUnderRandomChurn() {
        // Fuzz-ish consistency check: after a mix of add/update/remove, every
        // array element must be findable by both ids, and counts must agree.
        let s = SyncState()
        // Seed
        for i in 0..<50 {
            s.addOrUpdateMapping(obsidianId: "o\(i)", remindersId: "r\(i)", obsidianHash: "h", remindersHash: "rh")
        }
        // Update half
        for i in stride(from: 0, to: 50, by: 2) {
            s.addOrUpdateMapping(obsidianId: "o\(i)", remindersId: "r\(i)", obsidianHash: "h2", remindersHash: "rh2")
        }
        // Remove a third
        for i in stride(from: 0, to: 50, by: 3) {
            s.removeMapping(obsidianId: "o\(i)")
        }

        for m in s.mappings {
            XCTAssertEqual(s.findMapping(obsidianId: m.obsidianId)?.remindersId, m.remindersId,
                           "Array row \(m.obsidianId) not findable by obsidianId.")
            XCTAssertEqual(s.findMapping(remindersId: m.remindersId)?.obsidianId, m.obsidianId,
                           "Array row \(m.remindersId) not findable by remindersId.")
        }
        // No phantom entries: a removed id must not resolve.
        XCTAssertNil(s.findMapping(obsidianId: "o0"))  // removed (0 % 3 == 0)
        XCTAssertNil(s.findMapping(obsidianId: "o3"))
    }
}
