# Obsync

A native macOS menu-bar application that syncs tasks between an [Obsidian](https://obsidian.md) vault (using the [Tasks plugin](https://publish.obsidian.md/tasks/Introduction) format) and Apple Reminders.

**Obsidian is the source of truth.** Tasks flow from Obsidian into Apple Reminders. Completion status can optionally be written back to Obsidian using surgical, metadata-preserving edits.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Data Model & Sync Flow](#data-model--sync-flow)
- [Critical Design Decision: Surgical Edits](#critical-design-decision-surgical-edits)
- [Task Identification: Content-Hash IDs](#task-identification-content-hash-ids)
- [Safety & Reliability Layers](#safety--reliability-layers)
- [Feature Reference](#feature-reference)
- [Configuration & Persistence](#configuration--persistence)
- [Build & Run](#build--run)
- [Known Limitations](#known-limitations)
- [Version History](#version-history)
- [Handoff Notes for Future Development](#handoff-notes-for-future-development)

---

## Architecture Overview

```
+------------------------------------------------------------------+
|                        SwiftUI Layer                              |
|  ContentView  |  SettingsView  |  MenuBarView  | SyncHistoryView |
+-------+-------+--------+------+-------+-------+--------+--------+
        |                |               |                |
        +--------+-------+---------------+                |
                 v                                        |
          +------------------+                            |
          |   SyncManager    |  <-- @MainActor ObservableObject (singleton)
          |  (coordinator)   |      Bridges SyncEngine <-> UI
          +--------+---------+
                   |
          +--------v---------+
          |   SyncEngine     |  <-- Core sync orchestrator
          |                  |      NSLock mutex, dry run, writeback
          +--+------------+--+
             |            |
    +--------v----+  +----v-----------+
    | Obsidian    |  |  Reminders     |
    | Service     |  |  Service       |
    | (vault I/O) |  | (EventKit)     |
    +------+------+  +----------------+
           |
    +------v-------------------------------+
    |  Safety Services                      |
    |  FileBackupService  |  AuditLog       |
    +---------------------------------------+

Models: SyncTask | SyncConfiguration | SyncState | SyncLog
```

**Technology stack:**
- Swift 5, SwiftUI, macOS 13.0+ deployment target
- EventKit (Apple Reminders API)
- Carbon (RegisterEventHotKey for global shortcuts)
- UserNotifications (macOS notification center)
- No external dependencies

---

## Project Structure

```
Obsync/
├── ObsyncApp.swift      # @main entry point, AppDelegate
├── Info.plist                          # App metadata, LSUIElement, usage descriptions
├── Obsync.entitlements  # Sandbox, Reminders, file access, bookmarks
├── Assets.xcassets/                    # App icon (7 sizes: 16-1024px), AccentColor
│   ├── AppIcon.appiconset/             # Dark bg, sync arrows, green checkmark
│   ├── AccentColor.colorset/
│   └── Contents.json
├── Models/
│   ├── SyncTask.swift          # 377 lines - Unified task model (Obsidian <-> Reminders)
│   ├── SyncConfiguration.swift # 176 lines - All user settings, JSON-persisted
│   ├── SyncState.swift         # 150 lines - Bidirectional ID mappings + hash tracking
│   └── SyncLog.swift           #  89 lines - Sync history entries (max 200)
├── Services/
│   ├── ObsidianService.swift   # 303 lines - Vault scanning + surgical edits
│   ├── RemindersService.swift  # 192 lines - EventKit CRUD wrapper
│   ├── SyncEngine.swift        # 500 lines - Core sync logic, conflict resolution
│   ├── SyncManager.swift       # 261 lines - UI coordinator, timer, hotkey, bookmarks
│   ├── FileBackupService.swift #  80 lines - Timestamped file backups with pruning
│   ├── NotificationService.swift # 51 lines - macOS UserNotifications wrapper
│   ├── HotKeyService.swift     #  82 lines - Carbon global hotkey registration
│   └── AuditLog.swift          #  58 lines - Append-only file modification log
└── Views/
    ├── ContentView.swift       # 391 lines - Main window: dashboard, conflicts, history
    ├── SettingsView.swift      # 326 lines - 3-tab settings (General, Mappings, Advanced)
    ├── MenuBarView.swift       # 219 lines - Menu bar dropdown
    └── SyncHistoryView.swift   # 148 lines - Expandable sync history list
```

**Total:** 17 Swift source files, ~3,400 lines of code.

---

## Data Model & Sync Flow

### SyncTask (Models/SyncTask.swift)

The central data structure that bridges both systems. Key properties:

| Property | Type | Obsidian Source | Reminders Source |
|----------|------|----------------|-----------------|
| `title` | `String` | Text after `- [ ]` | `EKReminder.title` |
| `isCompleted` | `Bool` | `- [x]` vs `- [ ]` | `EKReminder.isCompleted` |
| `priority` | `Priority` | Emojis (see below) | `EKReminder.priority` (0-9) |
| `dueDate` | `Date?` | `📅 YYYY-MM-DD` | `EKReminder.dueDateComponents` |
| `startDate` | `Date?` | `🛫 YYYY-MM-DD` | Stored in `notes` |
| `scheduledDate` | `Date?` | `⏳ YYYY-MM-DD` | Stored in `notes` |
| `completedDate` | `Date?` | `✅ YYYY-MM-DD` | `EKReminder.completionDate` |
| `tags` | `[String]` | `#tag1 #tag2` | Used for list mapping |
| `obsidianSource` | `ObsidianSource?` | `filePath` + `lineNumber` | n/a |
| `remindersId` | `String?` | n/a | `EKReminder.calendarItemIdentifier` |

**Priority emojis:** `⏫` (high), `🔼` (medium), `🔽` (low)

**Parsing:** `SyncTask.fromObsidianLine(_:filePath:lineNumber:)` uses regex to extract emoji-prefixed metadata from Obsidian Tasks format lines.

**Serialization:** `SyncTask.toObsidianLine()` exists but is **deliberately unused** in safe code paths. See [Critical Design Decision](#critical-design-decision-surgical-edits).

### Obsidian Tasks Format

```markdown
- [ ] My task ⏫ 🛫 2024-01-15 📅 2024-01-20 #work #project
- [x] Completed task 📅 2024-01-10 ✅ 2024-01-09 #personal
- [ ] Recurring task 🔁 every week 📅 2024-03-01
```

### Sync Flow (SyncEngine.performSync)

```
1. Validate vault path exists and contains .obsidian/
2. Scan Obsidian vault -> [SyncTask] (all .md files, excluding configured folders)
3. Fetch all Apple Reminders -> [SyncTask]
4. Build lookup maps:
   - obsidianById: [obsidianId: SyncTask]
   - reminderById: [remindersId: SyncTask]
5. For each existing mapping in SyncState:
   a. Both sides exist -> check hashes for changes -> update if needed
   b. Obsidian deleted -> remove from Reminders
   c. Reminders deleted -> remove mapping (Obsidian is source of truth)
6. Handle completion writeback (if enabled):
   - Task completed in Reminders but not Obsidian -> surgically mark complete in .md file
   - Task un-completed in Reminders but completed in Obsidian -> surgically mark incomplete
7. New Obsidian tasks (no mapping) -> create in Reminders
8. Save updated SyncState, return SyncResult
```

**Dry run mode:** When `config.dryRunMode == true`, the entire flow executes but skips all actual Reminders API calls and Obsidian file writes. The SyncResult reports what *would* have changed.

---

## Critical Design Decision: Surgical Edits

### The Problem (v1.0)

The original codebase had three dangerous methods in `ObsidianService`:
- `updateTask()` -- called `toObsidianLine()` to reconstruct the full task line from parsed fields
- `addTask()` -- same issue
- `deleteTask()` -- removed lines, corrupting line-number-based sync state

`toObsidianLine()` only serialized fields that `SyncTask` explicitly modeled. Any metadata NOT captured by the parser was **permanently destroyed**:
- Recurrence markers: `🔁 every week`, `🔂 every 2 days`
- Custom inline metadata
- Non-standard formatting, indentation
- Any future Obsidian Tasks plugin fields

**This caused the user's data loss:** all Tasks plugin dates (start date, due date, recurrence) were stripped on the first sync.

### The Solution (v2.0)

**All three dangerous methods are disabled.** They are marked `@available(*, deprecated)` and throw `ObsidianError.unsafeWriteDisabled` if called.

Two new **surgical edit** methods replace them:

```swift
// ObsidianService.swift

func markTaskComplete(
    filePath: String,
    lineNumber: Int,
    originalLine: String,
    completionDate: Date,
    vaultPath: String
) throws

func markTaskIncomplete(
    filePath: String,
    lineNumber: Int,
    originalLine: String,
    vaultPath: String
) throws
```

These methods:
1. Read the original line **verbatim** from the file
2. **Safety check:** verify the current line matches `originalLine` (abort on mismatch)
3. **Only modify** `- [ ]` to `- [x]` (or reverse) and append/remove `✅ YYYY-MM-DD`
4. **Never reconstruct** the line -- all other content (recurrence, dates, tags, formatting) is preserved exactly
5. Back up the file first via `FileBackupService`
6. Log the modification via `AuditLog`

---

## Task Identification: Content-Hash IDs

### The Problem (v1.0)

Original task IDs were generated as `base64(filePath + ":" + lineNumber)`. This broke when:
- Tasks were reordered within a file
- Lines were inserted/deleted above a task
- The same task content appeared on different lines after edits

### The Solution (v2.0)

IDs are now content-based (see `SyncState.generateObsidianId(task:)`):

```swift
let components = [
    source.filePath,
    task.title,
    task.dueDate?.ISO8601Format() ?? "",
    task.startDate?.ISO8601Format() ?? "",
    task.scheduledDate?.ISO8601Format() ?? "",
    task.tags.sorted().joined(separator: ","),
    String(task.priority.rawValue)
]
return components.joined(separator: "|")
    .data(using: .utf8)!
    .base64EncodedString()
```

**State versioning:** `SyncState.stateVersion` is set to `2`. On load, if the persisted version is older, all mappings are automatically cleared to prevent ID format corruption. This means the first sync after upgrading will re-create all Reminders entries.

**Change detection hashes** (`generateTaskHash`) now include ALL fields: title, dates (due, start, scheduled, completed), priority, completion status, tags, and notes.

---

## Safety & Reliability Layers

### 1. File Backup (FileBackupService)
- **When:** Before every Obsidian file modification
- **Where:** `~/Library/Application Support/Obsync/backups/`
- **Naming:** `{filename}_{yyyyMMdd}_{HHmmss}.md`
- **Retention:** Max 50 backups per file, max 7 days old

### 2. Audit Log (AuditLog)
- **What:** Every file modification logged with timestamp, action, file path, line number, before/after content
- **Where:** `~/Library/Application Support/Obsync/audit.log`
- **Rotation:** Auto-rotates at 5 MB (renames to `.old.log`)

### 3. Sync Mutex (SyncEngine)
- `NSLock`-based mutual exclusion prevents concurrent sync operations
- Throws `SyncError.syncAlreadyInProgress` on conflict

### 4. Vault Path Validation (SyncEngine)
- Verifies vault path exists on disk
- Verifies it contains a `.obsidian` directory (not just any folder)
- Errors: `vaultPathNotFound`, `notAnObsidianVault`

### 5. Line Content Verification (ObsidianService)
- Before writing, compares current file line against expected content
- Aborts with `lineContentMismatch` if file was modified externally
- Prevents writing stale data

### 6. File Change Detection (ObsidianService)
- `captureFileTimestamp()` records modification time before sync
- `hasFileChanged(since:)` checks if file was modified during sync window
- Used by SyncEngine to skip writes to externally-modified files

### 7. Dry Run Mode (SyncConfiguration)
- Full sync logic executes without any actual changes
- SyncResult reports what would have been created/updated/deleted
- Toggle in Settings > Advanced

### 8. Security-Scoped Bookmarks (SyncManager)
- Saves vault directory bookmark when user selects via NSOpenPanel
- Resolves bookmark on app launch for sandbox persistence
- Re-prompts if bookmark becomes stale

### 9. Disabled Dangerous Methods (ObsidianService)
- `updateTask()`, `addTask()`, `deleteTask()` throw `unsafeWriteDisabled`
- Marked `@available(*, deprecated)` with explanatory messages
- Prevents any future code from accidentally calling the data-destructive paths

---

## Feature Reference

### Sync Behavior
- **Auto-sync:** Configurable interval (1/5/15/30/60 minutes), enabled by default at 5 min
- **Sync on launch:** Triggers sync when app starts (configurable)
- **Manual sync:** "Sync Now" button in menu bar and main window
- **Conflict resolution:** Obsidian always wins (only strategy implemented)
- **Completion writeback:** Opt-in. When a task is completed in Apple Reminders, the Obsidian file is surgically updated to `- [x]` with completion date. Disabled by default.

### List Mapping
- Obsidian tags (`#work`, `#personal`) map to specific Reminders lists
- Configurable in Settings > List Mappings
- Default list used for untagged tasks
- Reverse mapping available: `config.obsidianTagForList(_:)`

### Notifications (NotificationService)
- Sends macOS notifications on sync errors
- Uses `UNUserNotificationCenter` with `.alert` and `.sound`
- Categories: `syncError`, `syncComplete`, `permissionIssue`
- Toggle in Settings > General

### Sync History (SyncLog + SyncHistoryView)
- Last 200 sync operations stored with full details
- Each entry: timestamp, duration, counts (created/updated/deleted/completions), errors, dry run flag
- Expandable detail rows showing individual task actions
- Accessible in main window > History tab
- Clearable via button

### Global Keyboard Shortcut (HotKeyService)
- Uses Carbon `RegisterEventHotKey` API (sandbox-compatible)
- Default: Cmd+Shift+Option+S (disabled by default)
- Triggers immediate sync from any application
- Toggle and display in Settings > General

### Menu Bar
- Persistent menu bar extra with sync status indicator
- Color-coded: blue (syncing), red (no permission), orange (conflicts), green (normal)
- Quick access to Sync Now, main window, settings

### App Icon
- Programmatically generated (generation script: `/tmp/generate_icon.swift`)
- Dark rounded rectangle background
- Circular sync arrows (light gray) with green checkmark center
- All standard macOS sizes: 16, 32, 64, 128, 256, 512, 1024px

---

## Configuration & Persistence

All persistent data is stored under `~/Library/Application Support/Obsync/`:

| File | Purpose | Format | Max Size |
|------|---------|--------|----------|
| `config.json` | User settings | JSON (Codable) | ~2 KB |
| `sync_state.json` | Task ID mappings + hashes | JSON (Codable) | Grows with task count |
| `sync_log.json` | Sync history | JSON (Codable) | 200 entries max |
| `audit.log` | File modification audit trail | Plain text | 5 MB (rotates) |
| `backups/` | File backups before writes | .md copies | 50 per file, 7 days |

**UserDefaults key:** `vaultBookmark` -- security-scoped bookmark data for sandbox file access.

### SyncConfiguration Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `vaultPath` | `String` | `""` | Obsidian vault directory path |
| `syncIntervalMinutes` | `Int` | `5` | Auto-sync interval |
| `enableAutoSync` | `Bool` | `true` | Enable periodic sync |
| `syncOnLaunch` | `Bool` | `true` | Sync when app starts |
| `listMappings` | `[ListMapping]` | `[]` | Tag to Reminders list map |
| `defaultList` | `String` | `"Reminders"` | Default Reminders list |
| `taskFilesPattern` | `String` | `"**/*.md"` | File glob pattern |
| `excludedFolders` | `[String]` | `[".obsidian", ".git", ".trash"]` | Folders to skip |
| `syncCompletedTasks` | `Bool` | `true` | Include completed tasks |
| `deleteCompletedAfterDays` | `Int?` | `nil` | Auto-delete completed |
| `conflictResolution` | `ConflictResolution` | `.obsidianWins` | Conflict strategy |
| `includeDueTime` | `Bool` | `false` | Include time in due dates |
| `hideDockIcon` | `Bool` | `false` | LSUIElement behavior |
| `dryRunMode` | `Bool` | `false` | Simulate sync without changes |
| `enableCompletionWriteback` | `Bool` | `false` | Write completions to Obsidian |
| `enableNotifications` | `Bool` | `true` | Send macOS notifications |
| `globalHotKeyEnabled` | `Bool` | `false` | Enable global shortcut |
| `globalHotKeyCode` | `UInt32` | `1` (kVK_ANSI_S) | Key code |
| `globalHotKeyModifiers` | `UInt32` | `0x0D00` (Cmd+Shift+Opt) | Modifier flags |

All new properties use `decodeIfPresent` with defaults for backward compatibility with existing v1.0 config files.

---

## Build & Run

### Requirements
- macOS 13.0+ (Ventura or later)
- Xcode 15.0+
- Apple Reminders access (prompted on first launch)

### Build

```bash
# Command-line build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Obsync.xcodeproj \
  -scheme Obsync \
  -configuration Debug build

# Or open in Xcode
open Obsync.xcodeproj
```

The built app is at:
```
~/Library/Developer/Xcode/DerivedData/Obsync-*/Build/Products/Debug/Obsync.app
```

### Entitlements (sandbox)

The app runs sandboxed with these entitlements:
- `com.apple.security.app-sandbox` -- App Sandbox
- `com.apple.security.personal-information.calendars` -- Reminders (EventKit) access
- `com.apple.security.files.user-selected.read-write` -- User-selected file access (vault)
- `com.apple.security.files.bookmarks.app-scope` -- Security-scoped bookmarks

### First Launch

1. Grant Reminders access when prompted
2. Select your Obsidian vault directory via the file picker
3. (Optional) Configure list mappings in Settings > List Mappings
4. Sync will run automatically or click "Sync Now"

---

## Known Limitations

1. **One-way sync for task creation:** New tasks can only flow from Obsidian to Reminders. Tasks created in Reminders are not synced back to Obsidian.

2. **Recurrence not synced:** Obsidian Tasks recurrence markers (`🔁`, `🔂`) are **preserved** in files but not synced to Reminders' native recurrence. This is by design to avoid complexity and data loss.

3. **Conflict resolution:** Only "Obsidian Wins" is implemented. The `ConflictResolution` enum has only one case.

4. **`toObsidianLine()` still exists:** The method in `SyncTask.swift` that reconstructs task lines is still present in code but deliberately never called by safe code paths. It remains for potential future use if field-level reconstruction is ever needed, but all current write paths use surgical edits.

5. **Line number fragility for writeback:** While task IDs are now content-hash-based, the `markTaskComplete()`/`markTaskIncomplete()` methods still use `lineNumber` to locate the target line. If a file is modified between scan and writeback (task reordered, lines added/deleted), the line content safety check will catch the mismatch and abort. This is safe but means writeback can fail on actively-edited files.

6. **No file watcher:** The app polls on a timer. It does not use FSEvents or file system monitoring to detect changes in real-time.

7. **No undo for completion writeback:** Once a completion is written to an Obsidian file, there is no in-app undo. The backup file can be manually restored from the backups directory.

---

## Version History

### v2.0 (Current)

Major reliability and feature update.

**Critical Fixes:**
- Fixed compile error: `.newerWins` (nonexistent enum case) changed to `.obsidianWins` in `SyncConfiguration.swift:54`
- **Fixed data loss bug:** Replaced `toObsidianLine()`-based writes with surgical line editing that preserves all metadata verbatim
- Disabled dangerous write methods (`updateTask`, `addTask`, `deleteTask`) -- they now throw `unsafeWriteDisabled`

**Reliability Improvements:**
- Content-hash-based task IDs (stable across line reordering)
- Sync state versioning with auto-reset on format change
- NSLock-based sync mutex preventing concurrent syncs
- Vault path validation (existence + `.obsidian` directory check)
- Line content verification before writes
- File change detection during sync window
- Improved task hash including all fields (scheduledDate, completedDate, tags)

**New Features:**
- Completion writeback (opt-in): sync task completions from Reminders back to Obsidian
- Dry run mode: simulate sync without making changes
- File backup service: automatic timestamped backups before writes (50/file, 7-day retention)
- Audit log: append-only log of all file modifications (5 MB rotation)
- macOS notifications on sync errors
- Sync history view with expandable details (last 200 syncs)
- Global keyboard shortcut (Carbon API, default: Cmd+Shift+Option+S)
- App icon: dark rounded rect with sync arrows and green checkmark
- Security-scoped bookmarks for sandbox vault access persistence
- Settings UI for all new features

**New Files (6):**
- `Services/FileBackupService.swift`
- `Services/NotificationService.swift`
- `Services/HotKeyService.swift`
- `Services/AuditLog.swift`
- `Models/SyncLog.swift`
- `Views/SyncHistoryView.swift`

### v1.0

Initial release. One-way Obsidian to Reminders sync with basic conflict detection. **Had data loss bug** due to `toObsidianLine()` reconstruction destroying unmodeled metadata.

---

## Handoff Notes for Future Development

### Code Quality Observations

1. **SyncEngine.swift is the most complex file (500 lines).** The `performSync()` method is long and would benefit from extraction into smaller helper methods if further features are added.

2. **Error handling is thorough but inconsistent in style.** Some methods throw, some return optionals, some use Result. A future refactor could standardize on `async throws`.

3. **The `SyncTask.toObsidianLine()` method is dead code.** It still exists and could be removed entirely, or kept as documentation of the Obsidian Tasks format. If removed, also remove the `formatDate()` helper.

4. **RemindersService uses a completion-handler-to-async bridge** for `fetchReminders()`. This could be modernized to use EventKit's native async APIs on macOS 14+.

5. **The Carbon HotKeyService** uses legacy C-function-pointer callbacks. This works but is fragile. Consider migrating to `CGEvent` tap or a Swift wrapper if/when Carbon support is deprecated.

### Potential Future Improvements

1. **FSEvents file watcher:** Replace timer-based polling with real-time file system monitoring. Would require careful debouncing.

2. **Bidirectional task creation:** Allow new Reminders tasks to sync back into Obsidian. This is complex because it requires choosing a target file and position.

3. **Recurrence sync:** Map Obsidian Tasks recurrence rules to EKRecurrenceRule. This is non-trivial due to format differences.

4. **Multi-vault support:** Currently single vault only. Would require refactoring SyncState and SyncConfiguration to be vault-scoped.

5. **Unit tests:** No test suite exists. Priority test targets:
   - `SyncTask.fromObsidianLine()` parsing (many edge cases)
   - `SyncState.generateObsidianId()` stability
   - `ObsidianService.markTaskComplete()` with various line formats
   - `SyncEngine.performSync()` with mock services

6. **Undo support for writeback:** Track modifications in a stack and expose an undo action.

7. **Menu bar icon:** Currently uses the system `arrow.triangle.2.circlepath` SF Symbol. A custom template image matching the app icon style would be a nice polish.

### Key Invariants to Maintain

- **Never call `toObsidianLine()` in any write path.** This is the root cause of v1.0's data loss. All Obsidian file writes MUST be surgical (modify only what's needed, preserve everything else).
- **Always back up before writing.** Every code path that modifies an Obsidian file must call `FileBackupService.backupFile()` first.
- **Always verify line content before writing.** The `lineContentMismatch` check in `markTaskComplete()`/`markTaskIncomplete()` is a critical safety net. Never bypass it.
- **Bump `SyncState.stateVersion`** if you change the ID generation algorithm. This triggers automatic state reset on upgrade.
- **Keep `enableCompletionWriteback` opt-in (default: false).** Users should explicitly enable Obsidian file modification.

### Build System Notes

- The project uses simplified numeric IDs in `project.pbxproj` (001, 002, ..., 120) rather than standard Xcode UUIDs. This makes manual pbxproj edits easier but means Xcode may renumber them if it regenerates the file. If Xcode rewrites the project file, the IDs will change to standard UUIDs -- this is fine and expected.
- `MARKETING_VERSION` is `2.0` in the target build settings.
- `DEVELOPMENT_TEAM` is empty -- set your own team ID for code signing.
- The app compiles with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points to CommandLineTools.

### Troubleshooting

**"Access Denied" for Reminders:**
System Settings > Privacy & Security > Reminders > Enable for the app.

**Tasks not syncing:**
1. Verify the vault path is correct
2. Verify tasks use the `- [ ]` or `- [x]` format
3. Try "Reset Sync State" in Settings > Advanced

**Completion writeback not working:**
1. Ensure `enableCompletionWriteback` is toggled ON in Settings > General
2. Check that the file hasn't been modified since last scan (line content mismatch will abort safely)
3. Check `audit.log` for error details

**First sync after upgrade creates duplicate Reminders:**
This is expected. The v1 to v2 state version change clears all mappings. Delete the duplicates manually or reset from Reminders. Subsequent syncs will use the new content-hash IDs and remain stable.
