import Foundation

/// Owner-only persistence for files that hold credentials or personal content.
///
/// Remindian's state files were written with `.atomic` and nothing else, so they
/// landed at the process umask — `0644` on a default macOS install. That makes
/// `config.json` and `profiles.json` — which carry API tokens and OAuth refresh
/// tokens — readable by *every* account on the machine, and `debug.log` likewise.
/// (Security review GHSA-3q2g-hmqg-qj5r, finding H2.)
///
/// Note the honest limit: `0600` stops other *users* and reduces incidental
/// exposure (backups, shared machines, cloud-sync tooling running as another
/// account). It does **not** defend against a process running as the user — only
/// a real secure store (Keychain) does that, which needs a stable code-signing
/// identity this app does not yet have. This is hardening, not the full fix.
enum SecureFile {

    /// `rw-------`
    static let ownerOnly: NSNumber = 0o600
    /// `rwx------`
    static let ownerOnlyDirectory: NSNumber = 0o700

    /// Write atomically, then restrict to the owner.
    ///
    /// The permissions are applied *after* the write on purpose: an atomic write
    /// creates a fresh temp file and renames it over the target, so the mode is
    /// re-derived from the umask on every save. Setting it once at creation time
    /// would silently regress on the next write.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        restrictToOwner(at: url)
    }

    /// Apply owner-only permissions to an existing file or directory, if present.
    /// Best-effort: a failure here must never block the write that just succeeded.
    @discardableResult
    static func restrictToOwner(at url: URL, isDirectory: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? ownerOnlyDirectory : ownerOnly],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    /// Harden files that already exist on disk from before this was introduced.
    /// Called on load so existing installs are fixed without waiting for a write.
    static func hardenExistingFiles(in directory: URL, names: [String]) {
        restrictToOwner(at: directory, isDirectory: true)
        for name in names {
            restrictToOwner(at: directory.appendingPathComponent(name))
        }
    }

    private static var didHardenExisting = false
    private static let hardenLock = NSLock()

    /// Fix up permissions of files written by earlier versions, once per launch.
    /// An upgrading user's `config.json` is already sitting at `0644`; waiting for
    /// the next save to correct it would leave it exposed indefinitely.
    static func hardenLegacyFilesOnce(in directory: URL) {
        hardenLock.lock()
        defer { hardenLock.unlock() }
        guard !didHardenExisting else { return }
        didHardenExisting = true
        hardenExistingFiles(in: directory, names: sensitiveFileNames)
        // `backups/` holds copies of the user's vault notes. Tightening the
        // directory itself blocks traversal by other accounts, which protects
        // every file inside without walking thousands of entries.
        for subdirectory in sensitiveDirectoryNames {
            restrictToOwner(at: directory.appendingPathComponent(subdirectory), isDirectory: true)
        }
    }

    /// Directories whose *contents* are personal, hardened by blocking traversal.
    static let sensitiveDirectoryNames = ["backups"]

    /// Files that carry credentials or personal task content.
    static let sensitiveFileNames = [
        "config.json",      // API tokens
        "profiles.json",    // API tokens, per profile
        "debug.log",        // OAuth callback URLs, sync diagnostics
        "audit.log",
        "audit.old.log",
        "sync_log.json",    // task titles
        "sync_state.json",  // task titles
    ]
}
