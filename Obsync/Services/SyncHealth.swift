import Foundation

/// A pre-flight check that answers "is my sync configured the way I think it is?"
///
/// Every user-facing bug this project has shipped had the same shape: the sync was
/// working exactly as configured, but the configuration didn't mean what the user
/// assumed — a whitelist that silently let the vault root through (#81), a global
/// filter that matched nothing (#88/#89), a folder name with a typo. None of those
/// surface as errors; they surface as *silence*, or as reminders quietly
/// disappearing. This turns that silence into a list of findings.
///
/// `evaluate` is deliberately pure: the caller gathers the facts (which files
/// exist, what a dry run would do) and this decides what they mean. That keeps
/// the judgement testable without a vault, an EventKit store, or a real sync.
enum SyncHealth {

    struct Finding: Identifiable, Equatable {
        enum Severity: Int, Comparable {
            case critical = 0   // sync is broken or about to destroy something
            case warning  = 1   // sync works, but probably not as intended
            case info     = 2   // worth knowing, not a problem

            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

            var label: String {
                switch self {
                case .critical: return "Critical"
                case .warning:  return "Warning"
                case .info:     return "Info"
                }
            }

            var symbolName: String {
                switch self {
                case .critical: return "exclamationmark.octagon.fill"
                case .warning:  return "exclamationmark.triangle.fill"
                case .info:     return "info.circle"
                }
            }
        }

        let id = UUID()
        let severity: Severity
        let title: String
        let detail: String
        /// What the user can actually do about it. Nil when there's nothing to do.
        let suggestion: String?

        static func == (a: Finding, b: Finding) -> Bool {
            a.severity == b.severity && a.title == b.title && a.detail == b.detail
        }
    }

    /// Everything `evaluate` needs, gathered by the caller.
    struct Input {
        var vaultPathExists: Bool
        var vaultPath: String
        /// Whitelisted folders (`includedFolders`) that don't exist on disk — almost
        /// always a typo or a renamed folder, and the reason "nothing syncs".
        var missingWhitelistFolders: [String] = []
        /// Tasks the source returned for the current configuration.
        var scannedTaskCount: Int = 0
        /// Tasks that survived the global filter. Equal to `scannedTaskCount` when
        /// no filter is configured.
        var eligibleTaskCount: Int = 0
        var globalFilter: String = ""
        /// Titles of destination items a sync would delete right now.
        var pendingDeletionTitles: [String] = []
        var unresolvedConflictCount: Int = 0
        var lastSyncErrorCount: Int = 0
        var mappingCount: Int = 0
        var destinationAuthorized: Bool = true
        var destinationName: String = "the destination"
        var inboxRelativePath: String = ""
        /// True when a whitelist is configured *and* the inbox sits outside it.
        /// Remindian force-includes the inbox to keep the round-trip safe, so this
        /// is explanatory rather than broken.
        var inboxOutsideWhitelist: Bool = false
        var isDryRun: Bool = false
    }

    struct Report {
        var findings: [Finding]
        /// True when nothing above `.info` was found.
        var isHealthy: Bool { !findings.contains { $0.severity < .info } }
        var criticalCount: Int { findings.filter { $0.severity == .critical }.count }
        var warningCount: Int { findings.filter { $0.severity == .warning }.count }
    }

    /// Decide what the gathered facts mean. Pure — same input, same report.
    static func evaluate(_ input: Input) -> Report {
        var findings: [Finding] = []

        // --- Things that stop the sync working at all ---

        if !input.vaultPathExists {
            findings.append(Finding(
                severity: .critical,
                title: "Vault folder not found",
                detail: input.vaultPath.isEmpty
                    ? "No vault folder is set, so there's nothing to scan."
                    : "“\(input.vaultPath)” doesn't exist or can't be read. This usually means the folder was moved, renamed, or lives on a drive that isn't mounted.",
                suggestion: "Pick the vault folder again in Settings → General."
            ))
        }

        if !input.destinationAuthorized {
            findings.append(Finding(
                severity: .critical,
                title: "No access to \(input.destinationName)",
                detail: "Remindian can't read or write \(input.destinationName), so nothing can sync.",
                suggestion: "Grant access in System Settings → Privacy & Security, then sync again."
            ))
        }

        // --- Things that work, but silently do nothing ---

        if !input.missingWhitelistFolders.isEmpty {
            let names = input.missingWhitelistFolders.map { "“\($0)”" }.joined(separator: ", ")
            findings.append(Finding(
                severity: .warning,
                title: input.missingWhitelistFolders.count == 1
                    ? "A folder in “Only scan” doesn't exist"
                    : "\(input.missingWhitelistFolders.count) folders in “Only scan” don't exist",
                detail: "\(names) — nothing in \(input.missingWhitelistFolders.count == 1 ? "it" : "them") can be scanned. Folder names are matched relative to the vault root and are case-sensitive.",
                suggestion: "Check the spelling in Settings → Mappings → Only scan, or remove the entry."
            ))
        }

        let filter = input.globalFilter.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty, input.scannedTaskCount > 0, input.eligibleTaskCount == 0 {
            findings.append(Finding(
                severity: .critical,
                title: "The global filter matches no tasks",
                detail: "\(input.scannedTaskCount) task\(input.scannedTaskCount == 1 ? " was" : "s were") found in the vault, but none contain “\(filter)”, so nothing will sync. The filter is matched literally against the task line.",
                suggestion: "Check the exact text in Settings → Advanced, or clear the filter to sync every task."
            ))
        }

        if input.vaultPathExists, input.scannedTaskCount == 0 {
            findings.append(Finding(
                severity: .warning,
                title: "No tasks found in the vault",
                detail: "The scan completed but found no tasks. That's expected for an empty vault — otherwise the folder filters or the task format may not match what's in your notes.",
                suggestion: "Check Settings → Mappings → Only scan / Exclude, and that your tasks use checkbox lines."
            ))
        }

        // --- Things that are about to change your data ---

        if !input.pendingDeletionTitles.isEmpty {
            let count = input.pendingDeletionTitles.count
            let sample = input.pendingDeletionTitles.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            let more = count > 5 ? "\n…and \(count - 5) more." : ""
            findings.append(Finding(
                severity: count >= 10 ? .critical : .warning,
                title: "\(count) reminder\(count == 1 ? "" : "s") would be deleted",
                detail: "The next sync would remove \(count == 1 ? "this item" : "these items") from \(input.destinationName), because the matching task is no longer in the synced set:\n\(sample)\(more)\n\nThat's normal after deleting tasks in Obsidian — but a large number usually means the scan narrowed (a folder filter, a due-date horizon, or a moved vault).",
                suggestion: "If that isn't what you expect, widen the filters before syncing. Preview Changes shows the full list."
            ))
        }

        // --- Things worth knowing ---

        if input.unresolvedConflictCount > 0 {
            findings.append(Finding(
                severity: .warning,
                title: "\(input.unresolvedConflictCount) unresolved conflict\(input.unresolvedConflictCount == 1 ? "" : "s")",
                detail: "The same task changed on both sides since the last sync, so Remindian left it alone rather than guessing.",
                suggestion: "Resolve them from the menu bar, or set a conflict-resolution rule in Settings → Advanced."
            ))
        }

        if input.lastSyncErrorCount > 0 {
            findings.append(Finding(
                severity: .warning,
                title: "The last sync reported \(input.lastSyncErrorCount) error\(input.lastSyncErrorCount == 1 ? "" : "s")",
                detail: "Some items couldn't be written. The sync history has the details for each one.",
                suggestion: "Open Sync History to see which tasks failed and why."
            ))
        }

        if input.inboxOutsideWhitelist {
            findings.append(Finding(
                severity: .info,
                title: "Your inbox sits outside the scanned folders",
                detail: "“\(input.inboxRelativePath)” isn't inside the folders listed in “Only scan”. Remindian always scans it anyway — otherwise tasks it writes there would look deleted on the next scan and their reminders would be removed.",
                suggestion: nil
            ))
        }

        if input.vaultPathExists, input.mappingCount == 0, input.scannedTaskCount > 0 {
            findings.append(Finding(
                severity: .info,
                title: "No list mappings configured",
                detail: "Every task goes to the default list. Add tag, file, or folder mappings if you want tasks routed to different lists.",
                suggestion: nil
            ))
        }

        if input.isDryRun {
            findings.append(Finding(
                severity: .info,
                title: "Dry-run mode is on",
                detail: "Syncs are simulated and nothing is written to \(input.destinationName) or your vault.",
                suggestion: "Turn it off in Settings → Advanced when you're ready to sync for real."
            ))
        }

        // Most severe first, stable within a severity.
        let ordered = findings.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
        return Report(findings: ordered)
    }
}
