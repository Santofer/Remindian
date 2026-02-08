import Foundation

/// Append-only text log that records every file modification for audit/debugging.
/// Stored at ~/Library/Application Support/Obsync/audit.log
class AuditLog {
    static let shared = AuditLog()
    private let maxLogSize: UInt64 = 5 * 1024 * 1024 // 5 MB

    private var logURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Obsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.log")
    }

    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        rotateIfNeeded()

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }

    /// Log a file modification event with before/after context
    func logFileModification(action: String, filePath: String, lineNumber: Int, beforeLine: String, afterLine: String) {
        log("FILE_MODIFY action=\(action) file=\(filePath) line=\(lineNumber)")
        log("  BEFORE: \(beforeLine)")
        log("  AFTER:  \(afterLine)")
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }

        // Rotate: rename current to .old, start fresh
        let oldURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logURL, to: oldURL)
    }

    /// Get the log file URL (for UI "View Audit Log" button).
    var auditLogURL: URL {
        return logURL
    }
}
