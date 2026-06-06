import Foundation

/// A configurable plain-markdown task parser + surgical writer for the Generic
/// Markdown source (#27). Supports NotePlan and similar tools that put metadata
/// on the task line with a configurable prefix token (e.g. due `>2025-01-20`,
/// done `@done(2025-01-20)`, priority `!`/`!!`/`!!!`).
///
/// This is deliberately a SEPARATE implementation from the Obsidian-Tasks emoji
/// parser (`SyncTask.fromObsidianLine` / `ObsidianService`). The proven Obsidian
/// path is never touched, so adding dialect support carries zero regression risk
/// for existing users.
///
/// Design invariant (the thing the tests defend): parsing is the exact inverse
/// of writing for the fields this dialect supports — `parse(buildLine(task))`
/// reproduces the task. All edits are surgical: completion/incompletion only
/// touch the checkbox + done token; metadata edits replace/append/remove only
/// the targeted token, leaving the rest of the line byte-identical.
///
/// Supported: checkbox completion, due/start/scheduled dates, three priority
/// levels, `#tags`, and new-task line construction. Not supported in this
/// dialect: recurrence (varies too much between tools) — recurrenceRule is
/// always nil and recurring writeback is never emitted.
struct GenericMarkdownParser {

    // MARK: - Dialect (precompiled from config)

    let openMarkers: Set<Character>
    let completedMarkers: Set<Character>
    /// The marker used when *writing* (preserves the user's configured order, so
    /// `["x","X"]` writes lowercase `x`, not whatever sorts first).
    private let writeOpenMarker: Character
    private let writeCompletedMarker: Character

    /// Non-empty configured tokens, escaped for regex use.
    private let dueToken: String
    private let startToken: String
    private let scheduledToken: String
    private let doneToken: String
    /// (level, token) for the three priorities, only the non-empty ones,
    /// sorted longest-token-first so `!!!` wins over `!!` over `!`.
    private let priorityTokens: [(level: SyncTask.Priority, token: String)]

    /// Date regexes keyed by the token; matches bare (`>2025-01-20`) and
    /// parenthesized (`@done(2025-01-20)`) forms in one pattern.
    private let dueRegex: NSRegularExpression?
    private let startRegex: NSRegularExpression?
    private let scheduledRegex: NSRegularExpression?
    private let doneRegex: NSRegularExpression?
    private let priorityRegexes: [(level: SyncTask.Priority, regex: NSRegularExpression)]
    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)(#[\\p{L}0-9_][\\p{L}0-9_/-]*)", options: [])

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(settings: SyncConfiguration.GenericMarkdownSettings) {
        let openChars = settings.openMarkers.compactMap { $0.first }
        let completedChars = settings.completedMarkers.compactMap { $0.first }
        self.openMarkers = Set(openChars)
        self.completedMarkers = Set(completedChars)
        self.writeOpenMarker = openChars.first ?? " "
        self.writeCompletedMarker = completedChars.first ?? "x"
        self.dueToken = settings.dueToken
        self.startToken = settings.startToken
        self.scheduledToken = settings.scheduledToken
        self.doneToken = settings.doneToken

        let prios: [(SyncTask.Priority, String)] = [
            (.high, settings.priorityHighToken),
            (.medium, settings.priorityMediumToken),
            (.low, settings.priorityLowToken),
        ].filter { !$0.1.isEmpty }
        // Longest token first so a `!!!` line isn't matched as low `!`.
        self.priorityTokens = prios.sorted { $0.1.count > $1.1.count }

        self.dueRegex = Self.makeDateRegex(dueToken)
        self.startRegex = Self.makeDateRegex(startToken)
        self.scheduledRegex = Self.makeDateRegex(scheduledToken)
        self.doneRegex = Self.makeDateRegex(doneToken)
        self.priorityRegexes = priorityTokens.compactMap { entry in
            guard let rx = Self.makePriorityRegex(entry.token) else { return nil }
            return (entry.level, rx)
        }
    }

    /// `token` + optional `(` + date + optional `)`. Whole match is captured at
    /// range 0 (for stripping); the date is capture group 1.
    private static func makeDateRegex(_ token: String) -> NSRegularExpression? {
        guard !token.isEmpty else { return nil }
        let t = NSRegularExpression.escapedPattern(for: token)
        return try? NSRegularExpression(pattern: "\(t)\\s*\\(?\\s*(\\d{4}-\\d{2}-\\d{2})\\s*\\)?", options: [])
    }

    /// `token` standing alone (bounded by whitespace or string ends) so a `!`
    /// priority isn't matched inside `Hello!`.
    private static func makePriorityRegex(_ token: String) -> NSRegularExpression? {
        guard !token.isEmpty else { return nil }
        let t = NSRegularExpression.escapedPattern(for: token)
        return try? NSRegularExpression(pattern: "(?:^|(?<=\\s))\(t)(?=\\s|$)", options: [])
    }

    // MARK: - Checkbox

    /// Recognize `- [m] `, `* [m] `, or `+ [m] ` checkboxes (the common
    /// markdown/NotePlan forms). Returns the bullet, marker, and trailing
    /// content. Rejects wikilinks (`- [[Name]]`).
    static func extractCheckbox(from trimmed: String) -> (bullet: Character, marker: Character, content: String)? {
        guard trimmed.count >= 6 else { return nil }
        let chars = Array(trimmed)
        guard chars[1] == " ", chars[2] == "[", chars[4] == "]", chars[5] == " " else { return nil }
        let bullet = chars[0]
        guard bullet == "-" || bullet == "*" || bullet == "+" else { return nil }
        // Reject wikilink `- [[...`
        if chars[3] == "[" { return nil }
        let marker = chars[3]
        let content = String(trimmed.dropFirst(6))
        return (bullet, marker, content)
    }

    // MARK: - Parsing

    /// Parse one line into a SyncTask, or nil if it isn't a recognized task.
    func parse(_ line: String, filePath: String, lineNumber: Int, ignoredMarkers: Set<Character> = []) -> SyncTask? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let box = Self.extractCheckbox(from: trimmed) else { return nil }
        if ignoredMarkers.contains(box.marker) { return nil }

        let isOpen = openMarkers.contains(box.marker)
        let isCompleted = completedMarkers.contains(box.marker)
        // Only treat markers we recognize as tasks; unknown markers are skipped
        // (the generic dialect is opt-in — be conservative, don't grab lines we
        // can't classify).
        guard isOpen || isCompleted else { return nil }

        var content = box.content

        let dueDate = extractDate(&content, dueRegex)
        let startDate = extractDate(&content, startRegex)
        let scheduledDate = extractDate(&content, scheduledRegex)
        let completedDate = extractDate(&content, doneRegex)

        var priority: SyncTask.Priority = .none
        for (level, rx) in priorityRegexes {
            let range = NSRange(content.startIndex..., in: content)
            if let m = rx.firstMatch(in: content, options: [], range: range), let r = Range(m.range, in: content) {
                priority = level
                content.removeSubrange(r)
                break
            }
        }

        let tags = extractTags(&content)
        let title = content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: priority,
            dueDate: dueDate,
            startDate: startDate,
            scheduledDate: scheduledDate,
            completedDate: isCompleted ? completedDate : nil,
            tags: tags,
            targetList: tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 },
            obsidianSource: SyncTask.ObsidianSource(filePath: filePath, lineNumber: lineNumber, originalLine: line)
        )
    }

    private func extractDate(_ content: inout String, _ regex: NSRegularExpression?) -> Date? {
        guard let regex = regex else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let m = regex.firstMatch(in: content, options: [], range: range),
              let dateRange = Range(m.range(at: 1), in: content),
              let whole = Range(m.range, in: content) else { return nil }
        let dateStr = String(content[dateRange])
        let date = Self.dateFormatter.date(from: dateStr)
        content.removeSubrange(whole)
        return date
    }

    private func extractTags(_ content: inout String) -> [String] {
        let range = NSRange(content.startIndex..., in: content)
        let matches = Self.tagRegex.matches(in: content, options: [], range: range)
        guard !matches.isEmpty else { return [] }
        var tags: [String] = []
        // Remove from the end backwards so earlier ranges stay valid.
        for m in matches.reversed() {
            if let tagRange = Range(m.range(at: 1), in: content) {
                tags.insert(String(content[tagRange]), at: 0)
            }
            if let whole = Range(m.range, in: content) {
                content.removeSubrange(whole)
            }
        }
        return tags
    }

    // MARK: - Writing

    private func formatDate(_ date: Date) -> String { Self.dateFormatter.string(from: date) }

    /// Render a date token + date. Parenthesized when the token ends in a
    /// letter/digit (`@done(2025-01-20)`); bare otherwise (`>2025-01-20`).
    /// Parsing accepts both, so the exact spacing is round-trip-safe.
    private func renderDateToken(_ token: String, _ date: Date) -> String {
        let d = formatDate(date)
        if let last = token.last, last.isLetter || last.isNumber {
            return "\(token)(\(d))"
        }
        return "\(token)\(d)"
    }

    private var firstOpenMarker: Character { writeOpenMarker }
    private var firstCompletedMarker: Character { writeCompletedMarker }

    /// Build a fresh task line (used for new-task writeback). Order:
    /// `- [m] title !prio >due @done(done) #tags`.
    func buildLine(from task: SyncTask) -> String {
        var parts: [String] = []
        let marker = task.isCompleted ? firstCompletedMarker : firstOpenMarker
        parts.append("- [\(marker)]")
        let title = task.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { parts.append(title) }

        if task.priority != .none, let tok = priorityToken(for: task.priority) {
            parts.append(tok)
        }
        if let start = task.startDate, !startToken.isEmpty {
            parts.append(renderDateToken(startToken, start))
        }
        if let scheduled = task.scheduledDate, !scheduledToken.isEmpty {
            parts.append(renderDateToken(scheduledToken, scheduled))
        }
        if let due = task.dueDate, !dueToken.isEmpty {
            parts.append(renderDateToken(dueToken, due))
        }
        if task.isCompleted, let done = task.completedDate, !doneToken.isEmpty {
            parts.append(renderDateToken(doneToken, done))
        }
        // Tags + target list (deduped, with leading #).
        var seen = Set<String>()
        var tagOut: [String] = []
        var allTags = task.tags
        if let list = task.targetList, !list.isEmpty {
            let asTag = list.hasPrefix("#") ? list : "#\(list)"
            if !allTags.contains(where: { ($0.hasPrefix("#") ? $0 : "#\($0)") == asTag }) {
                allTags.insert(asTag, at: 0)
            }
        }
        for t in allTags {
            let tag = t.hasPrefix("#") ? t : "#\(t)"
            if seen.insert(tag).inserted { tagOut.append(tag) }
        }
        parts.append(contentsOf: tagOut)

        return parts.joined(separator: " ")
    }

    private func priorityToken(for level: SyncTask.Priority) -> String? {
        priorityTokens.first { $0.level == level }?.token
    }

    /// Surgically flip a line to completed: change the checkbox marker and
    /// append the done token + date (if a done token is configured and not
    /// already present). Everything else on the line is preserved verbatim.
    func markComplete(line: String, completionDate: Date) -> String {
        var newLine = replaceCheckboxMarker(in: line, with: firstCompletedMarker)
        if !doneToken.isEmpty, doneRegex?.firstMatch(in: newLine, options: [], range: NSRange(newLine.startIndex..., in: newLine)) == nil {
            let trimmed = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            newLine = trimmed + " " + renderDateToken(doneToken, completionDate)
        }
        return newLine
    }

    /// Surgically flip a line to open: change the checkbox marker and remove the
    /// done token + date if present.
    func markIncomplete(line: String) -> String {
        var newLine = replaceCheckboxMarker(in: line, with: firstOpenMarker)
        if let doneRegex = doneRegex {
            let range = NSRange(newLine.startIndex..., in: newLine)
            // Strip the done token + optional leading whitespace.
            if let m = doneRegex.firstMatch(in: newLine, options: [], range: range), let r = Range(m.range, in: newLine) {
                var lower = r.lowerBound
                while lower > newLine.startIndex {
                    let prev = newLine.index(before: lower)
                    if newLine[prev] == " " { lower = prev } else { break }
                }
                newLine.removeSubrange(lower..<r.upperBound)
            }
        }
        return newLine
    }

    private func replaceCheckboxMarker(in line: String, with marker: Character) -> String {
        let chars = Array(line)
        // Find the `[m]` that follows `<bullet> ` at the first non-space run.
        guard let bulletIdx = chars.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return line }
        let b = bulletIdx
        if b + 4 < chars.count, (chars[b] == "-" || chars[b] == "*" || chars[b] == "+"),
           chars[b+1] == " ", chars[b+2] == "[", chars[b+4] == "]" {
            var out = chars
            out[b+3] = marker
            return String(out)
        }
        return line
    }

    // MARK: - Metadata update

    /// Surgically apply due/start/priority/tag changes. Each `.some` field is
    /// set/replaced (or removed if the inner value is nil); `nil` outer means
    /// "leave untouched". Mirrors `ObsidianService.MetadataChanges` semantics.
    func updateMetadata(line: String, newDueDate: Date??, newStartDate: Date??, newPriority: SyncTask.Priority?, newTags: [String]?) -> String {
        var newLine = line
        if let due = newDueDate, !dueToken.isEmpty {
            newLine = applyDate(to: newLine, token: dueToken, regex: dueRegex, date: due)
        }
        if let start = newStartDate, !startToken.isEmpty {
            newLine = applyDate(to: newLine, token: startToken, regex: startRegex, date: start)
        }
        if let prio = newPriority {
            newLine = applyPriority(to: newLine, level: prio)
        }
        if let tags = newTags {
            newLine = applyTags(to: newLine, tags: tags)
        }
        return newLine.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    private func applyDate(to line: String, token: String, regex: NSRegularExpression?, date: Date?) -> String {
        var newLine = line
        let range = NSRange(newLine.startIndex..., in: newLine)
        let existing = regex?.firstMatch(in: newLine, options: [], range: range)
        if let date = date {
            let rendered = renderDateToken(token, date)
            if let m = existing, let r = Range(m.range, in: newLine) {
                newLine.replaceSubrange(r, with: rendered)
            } else {
                let trimmed = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                newLine = trimmed + " " + rendered
            }
        } else if let m = existing, let r = Range(m.range, in: newLine) {
            // Remove token + a leading space.
            var lower = r.lowerBound
            while lower > newLine.startIndex {
                let prev = newLine.index(before: lower)
                if newLine[prev] == " " { lower = prev } else { break }
            }
            newLine.removeSubrange(lower..<r.upperBound)
        }
        return newLine
    }

    private func applyPriority(to line: String, level: SyncTask.Priority) -> String {
        var newLine = line
        // Remove any existing priority token.
        for (_, rx) in priorityRegexes {
            let range = NSRange(newLine.startIndex..., in: newLine)
            if let m = rx.firstMatch(in: newLine, options: [], range: range), let r = Range(m.range, in: newLine) {
                var lower = r.lowerBound
                while lower > newLine.startIndex {
                    let prev = newLine.index(before: lower)
                    if newLine[prev] == " " { lower = prev } else { break }
                }
                newLine.removeSubrange(lower..<r.upperBound)
            }
        }
        if level != .none, let tok = priorityToken(for: level) {
            let trimmed = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            newLine = trimmed + " " + tok
        }
        return newLine
    }

    private func applyTags(to line: String, tags: [String]) -> String {
        var newLine = line
        // Remove all existing tags.
        while true {
            let range = NSRange(newLine.startIndex..., in: newLine)
            guard let m = Self.tagRegex.firstMatch(in: newLine, options: [], range: range), let r = Range(m.range, in: newLine) else { break }
            newLine.removeSubrange(r)
        }
        let normalized = tags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }
        if !normalized.isEmpty {
            let trimmed = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            newLine = trimmed + " " + normalized.joined(separator: " ")
        }
        return newLine
    }
}
