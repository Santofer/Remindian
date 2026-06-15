import Foundation
import EventKit

/// Unified task model that bridges Obsidian Tasks and Apple Reminders
struct SyncTask: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var isCompleted: Bool
    var priority: Priority
    var dueDate: Date?
    var startDate: Date?
    var scheduledDate: Date?
    var completedDate: Date?
    var tags: [String]
    var targetList: String? // The hashtag that determines which Reminders list to use
    var notes: String?
    var clientName: String? // Extracted from hierarchical tags (e.g., work/clients/somfy → "somfy") or file path

    /// Raw recurrence rule text preserved from the Obsidian line, e.g. "every week",
    /// "every month on the 1st when done", or "🔁 every 2 weeks". Nil if the task is
    /// not recurring. Used to (a) disambiguate the completed + new-uncompleted pair
    /// the Obsidian Tasks plugin produces on each occurrence completion, and (b) in
    /// a future phase, to read/write EKRecurrenceRule on the Reminders side. (#57)
    var recurrenceRule: String?

    // Source tracking for sync
    var obsidianSource: ObsidianSource?
    var remindersId: String?
    var lastModified: Date
    var url: URL?  // The URL field (e.g., obsidian:// link)
    
    enum Priority: Int, Codable, CaseIterable {
        case none = 0
        case low = 1
        case medium = 5
        case high = 9
        
        var obsidianEmoji: String {
            switch self {
            case .none: return ""
            case .low: return "🔽"
            case .medium: return "🔼"
            case .high: return "⏫"
            }
        }
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
        
        /// Convert from Apple Reminders priority (0 = none, 1-4 = high, 5 = medium, 6-9 = low)
        static func fromReminders(_ priority: Int) -> Priority {
            switch priority {
            case 0: return .none
            case 1...4: return .high
            case 5: return .medium
            case 6...9: return .low
            default: return .none
            }
        }
        
        /// Convert to Apple Reminders priority
        var toRemindersPriority: Int {
            switch self {
            case .none: return 0
            case .low: return 9
            case .medium: return 5
            case .high: return 1
            }
        }
    }
    
    struct ObsidianSource: Equatable, Codable {
        let filePath: String
        let lineNumber: Int
        let originalLine: String
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        priority: Priority = .none,
        dueDate: Date? = nil,
        startDate: Date? = nil,
        scheduledDate: Date? = nil,
        completedDate: Date? = nil,
        tags: [String] = [],
        targetList: String? = nil,
        notes: String? = nil,
        clientName: String? = nil,
        obsidianSource: ObsidianSource? = nil,
        remindersId: String? = nil,
        lastModified: Date = Date(),
        url: URL? = nil,
        recurrenceRule: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.priority = priority
        self.dueDate = dueDate
        self.startDate = startDate
        self.scheduledDate = scheduledDate
        self.completedDate = completedDate
        self.tags = tags
        self.targetList = targetList
        self.notes = notes
        self.clientName = clientName
        self.obsidianSource = obsidianSource
        self.remindersId = remindersId
        self.lastModified = lastModified
        self.url = url
        self.recurrenceRule = recurrenceRule
    }
}

// MARK: - Obsidian Tasks Format Parsing

extension SyncTask {
    /// Pre-compiled regexes for the per-line parser.
    ///
    /// `NSRegularExpression(pattern:)` builds an NFA on every call — cheap once,
    /// but `fromObsidianLine` runs once per task line, and the old code compiled
    /// ~13 patterns per call. On a 10k-task vault that's ~130k compilations.
    /// Hoisting them to `static let` compiles each pattern exactly once
    /// (Swift static-let init is lazy + thread-safe). Behavior is identical —
    /// same patterns, same options. (perf)
    ///
    /// Patterns here are compile-time constants, so `try!` is appropriate: a
    /// malformed pattern is a programmer error that surfaces immediately on
    /// first access (and is caught by the test suite).
    enum Rx {
        static func make(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            return try! NSRegularExpression(pattern: pattern, options: options)
        }

        // Priority emojis (with optional FE0F variation selector). Order is
        // high → medium → low (first match wins, matching the old loop).
        static let priority: [(level: Priority, regex: NSRegularExpression)] = [
            (.high, make("⏫\u{FE0F}?")),
            (.medium, make("🔼\u{FE0F}?")),
            (.low, make("🔽\u{FE0F}?")),
        ]

        // Recurrence emoji — capture the rule text (emoji + trailing run up to
        // the next metadata emoji or tag). Order 🔁 then 🔂.
        static let recurrenceEmojiCapture: [NSRegularExpression] = [
            make("🔁\u{FE0F}?\\s*[^📅🛫⏳✅⏫🔼🔽#]*"),
            make("🔂\u{FE0F}?\\s*[^📅🛫⏳✅⏫🔼🔽#]*"),
        ]

        // Recurrence emoji — bare emoji only, used when stripping the rule from
        // the title (everything after the emoji is removed by the caller).
        static let recurrenceEmojiBare: [NSRegularExpression] = [
            make("🔁\u{FE0F}?"),
            make("🔂\u{FE0F}?"),
        ]

        // Plain-text recurrence — capture form (full month names + intervals).
        static let plainRecurrenceCapture = make(
            "\\bevery\\s+(?:month|week|day|year|other|january|february|march|april|may|june|july|august|september|october|november|december|\\d+\\s+days?)\\b[^📅🛫⏳✅⏫🔼🔽#]*",
            [.caseInsensitive]
        )

        // Plain-text recurrence — title-strip form (greedy to end of line).
        static let plainRecurrenceStrip = make(
            "\\bevery\\s+(?:month|week|day|year|other|\\d+\\s+days?)\\b.*?(?:when done)?.*$",
            [.caseInsensitive]
        )

        // Tag / list token (supports hierarchical #a/b/c and +prefix).
        static let tag = make("[#+][\\w-]+(?:/[\\w-]+)*")

        // Date fields, keyed by emoji. Group 1 = yyyy-MM-dd, optional group 2 =
        // HH:mm (separated by a space or `T`). The time is non-standard for the
        // Obsidian Tasks plugin but harmless to capture — it only reaches the
        // destination when "Include time in due dates" is on (#6). (multi-profile)
        static let dateByEmoji: [String: NSRegularExpression] = [
            "📅": make("📅\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})(?:[ T](\\d{1,2}:\\d{2}))?"),
            "🛫": make("🛫\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})(?:[ T](\\d{1,2}:\\d{2}))?"),
            "⏳": make("⏳\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})(?:[ T](\\d{1,2}:\\d{2}))?"),
            "✅": make("✅\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})"),
        ]

        // Protected ranges for tag extraction (#65).
        static let url = make("https?://[^\\s)\\]]+")
        static let wikilink = make("\\[\\[[^\\]]*\\]\\]")
        static let codeSpan = make("`[^`]*`")

        // Dataview inline fields (#41).
        static let dataviewField = make("[\\[\\(]([\\w-]+)::\\s*([^\\]\\)]+)[\\]\\)]")
        static let dataviewClean = make("\\s*[\\[\\(][\\w-]+::\\s*[^\\]\\)]+[\\]\\)]")
    }

    /// Default open-status markers (the bracket content of `- [ ]`).
    static let defaultOpenMarkers: Set<Character> = [" "]

    /// Default completed-status markers (the bracket content of `- [x]` / `- [X]`).
    static let defaultCompletedMarkers: Set<Character> = ["x", "X"]

    /// Extract the checkbox from a trimmed task line.
    ///
    /// Recognizes any single character in the bracket (e.g. `- [ ]`, `- [x]`,
    /// `- [/]`, `- [<]`, `- [-]`) followed by a space. Returns `nil` for
    /// non-task lines, including wikilinks like `- [[Name]]` (caught by the
    /// `[[` prefix check) and lines that don't start with `- [`.
    ///
    /// Used by `fromObsidianLine` and by surgical-edit code paths in
    /// `ObsidianService` so we have one source of truth for what counts as a
    /// task checkbox. Backwards-compatible: when called without explicit
    /// marker sets the default `[" "]` open / `["x", "X"]` completed
    /// classification matches v5.8.x behavior exactly. (#63)
    static func extractCheckbox(from trimmed: String) -> (marker: Character, content: String)? {
        // Reject wikilinks explicitly — `- [[Name]]` has `[` as marker but is
        // not a task. The trailing `]] ` would match the regex below.
        guard !trimmed.hasPrefix("- [[") else { return nil }

        // Match `- [.] ` where `.` is any single character. Anchored at start.
        guard trimmed.count >= 6,
              trimmed.hasPrefix("- ["),
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "]",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)] == " "
        else { return nil }

        let marker = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)]
        let content = String(trimmed.dropFirst(6))
        return (marker, content)
    }

    /// The stable identity of a task *line*, used to relocate the task after the
    /// file has drifted since the last scan — lines inserted/removed/reordered,
    /// or the task completed (so its line moved and/or gained a ✅ date) between
    /// the menu snapshot and the moment the user acts on it.
    ///
    /// Strips the list marker + checkbox state and any completion-date suffix
    /// (`✅ YYYY-MM-DD`, optional FE0F variation selector), so the **open** and
    /// **completed** forms of the same task — and the same task at a different
    /// line number — collapse to one identity. Returns "" for non-task lines.
    ///
    /// Note: due/scheduled/start dates and the 🔁 recurrence rule are *kept* —
    /// they're part of the task's identity. This means a recurring task's next
    /// occurrence (which carries an advanced 📅 date) does NOT collide with the
    /// just-completed instance, so relocation never confuses the two. (#75-followup)
    static func taskIdentityBody(of rawLine: String) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard let (_, content) = extractCheckbox(from: trimmed) else { return "" }
        let withoutDone = content.replacingOccurrences(
            of: "\\s*\u{2705}\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}",
            with: "", options: .regularExpression
        )
        return withoutDone.trimmingCharacters(in: .whitespaces)
    }

    /// Parse an Obsidian Tasks format line
    /// Format: - [x] Task title 📅 2024-01-15 🛫 2024-01-10 ⏫ #list-name #tag1 🔁 every week
    /// We parse EVERYTHING from Obsidian but may truncate for Reminders display
    ///
    /// - Parameters:
    ///   - openMarkers: Single characters that count as "open / not done" inside
    ///     the checkbox. Defaults to `[" "]` for backwards compatibility. The
    ///     Obsidian Tasks plugin and extensions like Task-Board introduce
    ///     additional markers (`[/]` in progress, `[?]` waiting, `[<]` ready);
    ///     callers can opt in by passing them here. (#63)
    ///   - completedMarkers: Single characters that count as "done / completed".
    ///     Defaults to `["x", "X"]`. Callers can map cancelled (`[-]`) here too.
    ///   - ignoredMarkers: Single characters that mean "this isn't a task at
    ///     all — skip the entire line". Returns `nil` when the checkbox
    ///     marker is in this set. Used by patterns like `[i]` for
    ///     informational entries that shouldn't sync to reminders (#70).
    ///     Defaults to empty — back-compat with pre-v5.10.1 callers.
    ///     If a marker is in both ignored and open/completed, ignored wins.
    static func fromObsidianLine(
        _ line: String,
        filePath: String,
        lineNumber: Int,
        openMarkers: Set<Character> = defaultOpenMarkers,
        completedMarkers: Set<Character> = defaultCompletedMarkers,
        ignoredMarkers: Set<Character> = []
    ) -> SyncTask? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Use the shared checkbox extractor so the rules stay consistent with
        // surgical-edit code (markTaskComplete, etc.). (#63)
        guard let checkbox = extractCheckbox(from: trimmed) else { return nil }

        // Ignored takes priority over everything else. Treats the line as a
        // non-task — scanner won't see it, sync won't touch it. (#70)
        if ignoredMarkers.contains(checkbox.marker) { return nil }

        // Classify the marker. Unknown markers fall through to "open" — this
        // is the safe choice (we'd rather show an unknown-status task than
        // silently treat it as done and never sync it again).
        let isCompleted: Bool
        if completedMarkers.contains(checkbox.marker) {
            isCompleted = true
        } else if openMarkers.contains(checkbox.marker) {
            isCompleted = false
        } else {
            isCompleted = false
        }

        var content = checkbox.content
        
        // Parse dates with emojis
        let dueDate = extractDate(from: &content, emoji: "📅")
        let startDate = extractDate(from: &content, emoji: "🛫")
        let scheduledDate = extractDate(from: &content, emoji: "⏳")
        let completedDate = extractDate(from: &content, emoji: "✅")
        
        // Parse priority (handle optional FE0F variation selector)
        var priority: Priority = .none
        for (level, regex) in Rx.priority {
            let nsRange = NSRange(content.startIndex..., in: content)
            if let match = regex.firstMatch(in: content, options: [], range: nsRange),
               let matchRange = Range(match.range, in: content) {
                priority = level
                content.removeSubrange(matchRange)
                break
            }
        }
        
        // Extract recurrence rule — capture the rule text (for #57 recurring-task
        // handling) and strip it from content before tag/title parsing.
        //
        // The Obsidian Tasks plugin stores recurrence as either:
        //   Case 1: Emoji-prefixed — `🔁 every week`, `🔂 every 2 days when done`
        //   Case 2: Plain-text     — `every month on the 1st when done`
        //
        // We capture the first match of either case. The captured text is stored
        // verbatim on `SyncTask.recurrenceRule` and also signals that this task
        // needs line-number-aware ID generation (so completed + new-uncompleted
        // copies don't collide on the same obsidianId).
        var recurrenceRule: String? = nil

        // Case 1: emoji-based
        for recRegex in Rx.recurrenceEmojiCapture {
            let recRange = NSRange(content.startIndex..., in: content)
            if let match = recRegex.firstMatch(in: content, options: [], range: recRange),
               let matchRange = Range(match.range, in: content) {
                let captured = String(content[matchRange]).trimmingCharacters(in: .whitespaces)
                if !captured.isEmpty {
                    recurrenceRule = captured
                }
            }
            content = recRegex.stringByReplacingMatches(in: content, options: [], range: recRange, withTemplate: "")
        }

        // Case 2: plain-text (only consider if emoji case didn't hit)
        do {
            let plainRecRegex = Rx.plainRecurrenceCapture
            let recRange = NSRange(content.startIndex..., in: content)
            if recurrenceRule == nil,
               let match = plainRecRegex.firstMatch(in: content, options: [], range: recRange),
               let matchRange = Range(match.range, in: content) {
                let captured = String(content[matchRange]).trimmingCharacters(in: .whitespaces)
                if !captured.isEmpty {
                    recurrenceRule = captured
                }
            }
            content = plainRecRegex.stringByReplacingMatches(in: content, options: [], range: recRange, withTemplate: "")
        }

        // Parse tags and find target list.
        //
        // Supports hierarchical tags like #work/clients/somfy and +prefix tags
        // like +Project (#14). The full hierarchical path is preserved in the
        // `tags` array verbatim — the first segment is also extracted into
        // `targetList` for list-routing convenience. Resolution of the full
        // hierarchical mapping lives in `SyncConfiguration.resolveTargetList`.
        //
        // BEFORE matching tags, we compute "protected ranges" — substrings
        // of the line where tag-like patterns must be ignored: URLs (so
        // `#section` inside `https://example.com/#section` doesn't become a
        // tag, #65), wikilinks (so `[[Note#header]]` doesn't either), and
        // inline code spans. Tag matches whose start position falls inside
        // any protected range are dropped.
        var tags: [String] = []
        var targetList: String? = nil
        let protectedRanges = computeProtectedRanges(in: content)
        let tagRegex = Rx.tag
        let range = NSRange(content.startIndex..., in: content)

        do {
            let matches = tagRegex.matches(in: content, options: [], range: range)
            for match in matches {
                // Drop matches that overlap any protected range.
                let isProtected = protectedRanges.contains { protected in
                    NSIntersectionRange(match.range, protected).length > 0
                }
                if isProtected { continue }

                if let tagRange = Range(match.range, in: content) {
                    let tag = String(content[tagRange])
                    tags.append(tag)

                    // First top-level tag becomes the target list (convention)
                    // For "#work/clients/somfy", the target list is "work"
                    // For "+Project", the target list is "Project"
                    if targetList == nil {
                        let tagContent = String(tag.dropFirst()) // Remove # or +
                        if tagContent.contains("/") {
                            targetList = String(tagContent.split(separator: "/").first ?? Substring(tagContent))
                        } else {
                            targetList = tagContent
                        }
                    }
                }
            }
        }

        // Remove tags from content for clean title
        var title = content
        for tag in tags {
            title = title.replacingOccurrences(of: tag, with: "")
        }
        
        // Remove recurrence info from title
        // Case 1: 🔁/🔂 emoji (with optional FE0F variation selector) and everything after
        var recurrenceStripped = false
        for regex in Rx.recurrenceEmojiBare {
            let nsRange = NSRange(title.startIndex..., in: title)
            if let match = regex.firstMatch(in: title, options: [], range: nsRange),
               let matchRange = Range(match.range, in: title) {
                title = String(title[..<matchRange.lowerBound])
                recurrenceStripped = true
                break
            }
        }

        // Case 2: Plain-text recurrence rules without emoji
        // Matches patterns like "every month on the 1st when done", "every week", "every 90 days when done"
        if !recurrenceStripped {
            let regex = Rx.plainRecurrenceStrip
            let nsRange = NSRange(title.startIndex..., in: title)
            if let match = regex.firstMatch(in: title, options: [], range: nsRange),
               let matchRange = Range(match.range, in: title) {
                title = String(title[..<matchRange.lowerBound])
            }
        }
        
        title = title.trimmingCharacters(in: .whitespaces)
        
        // Clean up multiple spaces
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }
        
        guard !title.isEmpty else { return nil }

        // clientName is set later by ObsidianService from the note's YAML frontmatter
        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: priority,
            dueDate: dueDate,
            startDate: startDate,
            scheduledDate: scheduledDate,
            completedDate: completedDate,
            tags: tags,
            targetList: targetList,
            obsidianSource: ObsidianSource(
                filePath: filePath,
                lineNumber: lineNumber,
                originalLine: line
            ),
            recurrenceRule: recurrenceRule
        )
    }
    
    /// Parse dataview inline fields from a task line and merge into existing SyncTask.
    /// Format: `- [x] Task title [due::2024-01-15] [priority::high] [project::Shopping] [tags::work, urgent]`
    /// Also supports parenthetical syntax: `(due::2024-01-15)`
    /// This is called after `fromObsidianLine` to augment with any dataview fields found.
    static func parseDataviewFields(from line: String, into task: inout SyncTask) {
        // Match both [key::value] and (key::value) patterns
        let regex = Rx.dataviewField
        let nsRange = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, options: [], range: nsRange)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }

            let key = String(line[keyRange]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "due", "due_date", "duedate":
                if task.dueDate == nil, let date = dateFormatter.date(from: value) {
                    task.dueDate = date
                }
            case "start", "start_date", "startdate", "scheduled":
                if task.startDate == nil, let date = dateFormatter.date(from: value) {
                    task.startDate = date
                }
            case "scheduled_date", "scheduleddate":
                if task.scheduledDate == nil, let date = dateFormatter.date(from: value) {
                    task.scheduledDate = date
                }
            case "completed", "completion", "completed_date", "done":
                if task.completedDate == nil, let date = dateFormatter.date(from: value) {
                    task.completedDate = date
                }
            case "priority":
                if task.priority == .none {
                    switch value.lowercased() {
                    case "high", "highest", "1", "critical":
                        task.priority = .high
                    case "medium", "2", "normal":
                        task.priority = .medium
                    case "low", "lowest", "3":
                        task.priority = .low
                    default:
                        break
                    }
                }
            case "tags", "tag":
                // Parse comma-separated tags: "work, urgent" or "work"
                let dvTags = value.split(separator: ",").map { tag -> String in
                    let cleaned = tag.trimmingCharacters(in: .whitespaces)
                    return cleaned.hasPrefix("#") ? cleaned : "#\(cleaned)"
                }
                for dvTag in dvTags {
                    if !task.tags.contains(dvTag) {
                        task.tags.append(dvTag)
                    }
                }
                // Use first new tag as target list if not already set
                if task.targetList == nil, let firstTag = dvTags.first {
                    let tagContent = String(firstTag.dropFirst())
                    task.targetList = tagContent.contains("/")
                        ? String(tagContent.split(separator: "/").first ?? Substring(tagContent))
                        : tagContent
                }
            case "project", "list":
                // Directly set target list from project/list field
                if task.targetList == nil {
                    // Strip wikilink syntax [[Project Name]] → Project Name
                    let cleanValue = value
                        .replacingOccurrences(of: "[[", with: "")
                        .replacingOccurrences(of: "]]", with: "")
                    task.targetList = cleanValue
                }
            default:
                break
            }
        }

        // Clean dataview fields from the title
        let cleanRegex = Rx.dataviewClean
        let titleRange = NSRange(task.title.startIndex..., in: task.title)
        task.title = cleanRegex.stringByReplacingMatches(in: task.title, range: titleRange, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Convert task back to Obsidian Tasks format
    func toObsidianLine() -> String {
        var parts: [String] = []
        
        // Checkbox
        let checkbox = isCompleted ? "- [x]" : "- [ ]"
        parts.append(checkbox)
        
        // Title
        parts.append(title)
        
        // Priority emoji
        if priority != .none {
            parts.append(priority.obsidianEmoji)
        }
        
        // Start date
        if let startDate = startDate {
            parts.append("🛫 \(formatDate(startDate))")
        }
        
        // Scheduled date
        if let scheduledDate = scheduledDate {
            parts.append("⏳ \(formatDate(scheduledDate))")
        }
        
        // Due date
        if let dueDate = dueDate {
            parts.append("📅 \(formatDate(dueDate))")
        }
        
        // Completed date
        if let completedDate = completedDate, isCompleted {
            parts.append("✅ \(formatDate(completedDate))")
        }
        
        // Add tags - targetList is already in tags if it was parsed from Obsidian
        // Only add targetList as tag if it's not already in the tags array
        var allTags = tags
        if let targetList = targetList {
            let targetTag = "#\(targetList)"
            if !allTags.contains(targetTag) && !allTags.contains(where: { $0.lowercased() == targetTag.lowercased() }) {
                allTags.insert(targetTag, at: 0)
            }
        }
        
        // Add all unique tags
        for tag in allTags {
            if !parts.contains(tag) {
                parts.append(tag)
            }
        }
        
        return parts.joined(separator: " ")
    }
    
    // MARK: - Helper Methods
    
    private static func extractDate(from content: inout String, emoji: String) -> Date? {
        // Use the pre-compiled regex for this emoji; fall back to compiling on
        // the fly for any caller that passes an emoji outside the known four
        // (none today, but keeps the helper self-contained). (perf)
        let regex: NSRegularExpression
        if let cached = Rx.dateByEmoji[emoji] {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(
                pattern: "\(emoji)\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})(?:[ T](\\d{1,2}:\\d{2}))?", options: []
            ) else { return nil }
            regex = compiled
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              let dateRange = Range(match.range(at: 1), in: content) else { return nil }

        let dateString = String(content[dateRange])

        // Optional time component (group 2), e.g. "📅 2026-03-15 14:30".
        var timeString: String?
        if match.numberOfRanges > 2, let timeRange = Range(match.range(at: 2), in: content) {
            timeString = String(content[timeRange])
        }

        // Remove the matched portion from content
        if let fullRange = Range(match.range, in: content) {
            content.removeSubrange(fullRange)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let time = timeString {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            if let dated = formatter.date(from: "\(dateString) \(time)") { return dated }
            // Fall through to date-only if the time failed to parse.
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Compute substrings of `content` that must be treated as opaque during
    /// tag extraction. A tag-regex match whose start position falls inside
    /// one of these ranges is dropped on the floor. (#65)
    ///
    /// Covers:
    /// - HTTP/HTTPS URLs — stops at whitespace, `)`, or `]` so we handle bare
    ///   URLs, Markdown links `[label](url)`, and trailing punctuation cleanly.
    /// - Wikilinks `[[…]]` — header anchors like `#section` inside wikilinks
    ///   were the secondary source of false-positive tags.
    /// - Inline code spans `` `…` `` — defensive coverage for documentation
    ///   that mentions tags like `` `#deprecated` ``.
    ///
    /// Returns an array of `NSRange`. Empty if the content has none.
    static func computeProtectedRanges(in content: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsRange = NSRange(content.startIndex..., in: content)

        // URLs. The `[^\s)\]]+` body intentionally stops at whitespace, `)`
        // (closes a Markdown link), and `]` (closes a wikilink's outer
        // brackets if the URL is somehow inside one). Trailing punctuation
        // like `.,;` is included in the URL — fine, since we only need
        // start-position protection for tag matches, not exact URL bounds.
        ranges.append(contentsOf: Rx.url.matches(in: content, options: [], range: nsRange).map(\.range))

        // Wikilinks. `[[anything-not-containing-]]]` — minimal but correct
        // for our purpose (we only care that the header `#section` inside
        // doesn't escape).
        ranges.append(contentsOf: Rx.wikilink.matches(in: content, options: [], range: nsRange).map(\.range))

        // Inline code spans. Single backticks; we don't need to handle the
        // pathological double-backtick case for our purposes.
        ranges.append(contentsOf: Rx.codeSpan.matches(in: content, options: [], range: nsRange).map(\.range))

        return ranges
    }
}

// MARK: - EKReminder Conversion

extension SyncTask {
    /// Create SyncTask from Apple Reminder
    static func fromReminder(_ reminder: EKReminder, listName: String) -> SyncTask {
        var tags: [String] = []
        
        // Parse tags from notes if present (supports both # and + prefixes)
        if let notes = reminder.notes {
            let range = NSRange(notes.startIndex..., in: notes)
            do {
                let matches = Rx.tag.matches(in: notes, options: [], range: range)
                for match in matches {
                    if let tagRange = Range(match.range, in: notes) {
                        tags.append(String(notes[tagRange]))
                    }
                }
            }
        }
        
        // Get start date from reminder's start date component
        var startDate: Date? = nil
        if let startComponents = reminder.startDateComponents {
            startDate = Calendar.current.date(from: startComponents)
        }
        
        // Read the first EKRecurrenceRule and convert to Obsidian-format rule
        // string. Phase B (#57): lets recurring reminders originating in Apple
        // Reminders propagate their rule into Obsidian on writeback.
        let recurrenceRule: String? = {
            guard let rule = reminder.recurrenceRules?.first else { return nil }
            return RecurrenceConverter.format(rule: rule)
        }()

        return SyncTask(
            title: reminder.title ?? "Untitled",
            isCompleted: reminder.isCompleted,
            priority: Priority.fromReminders(Int(reminder.priority)),
            dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
            startDate: startDate,
            completedDate: reminder.completionDate,
            tags: tags,
            targetList: listName,
            notes: reminder.notes,
            remindersId: reminder.calendarItemIdentifier,
            lastModified: reminder.lastModifiedDate ?? Date(),
            url: reminder.url,
            recurrenceRule: recurrenceRule
        )
    }
    
    /// Apply task properties to an EKReminder.
    /// Title is clean (no hashtags). Client name added in notes for work tasks.
    /// - Parameter appendLinkToNotes: When `true` AND `addTaskLink` is also
    ///   true, the obsidian:// URL is appended to the reminder's notes body
    ///   *in addition to* being set on `reminder.url`. Defaults to `false` to
    ///   match the v5.10+ clean-notes behavior — Apple Reminders renders the
    ///   URL field as a clickable icon, so the notes-side copy was just
    ///   visual clutter (#69). Older clients that don't surface the URL
    ///   field can opt back in via the corresponding Settings toggle.
    /// Compute when a reminder's alarm should fire for a given due date. (#6)
    ///
    /// If the due date carries a real time-of-day (and time sync is on), the
    /// alarm fires at that exact moment. Otherwise (an all-day due) it fires at
    /// `allDayHour:00` on the due day so the user still gets a notification
    /// instead of a silent all-day reminder. Pure + testable.
    static func alarmFireDate(due: Date, includeTime: Bool, allDayHour: Int, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.hour, .minute], from: due)
        let hasTimeOfDay = includeTime && ((comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0)
        if hasTimeOfDay { return due }
        let hour = max(0, min(23, allDayHour))
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: due) ?? due
    }

    func applyToReminder(_ reminder: EKReminder, includeDueTime: Bool = false, addTaskLink: Bool = false, vaultPath: String = "", appendLinkToNotes: Bool = false, addReminderAlarm: Bool = false, allDayAlarmHour: Int = 9) {
        reminder.title = title
        reminder.isCompleted = isCompleted
        reminder.priority = priority.toRemindersPriority

        if let dueDate = dueDate {
            if includeDueTime {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            } else {
                // Only date, no time - this creates an all-day reminder
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            }
        } else {
            reminder.dueDateComponents = nil
        }

        if let startDate = startDate {
            if includeDueTime {
                reminder.startDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: startDate)
            } else {
                reminder.startDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: startDate)
            }
        } else {
            reminder.startDateComponents = nil
        }

        // Build notes: client name + tags + task link
        // (EventKit has no native tag API, so tags are stored in notes for visibility)
        var noteParts: [String] = []

        if let client = clientName, !client.isEmpty {
            noteParts.append("Client: \(client)")
        }

        if !tags.isEmpty {
            noteParts.append("Tags: \(tags.joined(separator: " "))")
        }

        // Add obsidian:// link to the reminder's URL field and notes
        if addTaskLink, let source = obsidianSource, !vaultPath.isEmpty {
            let vaultName = URL(fileURLWithPath: vaultPath).lastPathComponent
            let filePath = source.filePath.hasPrefix("/") ? String(source.filePath.dropFirst()) : source.filePath
            let encodedVault = vaultName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? vaultName
            let encodedFile = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
            let obsidianURL = "obsidian://open?vault=\(encodedVault)&file=\(encodedFile)"

            // Set the URL field (clickable in Reminders.app and GoodTask).
            // Apple Reminders surfaces this as a single clickable icon.
            reminder.url = URL(string: obsidianURL)

            // Optionally also append into notes as a fallback for older
            // clients that don't display the URL field. Opt-in since v5.10.0
            // (#69) — the historical default was always-append, which created
            // a long percent-encoded line of noise in every reminder.
            if appendLinkToNotes {
                noteParts.append(obsidianURL)
            }
        }

        if noteParts.isEmpty {
            reminder.notes = notes?.trimmingCharacters(in: .whitespaces)
        } else {
            reminder.notes = noteParts.joined(separator: "\n")
        }

        if isCompleted {
            reminder.completionDate = completedDate ?? Date()
        }

        // Alarm (#6) — opt-in. A synced reminder with a due date otherwise never
        // notifies the user. We only ADD an alarm when the reminder has none, so
        // we never duplicate on repeated syncs nor clobber a user-added alarm.
        // Completed reminders get no alarm.
        if addReminderAlarm, !isCompleted, let due = dueDate, (reminder.alarms?.isEmpty ?? true) {
            let fire = SyncTask.alarmFireDate(due: due, includeTime: includeDueTime, allDayHour: allDayAlarmHour)
            reminder.addAlarm(EKAlarm(absoluteDate: fire))
        }

        // Recurrence rule (#57 Phase B) — convert our preserved Obsidian-format
        // rule text into an EKRecurrenceRule and set it on the reminder. If the
        // rule string can't be parsed (unsupported grammar), clear any existing
        // rule rather than leaving stale state behind.
        if let ruleText = recurrenceRule, let rule = RecurrenceConverter.parse(ruleText: ruleText) {
            reminder.recurrenceRules = [rule]
        } else {
            // Drop any existing rules. (EventKit requires removing by instance.)
            if let existing = reminder.recurrenceRules {
                for r in existing { reminder.removeRecurrenceRule(r) }
            }
        }
    }
}
