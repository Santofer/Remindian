# Obsync

A native macOS menu-bar application that syncs tasks between an [Obsidian](https://obsidian.md) vault (using the [Tasks plugin](https://publish.obsidian.md/tasks/Introduction) format) and Apple Reminders.

**Obsidian is the source of truth.** Tasks flow from Obsidian into Apple Reminders. Completion status can optionally be written back to Obsidian using surgical, metadata-preserving edits.

## Download

**[Download Obsync v1.0.0](https://github.com/Santofer/Obsync/releases/tag/v1.0.0)** — macOS 14.0+ (Sonoma or later)

> Since the app is not notarized, right-click the app and select **Open** on first launch to bypass Gatekeeper.

> **Transparency note:** AI (Claude) was used as a development tool during the creation of this app. The code has been reviewed, tested on real data, and the full source is open for anyone to audit. The app is sandboxed, creates automatic backups before every file modification, and includes a dry run mode for safe testing.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Data Model & Sync Flow](#data-model--sync-flow)
- [Critical Design Decision: Surgical Edits](#critical-design-decision-surgical-edits)
- [Task Identification: Content-Hash IDs](#task-identification-content-hash-ids)
- [Recurrence & Completion Handling](#recurrence--completion-handling)
- [Safety & Reliability Layers](#safety--reliability-layers)
- [Feature Reference](#feature-reference)
- [Configuration & Persistence](#configuration--persistence)
- [Build & Run](#build--run)
- [Distribution & Releases](#distribution--releases)
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
          +------------------+
          |   SyncManager    |  <-- @MainActor ObservableObject (singleton)
          |  (coordinator)   |      Bridges SyncEngine <-> UI
          +--------+---------+      Observes appearance changes for icon
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
- Swift 5, SwiftUI, macOS 14.0+ deployment target
- EventKit (Apple Reminders API)
- Carbon (RegisterEventHotKey for global shortcuts)
- UserNotifications (macOS notification center)
- No external dependencies

---

## Project Structure

```
Obsync/
├── ObsyncApp.swift                        # @main, MenuBarExtra (SF symbol, NSImage pointSize:14),
│                                          # AppDelegate (dock icon, hotkey, vault bookmark, Reminders access)
├── Info.plist                             # App metadata, LSUIElement, usage descriptions
├── Obsync.entitlements                    # Sandbox, Reminders, file access, bookmarks
├── Assets.xcassets/
│   ├── AppIcon.appiconset/                # 30 PNGs: 10 sizes × 3 variants (default, dark, tinted)
│   │                                      # Uses luminosity appearances in Contents.json
│   ├── AppIconDark.imageset/              # Standalone dark icon (512+1024) for programmatic dock icon
│   ├── AppIconLight.imageset/             # Standalone light icon (512+1024) for programmatic dock icon
│   ├── AccentColor.colorset/
│   └── Contents.json
├── Models/
│   ├── SyncTask.swift                     # Unified task model (Obsidian <-> Reminders)
│   ├── SyncConfiguration.swift            # All user settings, JSON-persisted, Codable
│   ├── SyncState.swift                    # Bidirectional ID mappings + hash tracking (version 6)
│   └── SyncLog.swift                      # Sync history entries (max 200)
├── Services/
│   ├── ObsidianService.swift              # Vault scanning, surgical edits, recurrence computation
│   │                                      # Contains RecurrenceResult, computeNextDate(),
│   │                                      # computeNextDateWhenDone(), buildRecurrenceLine()
│   ├── RemindersService.swift             # EventKit CRUD wrapper
│   ├── SyncEngine.swift                   # Core sync logic, conflict resolution, completion writeback
│   │                                      # Uses completionDiffers (not gated by oChanged)
│   ├── SyncManager.swift                  # UI coordinator, timer, hotkey, bookmarks,
│   │                                      # appearance observer, refreshDockIcon(), updateAppIcon()
│   ├── FileBackupService.swift            # Timestamped file backups with pruning
│   ├── NotificationService.swift          # macOS UserNotifications wrapper
│   ├── HotKeyService.swift                # Carbon global hotkey registration
│   └── AuditLog.swift                     # Append-only file modification log
└── Views/
    ├── ContentView.swift                  # Main window: dashboard, conflicts, history
    │                                      # openSettingsWindow() via NSApp.windows
    ├── SettingsView.swift                 # 3-tab settings (General, List Mappings, Advanced)
    │                                      # Force dark mode toggle, hide dock icon, hotkey
    ├── MenuBarView.swift                  # Menu bar dropdown
    └── SyncHistoryView.swift              # Expandable sync history list
```

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
- [ ] Monthly task 🔁 every month on the 20th when done 🛫 2026-02-20 📅 2026-03-08
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
   - Detect completion differences: completionDiffers = rTask.isCompleted != oTask.isCompleted
   - NOT gated by oChanged flag (critical fix — previously suppressed detection)
   - Task completed in Reminders but not Obsidian -> surgically mark complete in .md file
   - Task un-completed in Reminders but completed in Obsidian -> surgically mark incomplete
   - For recurring tasks: marks original as done, creates new recurrence line above
7. New Obsidian tasks (no mapping) -> create in Reminders
8. Save updated SyncState, return SyncResult
```

**Dry run mode:** When `config.dryRunMode == true`, the entire flow executes but skips all actual Reminders API calls and Obsidian file writes. The SyncResult reports what *would* have changed.

---

## Critical Design Decision: Surgical Edits

### The Problem (v1.0)

The original codebase had three dangerous methods in `ObsidianService`:
- `updateTask()` — called `toObsidianLine()` to reconstruct the full task line from parsed fields
- `addTask()` — same issue
- `deleteTask()` — removed lines, corrupting line-number-based sync state

`toObsidianLine()` only serialized fields that `SyncTask` explicitly modeled. Any metadata NOT captured by the parser was **permanently destroyed**:
- Recurrence markers: `🔁 every week`, `🔂 every 2 days`
- Custom inline metadata
- Non-standard formatting, indentation
- Any future Obsidian Tasks plugin fields

### The Solution (v2.0)

**All three dangerous methods are disabled.** They are marked `@available(*, deprecated)` and throw `ObsidianError.unsafeWriteDisabled` if called.

Two new **surgical edit** methods replace them:

```swift
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
4. For recurring tasks: create a new uncompleted recurrence line above the completed one
5. **Never reconstruct** the line — all other content (recurrence, dates, tags, formatting) is preserved exactly
6. Back up the file first via `FileBackupService`
7. Log the modification via `AuditLog`

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

**State versioning:** `SyncState.stateVersion` is set to `6`. On load, if the persisted version is older, all mappings are automatically cleared to prevent ID format corruption. This means the first sync after upgrading will re-create all Reminders entries.

---

## Recurrence & Completion Handling

### How recurrence works

When a recurring task is completed in Reminders and completion writeback is enabled, the app:

1. Marks the original task line as `- [x]` with `✅ YYYY-MM-DD`
2. Creates a **new uncompleted task line** above the completed one with updated dates
3. The new line preserves all original metadata (priority, tags, recurrence rule, etc.)

### Recurrence date computation

The `computeNextDate()` function in `ObsidianService.swift` returns a `RecurrenceResult` struct with both `referenceDate` (for due date) and optional `startDate`:

```swift
struct RecurrenceResult {
    let referenceDate: Date  // Next due date
    let startDate: Date?     // Next start date (from "on the Nth" rules)
}
```

**"when done" rules** (e.g., `every month on the 20th when done`):
- The **due date** (`📅`) advances by the pure interval (e.g., +1 month) from the **completion date**
- The **start date** (`🛫`) is computed from the "on the Nth" component — the next occurrence of that day after the completion date
- Example: completed Feb 8 → `🛫 2026-02-20 📅 2026-03-08`

**Regular rules** (no "when done"):
- The next occurrence is computed from the current due date using RRule-style logic
- Start dates are offset by the same interval

### Inserting start dates

`buildRecurrenceLine()` can INSERT a `🛫` start date into the new recurrence line even if the original didn't have one. It inserts before the `📅` due date marker. If a start date already exists, it updates it in-place.

### Supported recurrence patterns

- `every day`, `every 2 days`, `every 3 days`
- `every week`, `every 2 weeks`
- `every month`, `every 2 months`
- `every month on the 20th` (with specific day)
- `every year`
- All of the above with `when done` modifier

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
- Also resolved from security-scoped bookmark on launch; `resolveVaultBookmark()` sets `config.vaultPath = url.path`
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
- Sets `config.vaultPath` from resolved URL (fixes empty vault path on restart)
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
- **Completion writeback:** Enabled by default. When a task is completed in Apple Reminders, the Obsidian file is surgically updated to `- [x]` with completion date. Handles recurrence by creating new task lines.

### List Mapping
- Obsidian tags (`#work`, `#personal`) map to specific Reminders lists
- Configurable in Settings > List Mappings
- **Auto-mapping by capitalization:** if no explicit mapping exists, `#work` automatically maps to a "Work" list (capitalized first letter)
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
- Uses SF symbols via `NSImage.SymbolConfiguration(pointSize: 14)` for proper sizing
- `checkmark.circle.fill` when idle, `arrow.triangle.2.circlepath.circle.fill` when syncing
- Quick access to Sync Now, main window, settings

### App Icon
- **Light mode:** Purple gradient background with white checkmark circle (from user-designed assets)
- **Dark mode:** Dark background with purple checkmark circle
- **Tinted mode:** Tinted light variant for macOS tinted icon appearance
- All standard macOS sizes: 16, 32, 64, 128, 256, 512, 1024px (at 1x and 2x scales)
- Asset catalog uses `luminosity` appearances for automatic dark/tinted switching
- `AppIconDark` and `AppIconLight` separate image sets for programmatic dock icon switching
- `refreshDockIcon()` observes `NSApp.effectiveAppearance` changes and sets the correct variant
- Dark icon padded with `paddedIcon()` (100px inset on 1024 canvas) to match native dock icon sizing

### Force Dark Mode
- Toggle in Settings > General > "Force dark mode"
- Sets `NSApp.appearance = NSAppearance(named: .darkAqua)` — forces entire app UI to dark mode
- Also triggers `refreshDockIcon()` to show the dark icon variant
- Config key: `forceDarkIcon` (Bool, default: false)

### Hide Dock Icon
- Toggle in Settings > General > "Hide dock icon"
- Uses `NSApp.setActivationPolicy(.accessory)` to remove from dock
- App remains accessible via menu bar

---

## Configuration & Persistence

All persistent data is stored under `~/Library/Application Support/Obsync/` (sandboxed: `~/Library/Containers/com.obsync.app/Data/Library/Application Support/Obsync/`):

| File | Purpose | Format | Max Size |
|------|---------|--------|----------|
| `config.json` | User settings | JSON (Codable) | ~2 KB |
| `sync_state.json` | Task ID mappings + hashes | JSON (Codable) | Grows with task count |
| `sync_log.json` | Sync history | JSON (Codable) | 200 entries max |
| `audit.log` | File modification audit trail | Plain text | 5 MB (rotates) |
| `backups/` | File backups before writes | .md copies | 50 per file, 7 days |

**UserDefaults key:** `vaultBookmark` — security-scoped bookmark data for sandbox file access.

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
| `enableCompletionWriteback` | `Bool` | `true` | Write completions to Obsidian |
| `enableNotifications` | `Bool` | `true` | Send macOS notifications |
| `globalHotKeyEnabled` | `Bool` | `false` | Enable global shortcut |
| `globalHotKeyCode` | `UInt32` | `1` (kVK_ANSI_S) | Key code |
| `globalHotKeyModifiers` | `UInt32` | `0x0D00` (Cmd+Shift+Opt) | Modifier flags |
| `forceDarkIcon` | `Bool` | `false` | Force dark mode appearance |

All properties use `decodeIfPresent` with defaults for backward compatibility with existing config files.

---

## Build & Run

### Requirements
- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+
- Apple Reminders access (prompted on first launch)

### Build

```bash
# Command-line build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Obsync -configuration Debug \
  -destination 'platform=macOS' build

# Release build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Obsync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build clean build

# Or open in Xcode
open ObsidianRemindersSync.xcodeproj
```

### Entitlements (sandbox)

The app runs sandboxed with these entitlements:
- `com.apple.security.app-sandbox` — App Sandbox
- `com.apple.security.personal-information.calendars` — Reminders (EventKit) access
- `com.apple.security.files.user-selected.read-write` — User-selected file access (vault)
- `com.apple.security.files.bookmarks.app-scope` — Security-scoped bookmarks

### First Launch

1. Right-click the app → **Open** (required since the app is not notarized)
2. Grant Reminders access when prompted
3. Select your Obsidian vault directory via the file picker
4. (Optional) Configure list mappings in Settings > List Mappings
5. Sync will run automatically or click "Sync Now"

---

## Distribution & Releases

### Creating a new release

```bash
# 1. Build release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Obsync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build clean build

# 2. Create DMG
mkdir -p dist/dmg_staging
cp -R build/Build/Products/Release/Obsync.app dist/dmg_staging/
ln -sf /Applications dist/dmg_staging/Applications
hdiutil create -volname "Obsync" -srcfolder dist/dmg_staging \
  -ov -format UDZO dist/Obsync-vX.Y.Z.dmg
rm -rf dist/dmg_staging

# 3. Create GitHub release
gh release create vX.Y.Z dist/Obsync-vX.Y.Z.dmg \
  --title "Obsync vX.Y.Z" --notes "Release notes here..."
```

### Repository

- **GitHub:** https://github.com/Santofer/Obsync
- **Bundle ID:** `com.obsync.app`

---

## Known Limitations

1. **One-way sync for task creation:** New tasks can only flow from Obsidian to Reminders. Tasks created in Reminders are not synced back to Obsidian.

2. **Recurrence not synced to Reminders native recurrence:** Obsidian Tasks recurrence markers (`🔁`) are **preserved** in files and handled for completion writeback, but not mapped to `EKRecurrenceRule`. Reminders shows them as one-off tasks.

3. **Conflict resolution:** Only "Obsidian Wins" is implemented. The `ConflictResolution` enum has only one case.

4. **`toObsidianLine()` still exists:** The method in `SyncTask.swift` that reconstructs task lines is still present but deliberately never called by safe code paths. All current write paths use surgical edits.

5. **Line number fragility for writeback:** While task IDs are content-hash-based, `markTaskComplete()`/`markTaskIncomplete()` use `lineNumber` to locate the target line. If a file is modified between scan and writeback, the line content safety check catches the mismatch and aborts. Safe but means writeback can fail on actively-edited files.

6. **No file watcher:** The app polls on a timer. It does not use FSEvents or file system monitoring to detect changes in real-time.

7. **No undo for completion writeback:** Once a completion is written to an Obsidian file, there is no in-app undo. The backup file can be manually restored from the backups directory.

8. **Not notarized:** Without an Apple Developer account ($99/year), the app cannot be notarized. Users must right-click → Open on first launch.

9. **Tags not synced to Reminders tags:** Apple Reminders has a tags API but EventKit does not expose it. Tags are used only for list mapping.

---

## Version History

### v1.0.0 (Current Release — February 2026)

First public release. Complete rewrite from the original prototype.

**Core Sync:**
- Two-way sync: Obsidian Tasks → Apple Reminders, with completion writeback
- Surgical file editing — never reconstructs task lines, preserves all metadata
- Content-hash-based task identification (stable across line reordering)
- Sync state versioning (v6) with auto-reset on format change

**Recurrence:**
- Full recurrence support including "when done" rules
- Proper date computation: due date by pure interval, start date from "on the Nth"
- `RecurrenceResult` struct returns both `referenceDate` and optional `startDate`
- `buildRecurrenceLine()` can insert `🛫` start dates into new recurrence lines

**Completion Writeback:**
- Enabled by default
- Detects completion changes independent of other metadata changes (`completionDiffers` not gated by `oChanged`)
- Handles recurring tasks: marks original done, creates new recurrence line above
- Vault path resolved from security-scoped bookmark on launch

**List Mapping:**
- Tag-to-list mapping with auto-capitalization fallback (`#work` → "Work")
- Configurable default list
- Refresh available lists from Reminders

**UI & Appearance:**
- Custom app icons: Default (light purple), Dark (dark bg), TintedLight variants
- All macOS icon sizes (16-1024px) at 1x and 2x scales from user-designed assets
- Automatic dark icon switching via `NSApp.effectiveAppearance` observer
- Programmatic dock icon with padding to match native sizing
- Force dark mode toggle (`NSApp.appearance = .darkAqua`)
- Menu bar SF symbol at pointSize 14 via NSImage.SymbolConfiguration
- Settings window accessible from both menu bar and main window
- Fixed "Open Settings" button (replaced broken private API call)

**Safety:**
- Automatic file backups before every Obsidian modification
- Append-only audit log with rotation
- NSLock sync mutex
- Vault path validation
- Line content verification before writes
- Dry run mode

**Infrastructure:**
- Global hotkey (Cmd+Shift+Option+S)
- macOS notifications on sync errors
- Sync history (last 200 operations)
- Hide dock icon option
- App Sandbox with security-scoped bookmarks

### Pre-release (v1.0 prototype)

Initial prototype. One-way Obsidian to Reminders sync with basic conflict detection. **Had data loss bug** due to `toObsidianLine()` reconstruction destroying unmodeled metadata. All dangerous write methods now disabled.

---

## Handoff Notes for Future Development

### Code Quality Observations

1. **SyncEngine.swift is the most complex file (~500 lines).** The `performSync()` method is long and would benefit from extraction into smaller helper methods if further features are added.

2. **ObsidianService.swift contains significant recurrence logic.** The `computeNextDate()`, `computeNextDateWhenDone()`, `computeNextOccurrence()`, and `nextMonthlyOnThe()` methods handle all recurrence patterns. This could be extracted into a dedicated `RecurrenceService`.

3. **Error handling is thorough but inconsistent in style.** Some methods throw, some return optionals, some use Result. A future refactor could standardize on `async throws`.

4. **The `SyncTask.toObsidianLine()` method is dead code.** It still exists and could be removed entirely, or kept as documentation of the Obsidian Tasks format.

5. **RemindersService uses a completion-handler-to-async bridge** for `fetchReminders()`. This could be modernized to use EventKit's native async APIs on macOS 14+.

6. **The Carbon HotKeyService** uses legacy C-function-pointer callbacks. This works but is fragile. Consider migrating to `CGEvent` tap or a Swift wrapper if Carbon support is deprecated.

### Key Technical Details

**Completion detection fix:** In `SyncEngine.swift`, `completionDiffers = rTask.isCompleted != oTask.isCompleted` is computed independently of `oChanged`. Previously it was gated by `!oChanged`, which suppressed completion detection whenever any metadata changed. This was a critical bug.

**Vault path fix:** `resolveVaultBookmark()` in `SyncManager.swift` now sets `config.vaultPath = url.path` from the resolved URL. Previously, `vaultPath` was empty after app restart because the bookmark resolved the URL but never stored the path back to config.

**Dark icon sizing:** When programmatically setting `NSApp.applicationIconImage`, the image appears larger than native asset catalog icons. `paddedIcon()` creates a 1024×1024 canvas with 100px inset to match native sizing. Light mode uses `applicationIconImage = nil` to let macOS handle it natively.

**Menu bar icon sizing:** SwiftUI `.font()` modifiers are ignored in `MenuBarExtra` labels. The workaround is to create an `NSImage` from the SF symbol using `NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)` and wrap it in a SwiftUI `Image(nsImage:)`.

### Potential Future Improvements

1. **FSEvents file watcher:** Replace timer-based polling with real-time file system monitoring. Would require careful debouncing.

2. **Bidirectional task creation:** Allow new Reminders tasks to sync back into Obsidian. Complex because it requires choosing a target file and position.

3. **Native recurrence sync:** Map Obsidian Tasks recurrence rules to EKRecurrenceRule. Non-trivial due to format differences.

4. **Multi-vault support:** Currently single vault only. Would require refactoring SyncState and SyncConfiguration to be vault-scoped.

5. **Unit tests:** No test suite exists. Priority test targets:
   - `SyncTask.fromObsidianLine()` parsing (many edge cases)
   - `computeNextDate()` with various recurrence rules and "when done"
   - `ObsidianService.markTaskComplete()` with various line formats
   - `buildRecurrenceLine()` with/without existing start dates
   - `SyncEngine.performSync()` with mock services

6. **Sparkle for auto-updates:** Add the [Sparkle framework](https://sparkle-project.org/) so users get prompted when new versions are available.

7. **Apple Developer notarization:** Sign and notarize the app ($99/year Apple Developer account) so users don't need to right-click → Open on first launch.

8. **iOS companion app:** Would require CloudKit or a shared backend to bridge between iOS Reminders and Obsidian vault (which lives on macOS).

9. **Dataview tasks support:** Parse Dataview-style task metadata in addition to Tasks plugin format.

### Key Invariants to Maintain

- **Never call `toObsidianLine()` in any write path.** This is the root cause of the prototype's data loss. All Obsidian file writes MUST be surgical (modify only what's needed, preserve everything else).
- **Always back up before writing.** Every code path that modifies an Obsidian file must call `FileBackupService.backupFile()` first.
- **Always verify line content before writing.** The `lineContentMismatch` check in `markTaskComplete()`/`markTaskIncomplete()` is a critical safety net. Never bypass it.
- **Bump `SyncState.stateVersion`** if you change the ID generation algorithm. This triggers automatic state reset on upgrade.
- **Completion detection must not be gated by `oChanged`.** The `completionDiffers` check must always run independently.

### Build System Notes

- The project uses simplified numeric IDs in `project.pbxproj` (001, 002, ..., 120) rather than standard Xcode UUIDs. This makes manual pbxproj edits easier but means Xcode may renumber them if it regenerates the file. If Xcode rewrites the project file, the IDs will change to standard UUIDs — this is fine and expected.
- `MARKETING_VERSION` is `1.0.0` in the target build settings.
- `DEVELOPMENT_TEAM` is empty — set your own team ID for code signing.
- The app compiles with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points to CommandLineTools.
- **Bundle ID:** `com.obsync.app`

### Troubleshooting

**"Access Denied" for Reminders:**
System Settings > Privacy & Security > Reminders > Enable for the app.

**Tasks not syncing:**
1. Verify the vault path is correct (Settings > General)
2. Verify tasks use the `- [ ]` or `- [x]` format
3. Check excluded folders don't include your task files (Settings > Advanced)
4. Try "Reset Sync State" in Settings > Advanced

**Completion writeback not working:**
1. Ensure `enableCompletionWriteback` is toggled ON in Settings > General
2. Verify vault path is not empty (restart app if needed — bookmark resolution sets it)
3. Check that the file hasn't been modified since last scan (line content mismatch will abort safely)
4. Check `audit.log` for error details

**App icon not changing in dark mode:**
The app observes system appearance changes. If the icon is stuck, try toggling "Force dark mode" in Settings, or quit and relaunch the app.

**Tasks going to wrong Reminders list:**
1. Check list mappings in Settings > List Mappings
2. Auto-mapping capitalizes the first letter of the tag (e.g., `#work` → "Work")
3. If no matching list exists, tasks go to the default list
