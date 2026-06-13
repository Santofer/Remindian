import Foundation

/// Parses a free-text quick-add string into a `SyncTask`. (Shortcuts + quick-add)
///
/// Examples:
///   "Buy milk friday !!"        → title "Buy milk", due next Friday, medium
///   "Pay rent tomorrow #home !!!" → title "Pay rent", due tomorrow, #home, high
///   "Email Sam"                 → title "Email Sam"
///
/// Dates use `NSDataDetector` (the same engine Spotlight/Mail use) so natural
/// phrases like "tomorrow", "next monday", "Jan 20 3pm" work. Priority is
/// trailing/standalone `!` / `!!` / `!!!` (low / medium / high). `#tags` are
/// extracted. Everything left over is the title. Pure and deterministic given a
/// reference date — no side effects.
struct QuickAddParser {

    private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let priorityRegex = try! NSRegularExpression(pattern: "(?:^|\\s)(!{1,3})(?=\\s|$)", options: [])
    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)(#[\\p{L}0-9_][\\p{L}0-9_/-]*)", options: [])

    /// Parse `input` into a task. Relative date phrases ("tomorrow", "next
    /// monday") are resolved by `NSDataDetector` against the current calendar.
    static func parse(_ input: String) -> SyncTask {
        var working = input

        // 1) Priority — take the longest standalone run of '!'.
        var priority: SyncTask.Priority = .none
        if let m = priorityRegex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let bangRange = Range(m.range(at: 1), in: working) {
            switch working[bangRange].count {
            case 3: priority = .high
            case 2: priority = .medium
            default: priority = .low
            }
            if let whole = Range(m.range, in: working) { working.removeSubrange(whole) }
        }

        // 2) Tags.
        var tags: [String] = []
        while let m = tagRegex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)) {
            if let tagRange = Range(m.range(at: 1), in: working) {
                tags.append(String(working[tagRange]))
            }
            if let whole = Range(m.range, in: working) { working.removeSubrange(whole) } else { break }
        }

        // 3) Date — first detected date phrase; remove it from the title.
        var dueDate: Date?
        if let detector = dateDetector {
            let ns = working as NSString
            let matches = detector.matches(in: working, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first {
                dueDate = first.date
                if let r = Range(first.range, in: working) { working.removeSubrange(r) }
            }
        }

        // 4) Title = what's left, whitespace-collapsed.
        let title = working
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SyncTask(
            title: title.isEmpty ? input.trimmingCharacters(in: .whitespaces) : title,
            isCompleted: false,
            priority: priority,
            dueDate: dueDate,
            tags: tags,
            targetList: tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        )
    }
}
