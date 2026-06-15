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
/// extracted. Recurrence phrases — English ("every 2 weeks", "weekly") and
/// French ("tous les mois", "hebdomadaire") — become an Obsidian Tasks
/// `🔁 every …` rule that round-trips all the way to a repeating Apple Reminder.
/// Everything left over is the title. Pure and deterministic given a reference
/// date — no side effects.
struct QuickAddParser {

    private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let priorityRegex = try! NSRegularExpression(pattern: "(?:^|\\s)(!{1,3})(?=\\s|$)", options: [])
    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)(#[\\p{L}0-9_][\\p{L}0-9_/-]*)", options: [])

    // Recurrence — interval form: "every [N] day|week|month|year" and the French
    // "tous les / toutes les / chaque [N] jour|semaine|mois|an|année". Group 1 =
    // optional count, group 2 = unit (EN or FR). Day-of-week rules ("every
    // monday") are intentionally out of scope: the recurrence engine only
    // advances day/week/month/year intervals, so anything else wouldn't recur
    // correctly downstream.
    private static let recurrenceIntervalRegex = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:every|each|tous les|toutes les|chaque)\\s+(?:(\\d+)\\s+)?(days?|weeks?|months?|years?|jours?|semaines?|mois|ans?|ann[eé]es?)(?=\\s|$)",
        options: [.caseInsensitive])

    // Recurrence — single-word adverbs in English and French.
    private static let recurrenceAdverbRegex = try! NSRegularExpression(
        pattern: "(?:^|\\s)(everyday|daily|weekly|monthly|yearly|annually|quotidiennement|quotidiennes?|quotidiens?|hebdomadaires?|hebdo|mensuelles?|mensuels?|mensuellement|annuelles?|annuels?|annuellement)(?=\\s|$)",
        options: [.caseInsensitive])

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

        // 3) Recurrence — extract BEFORE date detection so phrases like "every 2
        //    weeks" aren't half-eaten by NSDataDetector as a relative date.
        let recurrenceRule = extractRecurrence(from: &working)

        // 4) Date — first detected date phrase; remove it from the title.
        var dueDate: Date?
        if let detector = dateDetector {
            let ns = working as NSString
            let matches = detector.matches(in: working, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first {
                dueDate = first.date
                if let r = Range(first.range, in: working) { working.removeSubrange(r) }
            }
        }

        // 5) Title = what's left, whitespace-collapsed.
        let title = working
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SyncTask(
            title: title.isEmpty ? input.trimmingCharacters(in: .whitespaces) : title,
            isCompleted: false,
            priority: priority,
            dueDate: dueDate,
            tags: tags,
            targetList: tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 },
            recurrenceRule: recurrenceRule
        )
    }

    // MARK: - Recurrence

    /// Extract a recurrence phrase, returning a normalized Obsidian Tasks rule
    /// ("every day" / "every 2 weeks") and removing the matched text from
    /// `working`. Interval phrases ("every 2 weeks") win over bare adverbs
    /// ("weekly"). Returns nil when no recurrence is present.
    static func extractRecurrence(from working: inout String) -> String? {
        let full = NSRange(working.startIndex..., in: working)
        if let m = recurrenceIntervalRegex.firstMatch(in: working, range: full),
           let unitRange = Range(m.range(at: 2), in: working),
           let unit = normalizedUnit(String(working[unitRange])) {
            var interval = 1
            if let nRange = Range(m.range(at: 1), in: working), let n = Int(working[nRange]), n > 0 {
                interval = n
            }
            if let whole = Range(m.range, in: working) { working.removeSubrange(whole) }
            return rule(unit: unit, interval: interval)
        }

        let full2 = NSRange(working.startIndex..., in: working)
        if let m = recurrenceAdverbRegex.firstMatch(in: working, range: full2),
           let advRange = Range(m.range(at: 1), in: working),
           let unit = unitForAdverb(String(working[advRange])) {
            if let whole = Range(m.range, in: working) { working.removeSubrange(whole) }
            return rule(unit: unit, interval: 1)
        }
        return nil
    }

    /// EN/FR unit word → canonical singular English unit.
    private static func normalizedUnit(_ raw: String) -> String? {
        let u = raw.lowercased()
        if u.hasPrefix("day") || u.hasPrefix("jour") { return "day" }
        if u.hasPrefix("week") || u.hasPrefix("semaine") { return "week" }
        if u == "mois" || u.hasPrefix("month") { return "month" }
        if u.hasPrefix("year") || u.hasPrefix("an") || u.hasPrefix("ann") { return "year" }
        return nil
    }

    /// EN/FR adverb → canonical unit.
    private static func unitForAdverb(_ raw: String) -> String? {
        let a = raw.lowercased()
        if a == "everyday" || a == "daily" || a.hasPrefix("quotidien") { return "day" }
        if a == "weekly" || a.hasPrefix("hebdo") { return "week" }
        if a == "monthly" || a.hasPrefix("mensuel") { return "month" }
        if a == "yearly" || a == "annually" || a.hasPrefix("annuel") { return "year" }
        return nil
    }

    /// Build the Obsidian Tasks rule text. Singular for interval 1 ("every
    /// week"), plural with the count otherwise ("every 2 weeks").
    private static func rule(unit: String, interval: Int) -> String {
        interval <= 1 ? "every \(unit)" : "every \(interval) \(unit)s"
    }
}
