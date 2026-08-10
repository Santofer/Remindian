import XCTest
@testable import Remindian

/// The health check exists to catch the failure mode this project keeps hitting:
/// a sync that works exactly as configured, while the configuration doesn't mean
/// what the user assumed. Each test below mirrors a real shipped bug.
final class SyncHealthTests: XCTestCase {

    /// A configuration with nothing wrong with it.
    private func healthyInput() -> SyncHealth.Input {
        SyncHealth.Input(
            vaultPathExists: true,
            vaultPath: "/vault",
            scannedTaskCount: 42,
            eligibleTaskCount: 42,
            mappingCount: 3
        )
    }

    private func titles(_ report: SyncHealth.Report) -> [String] {
        report.findings.map(\.title)
    }

    // MARK: - Healthy baseline

    func test_healthySetupReportsNothing() {
        let report = SyncHealth.evaluate(healthyInput())
        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.findings.isEmpty, "Got: \(titles(report))")
    }

    // MARK: - Broken outright

    func test_missingVaultIsCritical() {
        var input = healthyInput()
        input.vaultPathExists = false
        let report = SyncHealth.evaluate(input)
        XCTAssertEqual(report.criticalCount, 1)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(titles(report).contains { $0.contains("Vault folder not found") })
    }

    func test_noDestinationAccessIsCritical() {
        var input = healthyInput()
        input.destinationAuthorized = false
        input.destinationName = "Apple Reminders"
        let report = SyncHealth.evaluate(input)
        XCTAssertEqual(report.criticalCount, 1)
        XCTAssertTrue(report.findings[0].detail.contains("Apple Reminders"))
    }

    // MARK: - The #81 class: a filter that silently matches nothing

    func test_missingWhitelistFolderIsFlagged() {
        var input = healthyInput()
        input.missingWhitelistFolders = ["Projeckts"]   // typo
        let report = SyncHealth.evaluate(input)
        let finding = try? XCTUnwrap(report.findings.first)
        XCTAssertEqual(finding?.severity, .warning)
        XCTAssertTrue(finding?.detail.contains("Projeckts") ?? false, "Must name the offending folder")
        XCTAssertNotNil(finding?.suggestion, "A typo'd folder needs an actionable fix")
    }

    func test_multipleMissingFoldersAreSummarised() {
        var input = healthyInput()
        input.missingWhitelistFolders = ["A", "B", "C"]
        let report = SyncHealth.evaluate(input)
        XCTAssertTrue(titles(report).contains { $0.contains("3 folders") }, "Got: \(titles(report))")
    }

    // MARK: - The #88/#89 class: a global filter that excludes everything

    func test_filterMatchingNothingIsCritical() {
        var input = healthyInput()
        input.globalFilter = "#task"
        input.scannedTaskCount = 120
        input.eligibleTaskCount = 0
        let report = SyncHealth.evaluate(input)
        XCTAssertEqual(report.criticalCount, 1, "Silently syncing nothing is the worst failure mode")
        XCTAssertTrue(report.findings[0].detail.contains("120"), "Say how many tasks exist, so the cause is obvious")
        XCTAssertTrue(report.findings[0].detail.contains("#task"))
    }

    func test_filterThatMatchesSomethingIsFine() {
        var input = healthyInput()
        input.globalFilter = "#task"
        input.scannedTaskCount = 120
        input.eligibleTaskCount = 30
        XCTAssertTrue(SyncHealth.evaluate(input).isHealthy)
    }

    /// An empty vault shouldn't be reported as a *filter* problem.
    func test_emptyVaultIsAWarningNotAFilterProblem() {
        var input = healthyInput()
        input.scannedTaskCount = 0
        input.eligibleTaskCount = 0
        input.globalFilter = "#task"
        let report = SyncHealth.evaluate(input)
        XCTAssertFalse(titles(report).contains { $0.contains("global filter matches no tasks") },
                       "With zero tasks the filter isn't the culprit. Got: \(titles(report))")
        XCTAssertTrue(titles(report).contains { $0.contains("No tasks found") })
    }

    // MARK: - Data about to be destroyed

    func test_pendingDeletionsAreSurfacedWithSamples() {
        var input = healthyInput()
        input.pendingDeletionTitles = ["Buy milk", "Call the bank", "Renew passport"]
        let report = SyncHealth.evaluate(input)
        let finding = report.findings[0]
        XCTAssertEqual(finding.severity, .warning)
        XCTAssertTrue(finding.title.contains("3 reminders"))
        XCTAssertTrue(finding.detail.contains("Buy milk"), "Show what would go. Got:\n\(finding.detail)")
    }

    func test_manyPendingDeletionsEscalateToCritical() {
        var input = healthyInput()
        input.pendingDeletionTitles = (1...25).map { "Task \($0)" }
        let report = SyncHealth.evaluate(input)
        XCTAssertEqual(report.findings[0].severity, .critical,
                       "A mass deletion is how #81 destroyed reminders — it must shout")
        XCTAssertTrue(report.findings[0].detail.contains("and 20 more"), "Truncate the list. Got:\n\(report.findings[0].detail)")
    }

    // MARK: - Informational

    func test_inboxOutsideWhitelistIsExplainedNotAlarming() {
        var input = healthyInput()
        input.inboxOutsideWhitelist = true
        input.inboxRelativePath = "Inbox.md"
        let report = SyncHealth.evaluate(input)
        XCTAssertTrue(report.isHealthy, "It's safe by design — must not read as a problem")
        XCTAssertEqual(report.findings.first?.severity, .info)
        XCTAssertTrue(report.findings[0].detail.contains("Inbox.md"))
    }

    func test_dryRunModeIsMentioned() {
        var input = healthyInput()
        input.isDryRun = true
        let report = SyncHealth.evaluate(input)
        XCTAssertTrue(titles(report).contains { $0.contains("Dry-run") })
        XCTAssertTrue(report.isHealthy, "Dry run is a deliberate choice, not a fault")
    }

    func test_conflictsAndErrorsAreReported() {
        var input = healthyInput()
        input.unresolvedConflictCount = 2
        input.lastSyncErrorCount = 1
        let report = SyncHealth.evaluate(input)
        XCTAssertEqual(report.warningCount, 2)
        XCTAssertTrue(titles(report).contains { $0.contains("2 unresolved conflicts") })
        XCTAssertTrue(titles(report).contains { $0.contains("1 error") })
    }

    // MARK: - Presentation

    func test_findingsAreOrderedMostSevereFirst() {
        var input = healthyInput()
        input.isDryRun = true                              // info
        input.unresolvedConflictCount = 1                  // warning
        input.vaultPathExists = false                      // critical
        let severities = SyncHealth.evaluate(input).findings.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(), "Most severe first")
        XCTAssertEqual(severities.first, .critical)
    }

    func test_isHealthyIgnoresInfoOnly() {
        var input = healthyInput()
        input.isDryRun = true
        let report = SyncHealth.evaluate(input)
        XCTAssertFalse(report.findings.isEmpty)
        XCTAssertTrue(report.isHealthy, "Info-level notes don't make a setup unhealthy")
    }

    func test_evaluateIsPure() {
        let input = healthyInput()
        XCTAssertEqual(SyncHealth.evaluate(input).findings, SyncHealth.evaluate(input).findings)
    }
}
