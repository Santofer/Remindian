import XCTest
@testable import Remindian

/// Deleting destination items is the only irreversible thing a sync does, and
/// every destructive incident this project has had looked identical from the
/// engine's side: the scan narrowed for a reason nobody noticed, so a pile of
/// still-wanted tasks looked deleted at once.
final class MassDeletionGuardTests: XCTestCase {

    func test_limitDefaultsToASaneValue() {
        let config = SyncConfiguration()
        XCTAssertEqual(config.maxDeletionsPerSync, 25,
                       "On by default — a guard nobody enables protects nobody")
    }

    func test_limitSurvivesEncodeDecode() throws {
        let config = SyncConfiguration()
        config.maxDeletionsPerSync = 50
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.maxDeletionsPerSync, 50)
    }

    func test_negativeLimitDegradesToNoLimit() throws {
        // A corrupt config must not turn into "refuse every deletion forever".
        let config = SyncConfiguration()
        config.maxDeletionsPerSync = -5
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.maxDeletionsPerSync, 0)
    }

    func test_zeroMeansUnlimited() {
        // Explicit opt-out has to remain possible for people who bulk-edit vaults.
        let config = SyncConfiguration()
        config.maxDeletionsPerSync = 0
        XCTAssertEqual(config.maxDeletionsPerSync, 0)
    }

    func test_blockedErrorExplainsItselfAndNamesTheNumbers() {
        let error = SyncError.massDeletionBlocked(count: 67, limit: 25)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("67"), "Say how many. Got: \(message)")
        XCTAssertTrue(message.contains("25"), "Say what the limit was. Got: \(message)")
        XCTAssertTrue(message.lowercased().contains("nothing was removed"),
                      "The reassurance matters more than the number. Got: \(message)")
    }
}
