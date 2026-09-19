import Foundation

/// Finds duplicate task lines *inside the vault*.
///
/// The reminder-side cleanup removes duplicate reminders, but the debris that
/// created them often sits in the vault too: a feedback loop between the two sync
/// directions could append the same recurring task to the inbox once per
/// occurrence. One real vault accumulated 140 such lines in `Inbox.md`.
///
/// Matching mirrors the reminder cleanup: same title and same completion state
/// count as duplicates even when their dates differ, because each appended copy
/// carries a different completion date. The parse reuses
/// `SyncTask.fromObsidianLine`, so "what counts as a task" can't drift from what
/// the sync itself sees.
enum VaultCleanup {

    struct Duplicate {
        let lineIndex: Int      // 0-based, into the file's lines
        let title: String
        let isCompleted: Bool
    }

    /// Line indices that are repeat copies of an earlier task in the same file.
    /// The first occurrence of each (title, completion state) is always kept.
    static func duplicateTaskLines(in content: String) -> [Duplicate] {
        let lines = content.components(separatedBy: "\n")
        var seen = Set<String>()
        var duplicates: [Duplicate] = []

        for (index, line) in lines.enumerated() {
            guard let task = SyncTask.fromObsidianLine(line, filePath: "", lineNumber: index + 1) else { continue }
            let title = task.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            let key = "\(title.lowercased())|\(task.isCompleted)"
            if seen.contains(key) {
                duplicates.append(Duplicate(lineIndex: index, title: title, isCompleted: task.isCompleted))
            } else {
                seen.insert(key)
            }
        }
        return duplicates
    }

    /// The file's content with the given line indices removed.
    static func removingLines(_ indices: [Int], from content: String) -> String {
        let drop = Set(indices)
        var lines = content.components(separatedBy: "\n")
        lines = lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        return lines.joined(separator: "\n")
    }
}
