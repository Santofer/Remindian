import XCTest
@testable import Remindian

/// Tests for the crash-loop breaker state machine. (#80)
///
/// The contract: a launch that crashes during startup (registers an attempt but
/// never reaches `markHealthy`) must latch Safe Mode on the *next* launch, and
/// stay there until the user explicitly resumes — while a clean run, or a clean
/// quit, is never mistaken for a crash.
final class SafeModeTests: XCTestCase {
    private let suiteName = "SafeModeTests"
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        SafeMode.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        SafeMode.defaults = .standard
        suite = nil
        super.tearDown()
    }

    func test_firstLaunch_isNotSafeMode() {
        XCTAssertFalse(SafeMode.isActive)
        XCTAssertFalse(SafeMode.registerLaunchAttempt(), "A clean first launch is not Safe Mode.")
        XCTAssertFalse(SafeMode.isActive)
    }

    func test_healthyRun_thenNextLaunchStaysNormal() {
        SafeMode.registerLaunchAttempt()   // launch 1
        SafeMode.markHealthy()             // survived startup
        XCTAssertFalse(SafeMode.registerLaunchAttempt(), "A launch after a healthy run is normal.")  // launch 2
    }

    func test_startupCrash_latchesSafeModeOnNextLaunch() {
        SafeMode.registerLaunchAttempt()   // launch 1 — crashes before markHealthy (pending stays set)
        XCTAssertTrue(SafeMode.registerLaunchAttempt(), "A startup crash latches Safe Mode next launch.")  // launch 2
        XCTAssertTrue(SafeMode.isActive)
    }

    func test_safeModeIsSticky_acrossHealthyLaunches() {
        SafeMode.registerLaunchAttempt()
        SafeMode.registerLaunchAttempt()   // now in Safe Mode
        XCTAssertTrue(SafeMode.isActive)
        SafeMode.markHealthy()             // Safe-Mode launch survives (it skipped the dangerous work)
        XCTAssertTrue(SafeMode.registerLaunchAttempt(), "Safe Mode persists until the user resumes.")
    }

    func test_resume_clearsSafeMode() {
        SafeMode.registerLaunchAttempt()
        SafeMode.registerLaunchAttempt()
        XCTAssertTrue(SafeMode.isActive)
        SafeMode.resume()
        XCTAssertFalse(SafeMode.isActive)
        XCTAssertFalse(SafeMode.registerLaunchAttempt(), "After resume the next launch is normal.")
    }

    func test_cleanTermination_preventsFalsePositive() {
        SafeMode.registerLaunchAttempt()
        SafeMode.markHealthy()             // applicationWillTerminate on a clean quit
        XCTAssertFalse(SafeMode.registerLaunchAttempt(), "A clean quit is not a crash.")
    }
}
