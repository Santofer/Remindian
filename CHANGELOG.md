# Changelog

All notable changes to Remindian (formerly Obsync) are documented here.

---

## v3.2.0 (February 2026)

### New Features
- **TaskNotes CLI integration (`mtn`)** — Sync tasks using the [mdbase-tasknotes](https://github.com/callumalpass/mdbase-tasknotes) CLI tool. Works completely standalone without Obsidian open. Install with `npm install -g mdbase-tasknotes`
- **TaskNotes integration mode picker** — Choose between CLI (mtn), Direct Files, or HTTP API in Settings
- **Auto-updater** — Checks GitHub Releases for new versions automatically (every 24 hours). Downloads, mounts DMG, replaces the app, and relaunches — all without opening a browser
- **Buy Me a Coffee** — Support the project directly from the About page

### Technical Changes
- `TaskNotesSource` now supports 3 integration modes: CLI (`mtn list --json`), file-based (direct YAML parsing), and HTTP API
- CLI mode uses `Process` to invoke `mtn` with auto-detection of the binary path
- All CLI operations: scan (`mtn list --json`), complete (`mtn complete`), update (`mtn update`), create (`mtn create`)
- File-based mode updated to match mdbase-tasknotes field names (`scheduled` instead of `start`, `completedDate`, `title` in frontmatter)
- `SyncConfiguration` gains `taskNotesIntegrationMode` field (backward compatible, defaults to `cli`)
- `UpdaterService` checks GitHub Releases API, downloads DMG, mounts with `hdiutil`, replaces app bundle, and relaunches
- About page redesigned with update status, progress bar, and Buy Me a Coffee button

---

## v3.1.0-beta (February 2026)

### New Features
- **Things 3 integration** — Sync your tasks to [Things 3](https://culturedcode.com/things/) instead of (or in addition to) Apple Reminders. Reads tasks via AppleScript, creates/updates via `things://` URL scheme
- **TaskNotes integration** — Use the [TaskNotes](https://github.com/nicolo/obsidian-tasknotes) Obsidian plugin as a task source. Parses YAML frontmatter files (one file per task) with support for status, priority, due/start dates, tags, and recurrence
- **Modular architecture** — New `TaskSource` / `TaskDestination` protocol system. The sync engine is now source/destination agnostic, making it easy to add more backends in the future
- **Source & Destination picker** — Choose your task source (Obsidian Tasks or TaskNotes) and destination (Apple Reminders or Things 3) in Settings and in the onboarding wizard
- **FileWatcher self-change filtering** — Writes made by Remindian itself no longer trigger a redundant re-sync (prevents feedback loops)
- **Safety abort** — Sync aborts automatically if the source task count drops more than 50% compared to existing mappings (protects against vault unmounted, scan failures, etc.)
- **Content-hash task IDs** — Task IDs no longer include line numbers, making them stable across line reordering in Obsidian files
- **Unit test suite** — 34 automated tests covering task parsing, deduplication, TaskNotes parsing, and configuration management

### Technical Changes
- `SyncEngine` now takes `TaskSource` and `TaskDestination` protocols instead of direct service instances
- `SyncManager` uses factory methods to create source/destination at runtime based on user settings
- `Things3Destination` handles reading (AppleScript), creating (URL scheme), updating (URL scheme + auth token), and deleting (AppleScript)
- `TaskNotesSource` parses YAML frontmatter and supports both file-based scanning and HTTP API (localhost:7117)
- `RemindersDestination` wraps EventKit behind the `TaskDestination` protocol
- `ObsidianTasksSource` wraps `ObsidianService` behind the `TaskSource` protocol
- `FileWatcherService` now maintains a `selfModifiedFiles` set with 3-second auto-expiry for change filtering
- Added `NSAppleEventsUsageDescription` to Info.plist for Things 3 AppleScript access
- Onboarding wizard expanded to 6 steps (new "Choose Your Setup" step)
- Settings view updated with Source & Destination section and conditional fields

---

## v3.0.0-beta (February 2026) — Remindian

**App renamed from Obsync to Remindian.**

### New Features
- **Due date writeback** — Changes to due dates in Reminders sync back to Obsidian (`📅`)
- **Start date writeback** — Changes to start dates in Reminders sync back to Obsidian (`🛫`)
- **Priority writeback** — Changes to priority in Reminders sync back to Obsidian (`⏫`/`🔼`/`🔽`)
- **New task writeback** — Tasks created in Reminders are appended to an Obsidian inbox file
- **Recurrence writeback** — Completing a recurring task in Reminders creates the next occurrence in Obsidian with correctly computed dates
- **FSEvents file watcher** — Real-time sync triggered by vault file changes (optional)
- **Onboarding wizard** — Guided setup on first launch with folder filtering and tag mapping configuration
- **Folder whitelist** — Optionally scan only specific vault folders instead of the entire vault
- **Cross-file deduplication** — Detects duplicate tasks across files (e.g. Inbox.md + original) and syncs only one copy
- **About page** — In-app version info, author credits, update check link
- **Config persistence fix** — Settings (exclusions, mappings, whitelist) now save correctly when modified
- **Consistent menu bar font** — All menu items use the same system font size

### Bug Fixes
- **Fixed emoji encoding corruption** — `applyDateChange()` rewritten to only replace date digits (YYYY-MM-DD), preserving original emoji bytes verbatim
- **Fixed FE0F variation selector handling** — All emoji regex patterns now include `\u{FE0F}?` to handle optional Unicode variation selectors
- **Fixed recurrence text leaking into titles** — Both emoji-based (`🔁`) and plain-text (`every month on the 1st when done`) recurrence rules are now stripped from task titles
- **Fixed recurrence writeback line-shift corruption** — Line offset tracking prevents subsequent writebacks in the same file from targeting wrong lines after a recurrence insertion
- **Fixed double completion writeback** — Guard prevents writing `[x]` to already-completed tasks
- **Fixed delete+recreate cycle** — Removed mutable fields from `generateObsidianId()`; task IDs now use `filePath + title + tags + lineNumber` only
- **Fixed duplicate deletion during migration** — `relinkedRemindersIds` tracking prevents the same reminder from being deleted by stale mappings
- **Fixed recurring task ID collision** — Added `lineNumber` to ID components to disambiguate completed + uncompleted copies
- **Fixed backup errors during bulk sync** — File-exists check before backup to skip redundant backups within the same second
- **Fixed newline handling** — Changed all `components(separatedBy: .newlines)` to `components(separatedBy: "\n")`
- **Fixed settings tab visibility** — Increased window size and made General tab scrollable
- **Fixed folder exclusion matching** — Now matches by folder name, relative path, and path prefix
- **Fixed graceful file skip** — Unreadable files (broken symlinks, permissions) are skipped with a warning instead of failing the entire sync

### Technical Changes
- Sync state version bumped to v7 (stable IDs)
- v6 → v7 migration preserves existing mappings for graceful re-linking
- Score-based re-linking in `(.none, .some)` case with title + targetList + filePath matching
- Reconnect logic in `(.some, .none)` case checks existing reminders before recreating
- Step 5 deduplication builds title index of unmatched reminders to prevent duplicates after sync state reset
- Bundle identifier changed from `com.obsync.app` to `com.remindian.app`
- Application Support folder changed from `Obsync` to `Remindian`

---

## v2.0.0 (February 2026)

### New Features
- **Completion writeback** — Marking a task complete in Reminders surgically updates the Obsidian file (`- [x]` + `✅ YYYY-MM-DD`)
- **Recurrence handling** — Completing a recurring task creates a new uncompleted task with updated dates above the completed one
- **Metadata writeback** — Due date, start date, and priority changes from Reminders written back to Obsidian (atomic, surgical edits)
- **Dry run mode** — Full sync logic executes without making changes; reports what would change
- **Automatic file backups** — Every Obsidian file backed up before modification (`~/Library/Application Support/Remindian/backups/`)
- **Audit log** — Append-only log of every file modification with before/after content
- **Sync mutex** — NSLock prevents concurrent sync operations
- **Vault path validation** — Verifies vault exists and contains `.obsidian` directory
- **Line content verification** — Safety check before writing ensures file hasn't changed externally
- **Security-scoped bookmarks** — Vault access persists across app restarts in sandbox
- **Global hotkey** — Cmd+Shift+Option+S to trigger sync from any app (Carbon RegisterEventHotKey)
- **macOS notifications** — Sync errors and status updates via UNUserNotificationCenter
- **Sync history** — Last 200 sync operations with expandable detail view
- **Tag-based list mapping** — `#tag` → Reminders list with auto-capitalization fallback
- **Custom app icons** — Light, dark, and tinted variants with automatic switching
- **Force dark mode** — Toggle to force entire app UI to dark mode
- **Hide dock icon** — Run as menu bar-only app

### Safety: Disabled Dangerous Methods
The original `updateTask()`, `addTask()`, and `deleteTask()` methods in ObsidianService used `toObsidianLine()` to reconstruct task lines, which destroyed any metadata not explicitly modeled (recurrence markers `🔁`/`🔂`, custom metadata, non-standard formatting). All three are now marked `@available(*, deprecated)` and throw `ObsidianError.unsafeWriteDisabled`.

Replaced by surgical edit methods:
- `markTaskComplete()` — Only modifies `- [ ]` → `- [x]` and appends `✅ YYYY-MM-DD`
- `markTaskIncomplete()` — Reverses the above
- `updateTaskMetadata()` — Only replaces date digits or priority emoji, preserving all surrounding content

### Content-Hash Task IDs
Replaced line-number-based IDs (`filePath:lineNumber`) with content-hash IDs (`filePath + title + tags + lineNumber`). Tasks survive reordering, and the re-linking logic handles ID format migrations gracefully.

---

## v1.0.1 (February 2026)

- Fix: `.newerWins` compile error in SyncConfiguration (changed to `.obsidianWins`)
- Fix: Menu bar icon sizing using NSImage.SymbolConfiguration(pointSize: 14)
- Fix: "Open Settings" button using proper NSWindow approach instead of broken private API

---

## v1.0.0 (February 2026)

First public release. One-way sync from Obsidian Tasks to Apple Reminders.

- Scans Obsidian vault for tasks in Tasks plugin format
- Creates/updates/deletes Apple Reminders to match
- Priority emoji mapping (⏫/🔼/🔽 → Reminders priority levels)
- Due date sync (📅 → Reminders due date)
- Start date and scheduled date stored in Reminders notes
- Excluded folders configuration
- Auto-sync on configurable timer
- Menu bar app with sync status indicator

---

## Architecture

```
SwiftUI Layer: ContentView | SettingsView | MenuBarView | SyncHistoryView | AboutView
                    |
              SyncManager  (@MainActor ObservableObject singleton)
                    |
              SyncEngine   (core sync orchestrator, NSLock mutex)
               /        \
        TaskSource       TaskDestination
        (protocol)        (protocol)
          /    \            /       \
  Obsidian   TaskNotes  Reminders  Things3
  TasksSrc   Source     Destination Destination
     |          |          |           |
  ObsidianSvc  YAML     EventKit   AppleScript
  (vault I/O)  parser   (CRUD)     + URL scheme
       |
  FileBackupService | AuditLog
```

**Technology:** Swift 5, SwiftUI, EventKit, Carbon (hotkeys), UserNotifications, AppleScript (Things 3). No external dependencies.

## Data Storage

All persistent data under `~/Library/Application Support/Remindian/`:

| File | Purpose | Limit |
|------|---------|-------|
| `config.json` | User settings | ~2 KB |
| `sync_state.json` | Task ID mappings + hashes | Grows with task count |
| `sync_log.json` | Sync history | 200 entries |
| `audit.log` | File modification trail | 5 MB (rotates) |
| `backups/` | Pre-modification file copies | 50 per file, 7 days |
| `debug.log` | Debug output | Grows (manual cleanup) |

## Key Invariants

- **Never call `toObsidianLine()` in any write path.** All Obsidian writes must be surgical.
- **Always back up before writing.** Every code path modifying an Obsidian file calls `FileBackupService.backupFile()` first.
- **Always verify line content before writing.** The `lineContentMismatch` check is a critical safety net.
- **Bump `SyncState.stateVersion`** if you change the ID generation algorithm.
- **Completion detection must not be gated by `oChanged`.** The `completionDiffers` check always runs independently.

## Known Limitations

1. Recurrence rules are preserved in Obsidian files but not mapped to native EKRecurrenceRule in Reminders
2. Only "Obsidian Wins" conflict resolution is implemented
3. `toObsidianLine()` still exists as dead code (never called in safe paths)
4. Line number-based writeback can fail if file is modified between scan and write (safety check catches this)
5. Not notarized — requires right-click → Open on first launch
6. Tags used only for list mapping; not synced to Reminders tags (EventKit limitation)
