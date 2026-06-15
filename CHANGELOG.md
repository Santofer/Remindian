# Changelog

All notable changes to Remindian (formerly Obsync) are documented here.

---

## v5.22.1 (June 2026)

A leaner menu: actions first, status consolidated at the bottom.

### Menu bar

- **Removed the "Remindian" title bar** at the top — the menu now opens straight on **Sync Now**.
- **Moved the sync status badge** (Synced / Syncing / Conflicts / No access) out of the old title bar and into a single status hub at the bottom, next to the **"synced 11 min ago"** timing and this sync's task-count chips. The standalone "Last sync …" line in the actions list is gone — it lives in the status hub now. The DRY-RUN marker moved there too.
- **"Quit Remindian" → "Quit."**

---

## v5.22.0 (June 2026)

Quick-add now understands recurrence — in English and French.

### New

- **Recurring tasks from the menu's quick-add.** Type a repeat phrase and the task is created as a proper recurring Obsidian Tasks task (`🔁 every …`) that becomes a **repeating Apple Reminder** on the next sync. Understands both languages:
  - English: `every day` / `every 2 weeks` / `every month` / `every 3 months` / `every year`, and the adverbs `daily` / `weekly` / `monthly` / `yearly` / `annually`.
  - French: `tous les jours` / `toutes les 2 semaines` / `tous les mois` / `chaque semaine` / `tous les ans`, and `quotidien` / `hebdomadaire` / `mensuel` / `annuel`.
  - Combines with everything else: `Payer le loyer vendredi tous les mois #maison !!!` → title "Payer le loyer", due Friday, repeats monthly, tag #maison, high priority.

  Scope note: day/week/month/year intervals are supported end-to-end (they round-trip to a real repeating reminder). Day-of-week rules like "every monday" are not yet parsed from quick-add — a phrase like that is treated as a one-off due date for now. Times of day aren't captured, since the Obsidian Tasks format is day-granularity.

---

## v5.21.2 (June 2026)

A refreshed menu, and the last class of "file changed" completion errors gone.

### Bug fixes

- **"File has changed since last scan. Expected line content doesn't match…" when completing a task.** This was a *second*, distinct cause from the one fixed in v5.21.1. The menu's Today list stores each task's line *number* and text from the last scan. When a sync rewrites lines a moment later (e.g. completing a recurring task inserts its next occurrence and shifts everything below it), that stored line number now points at a *different* task — so checking the task off compared the wrong line and refused with an error. Completion (and all writeback) now **relocate the task by its content** rather than trusting a line index: it finds the task by a stable identity (title + metadata, ignoring checkbox state and the `✅ date`), and:
  - if the task was already completed by the sync, it's a silent success — no error;
  - it **never** edits a different task that happens to sit at the stale line, which is now covered by a dedicated safety test;
  - the same robustness applies to the Generic Markdown source, and the Today list re-scans after each completion so finished tasks drop off immediately.

### Menu bar

- **The menu-bar panel got a proper redesign.** A compact header with a tinted status pill (Synced / Syncing / Conflicts / No access) instead of a bare colored dot; Today rows now show a small priority dot, a circular check that fills on hover, and a tinted due capsule ("Today", "2d late", "Jun 18"); a rounded quick-add field that highlights on focus; last-sync results as compact colored chips; and a subtle rounded hover highlight on every row. Each task is still exactly one line, the panel still auto-sizes (no scroll-collapse), and everything respects light/dark mode.

---

## v5.21.1 (June 2026)

Hotfix: completing a task from the menu no longer fails with a false "file modified" error.

### Bug fixes

- **"File was modified during sync operation. Skipping write for safety." when completing tasks.** Each sync compares every file's modification time against a single sync-start timestamp to refuse writing into a file something else changed mid-sync. But the engine's *own* writebacks (marking a task done, updating its metadata) bump that file's modification time — so a second task living in the same file (or in a file iCloud re-touched mid-sync) tripped the guard and was skipped, surfacing as several "file modified" errors when you completed something from the menu. The engine now remembers the files it wrote itself this cycle and no longer treats its own writes as outside interference. The real protection (line-level content verification before any edit) is unchanged.

---

## v5.21.0 (June 2026)

Cleanup tools + a menu fix, after diagnosing duplicate build-up from older buggy versions.

### New

- **Remove Duplicate Reminders.** Settings → Advanced → Troubleshooting (Apple Reminders only) now has a **Remove Duplicate Reminders…** action. It finds reminders that are exact duplicates — same title, due date, and list — left over from older versions that created the same reminder repeatedly, and removes all but one of each. The copy carrying the `obsidian://` link (your synced canonical one) is always kept, and it shows a count + confirmation before deleting. Obsidian stays your source of truth, so anything still in your vault is re-created on the next sync.

### Bug fixes

- **The menu "Today" list no longer shows duplicates.** It now de-duplicates by title + due day, so a task that exists in more than one vault file (e.g. your inbox *and* its project note) appears once instead of several times.

---

## v5.20.4 (June 2026)

Critical hotfix for v5.20.3.

### Bug fixes

- **The menu bar opened to an empty panel in v5.20.3.** The height-capping `ScrollView` added in v5.20.3 collapses to zero height in a window-style menu (a `ScrollView` is greedy vertically and has no fixed height to fill), so the whole menu showed nothing. Reverted to an auto-sizing panel — the Today list is already capped at 6 rows, so there's no overflow risk. The menu renders correctly again, with each task on one line.
- Widened the menu panel slightly so longer task titles aren't truncated as aggressively.

**If you installed v5.20.3 and the menu is blank, upgrade to this version.**

---

## v5.20.3 (June 2026)

Menu-bar overhaul + a sweep of fixes from a full multi-dimension audit of the app.

### Menu bar

- **The menu now renders as a proper panel** (`.window` style). Previously the menu-bar dropdown used the native menu style, which split each Today-list task into separate stacked lines (checkbox, then title, then "overdue") — a mess. Now **each task is one clean line**, and the quick-add field works as intended. The panel is height-capped and scrolls instead of overflowing the screen on long lists.

### Bug fixes (from the audit)

- **Another UI freeze fixed.** Completing a task from the Today list ran a full file backup + read + write **on the main thread**, freezing the menu on large notes — the same class of bug as the earlier Today-list scan. Both completing a task and quick-adding now do their file work off the main thread.
- **Undo could corrupt a note with a duplicate name.** Two vault files sharing a basename (e.g. a per-folder `Inbox.md`) could collide in the backup store, so "Undo last sync" might overwrite one with the other's content. Backups are now disambiguated by full path (with a regression test).
- **Fixed a data race** on the backup manifest (written from the sync engine off-main and from quick-add on-main) — now lock-guarded.
- **Shortcuts/automation no longer pop a modal file picker.** Quick-add and Sync from a Shortcut, the auto-sync timer, the file watcher, and the global hotkey now run non-interactively instead of stealing focus with a vault-picker dialog.
- **Single-task actions sync only the active profile** (quick-add, completing a Today item) instead of sweeping every enabled profile and rebuilding everything — much faster.
- **TickTick tokens now persist to `profiles.json`** (they were written only to the legacy config file and could be lost on reload).

The audit surfaced 22 verified issues; the highest-impact ones are fixed here, the rest (minor performance edges) are tracked for follow-up.

---

## v5.20.2 (June 2026)

Critical hotfix.

### Bug fixes

- **App froze / beachballed when opening the menu (regression from v5.19.0).** The new menu-bar "Today" list scanned the entire vault on the **main thread** every time the menu appeared, which locked up the whole app on real vaults. The scan now runs on a **background task** (the UI never blocks), and the refresh is re-entrancy-guarded and throttled so the menu can open freely. If you upgraded to v5.19–v5.20.1 and the app became unresponsive, this fixes it.

---

## v5.20.1 (June 2026)

Correctness fix for Reminders → Obsidian writeback (#75, PR #74).

### Bug fixes

- **Due-date changes made in Apple Reminders are no longer silently lost.** With "Sync due date changes back" enabled, if the task's `.md` file's modification time bumped between the start of a sync and the writeback check (Obsidian indexing, Spotlight, a file-watcher tick…), the writeback was skipped **but the sync state was still advanced as if it had succeeded** — so the next sync saw nothing to retry, and a later "Obsidian wins" pass pushed the stale Obsidian date back, reverting the user's Reminders edit on both sides. Now the pre-sync hashes are preserved when the file-modification guard skips a writeback, so the next sync re-detects the change and retries, and the skip is surfaced as a non-fatal logged error.
- **No more phantom "N updated" on every sync.** A task in the inbox (no `#tag`) or whose tag differed in case from the list name was reported "updated" forever, because the stored reminders-side hash was seeded from the Obsidian task (empty/lowercase list) instead of the live reminder's resolved list. The reminders-side hash is now seeded with the resolved destination list, so the two agree and the redundant re-push stops.

With thanks to the contributor who root-caused both bugs and provided the fix and regression tests (`FileModSkipRegressionTests`).

---

## v5.20.0 (June 2026)

Due times and alarms for Apple Reminders.

### New

- **Alarms on synced reminders (#6).** Apple Reminders only notify you if the reminder has an *alarm* — and until now Remindian never set one, so synced reminders were silent. Settings → General → **Add an alarm to reminders** (Apple Reminders only) now gives each synced reminder with a due date an alarm: at its specific time if it has one, otherwise at a configurable hour (default **09:00**) for all-day tasks. **Off by default** — existing reminders and their alarms are never touched; the alarm is only added to reminders that don't already have one, so repeated syncs never pile up duplicates.
- **Due times from Obsidian.** The task parser now optionally reads a time after a date — `📅 2026-03-15 14:30` or `📅 2026-03-15T14:30` (also for `🛫` start). With "Include time in due dates" enabled, that time flows through to the reminder (and its alarm). Plain `📅 2026-03-15` lines behave exactly as before.

### Tests

- New `TimeAndAlarmTests` (due-time parsing incl. back-compat for date-only lines, and alarm fire-date computation: all-day hour, exact time, time-sync-off fallback, hour clamping). Full suite green; Release build clean.

---

## v5.19.0 (June 2026)

A "Today" glance right in the menu bar.

### New

- **Today list in the menu bar.** The menu now shows your open tasks **due today or overdue**, soonest first, with overdue ones flagged in red. Click the circle next to any task to **complete it inline** — it's marked done in your vault (the source of truth) and synced to your destination, without opening Obsidian or Reminders. The list refreshes when you open the menu; long lists show the first few with a "+ N more…" link to the main window.

### Tests

- New `AgendaBuilderTests` (overdue + due-today selection, exclude completed / no-date, soonest-first ordering, overdue boundary). Full suite green; Release build clean.

---

## v5.18.0 (June 2026)

Capture from anywhere — Shortcuts/Spotlight actions and a menu-bar quick-add with natural-language parsing.

### New

- **macOS Shortcuts & Spotlight actions.** Remindian now ships two App Intents:
  - **Sync Now** — runs a sync of all enabled profiles (e.g. "Hey Siri, sync Remindian", or as a step in any Shortcut / automation).
  - **Add Task to Obsidian** — capture a task into your vault inbox from a Shortcut, Spotlight, or the Share sheet.
- **Menu-bar quick-add.** A text field in the menu bar: type a task, press Return, and it's captured into your Obsidian inbox and synced. Understands **natural-language dates** ("friday", "tomorrow 3pm", "April 15"), **priority** (`!` / `!!` / `!!!`), and **`#tags`** — e.g. `Pay rent friday !! #home`.

Quick-add writes to the **active profile's** source inbox (Obsidian stays the source of truth), then syncs so the task reaches your destination.

### Tests

- New `QuickAddParserTests` (dates parsed + stripped, priority levels, `!`-in-word ignored, tags, combined, edge cases). Full suite green; Release build clean.

---

## v5.17.0 (June 2026)

Confidence features — see exactly what a sync will do before it happens, and roll back the file changes it made.

### New

- **Preview Changes.** A new **Preview Changes…** action (menu bar) opens a window that runs a forced dry-run across all enabled profiles and shows precisely what *would* change — grouped into create / update / delete in the destination, and complete / write-metadata back to Obsidian — with the affected file paths. Nothing is written until you click **Apply Changes**. It mutates nothing on disk (dry-run skips every write and the state save), so previewing is always safe.
- **Undo Last Sync.** After a sync that wrote back to your vault, an **Undo Last Sync** action restores those Obsidian files to their exact pre-sync content. It's built on the automatic per-edit backups, targets each file by its recorded original path, and **backs up the current content first** — so the undo is itself reversible. (Scope: this restores *vault* files changed by writeback; reminders created in your destination aren't auto-removed — use Preview to vet those before applying.)

### Tests

- New `FileBackupRestoreTests` (pre-edit content round-trip, restore-backs-up-current, original-path recorded). Dry-run change-list population is covered by the existing engine/parser suites. Full suite green; Release build clean.

---

## v5.16.0 (June 2026)

Multiple sync profiles — Remindian becomes a sync **hub** instead of a single pipe. Fully backward compatible: your current setup becomes the "Default" profile automatically and behaves exactly as before.

### New

- **Sync profiles.** Settings → General → **Sync Profiles** lets you run several independent source → destination pipelines at once — e.g. *Work vault → Todoist* and *Personal vault → Apple Reminders*. Each profile has its own source, destination, vault, list mappings, filters, writeback toggles, tokens, and **its own sync state**, so their mappings never collide.
  - Add / rename / delete / pause profiles. "Sync Now" (and auto-sync, and the file watcher) run **all enabled profiles**; paused profiles are skipped.
  - The settings panes always edit the **selected** profile — pick a profile at the top of General and everything below applies to it.
  - App-wide settings (global hotkey, launch-at-login, notifications, auto-sync interval, dock/appearance) stay consistent across all profiles automatically.

### Migration & safety

- Your existing `config.json` is migrated into a single **Default** profile on first launch, and that profile keeps using the existing `sync_state.json` **verbatim** — zero migration, no mapping loss, no re-sync. Additional profiles get their own `sync_state_<id>.json`.
- Each profile can point at a different vault; Remindian stores a security-scoped bookmark per vault path. A profile whose vault isn't yet authorized reports a clear, actionable message instead of failing silently.
- The Obsidian Tasks parser, the surgical writeback engine, and all existing Settings bindings are untouched — multi-profile is an additive layer around the proven single-profile path.

### Tests

- New `ProfileStoreTests` (migration shape, normalization invariants, deep copy, global-settings propagation, Codable round-trip) and extended `SyncStateLocationTests` (per-profile state file keying, isolation, default-file-untouched, no cross-seed). Full suite green; Release build clean.

---

## v5.15.0 (June 2026)

Generic Markdown source (#27) — Remindian now syncs **NotePlan** and other plain-markdown task tools, not just Obsidian. Additive and opt-in; the Obsidian Tasks path is completely untouched.

### New

- **Generic Markdown task source.** Settings → General → Task Source now offers **Generic Markdown (NotePlan, etc.)**. It reads tasks written with a *configurable token dialect* instead of Obsidian's emoji:
  - **Due / start / done dates** via a configurable prefix — defaults to NotePlan's `>2025-01-20` (due) and `@done(2025-01-20)` (done). Both bare (`>2025-01-20`) and parenthesized (`@done(2025-01-20)`) forms are understood.
  - **Priority** via configurable tokens — defaults to `!!!` / `!!` / `!` (high / medium / low).
  - **File extensions** (default `md`, `txt`), checkbox markers, and `#tags`.
  - Tasks use `- [ ] / - [x]` checkboxes (also `*` and `+` bullets).
  - Two-way sync works: completion, due/start dates, priority, tags, and new-task creation are written back surgically in the same dialect, verifying the line before editing so a concurrent external change aborts the write rather than clobbering it.

### Notes

- This is a **separate parser and writer** from the Obsidian Tasks engine — the proven Obsidian path carries zero regression risk. Recurrence is not parsed in the generic dialect (recurrence conventions vary too much between tools); everything else round-trips.

### Tests

- New `GenericMarkdownTests` (20 cases): NotePlan parsing, longest-priority-token wins, `!`-inside-a-word is not a priority, multiple bullet styles, full field round-trip (`parse(build(task)) == task`), surgical completion/incompletion preserving other tokens, metadata add/replace/remove, plus source-level scan + writeback against real temp files and a write-aborts-on-line-mismatch safety test. Full suite green.

---

## v5.14.0 (June 2026)

Multi-device sync state (#15). Opt-in, backward compatible — existing installs keep their current per-machine behavior untouched.

### New

- **Share sync state across your Macs.** Settings → Advanced → **Sync State Storage** now offers a choice: keep the mapping table in Application Support (this Mac only — the default and previous behavior) or store it **inside your vault** at `.remindian/sync_state.json`. With vault storage, whatever you already use to sync your vault across machines (Obsidian Sync, iCloud Drive, Dropbox, git…) also carries the Obsidian↔reminders mappings — so a second Mac **reuses the existing reminders instead of recreating duplicates**.
  - The first time you switch to vault storage, this Mac's existing mappings are copied into the vault, so nothing is lost.
  - Remindian reloads the shared state at the start of every sync, so each device picks up the other's changes. (For best results, avoid syncing on two Macs at the exact same moment.)
  - Requires no new permissions — Remindian already writes task files into your vault.

### Notes

- **iCloud-container storage was intentionally not added.** It requires a paid Apple Developer membership and a provisioned iCloud container, which can't be tested or shipped reliably right now. The vault option reaches the same multi-device outcome through the vault sync you already have.
- The on-disk state format is unchanged — switching location back and forth never changes the schema, and old `sync_state.json` / `config.json` files load as before (the new setting defaults to Application Support when absent).

### Tests

- New `SyncStateLocationTests`: vault path resolution + `.remindian` creation, lossless round-trip, per-vault isolation, safe degradation on an empty vault path, on-disk format compatibility, and backward-compatible config decoding. Full suite green.

---

## v5.13.0 (June 2026)

Performance — large vaults and multi-list Reminders accounts sync noticeably faster. Behavior is identical (the full test suite passes unchanged); only the speed differs. No config or sync-state format change.

### Performance

- **Parallel Apple Reminders fetch.** Reminders were fetched one list at a time, each waiting for the previous EventKit round-trip to finish. They're now fetched **concurrently** — on an account with several lists this collapses N sequential round-trips into one batch. Error handling is unchanged: if any list fails, the whole fetch fails exactly as before.
- **Incremental vault scan.** A full sync used to re-read and re-parse *every* markdown file in the vault, even when only one file changed (the common case for a file-watcher-triggered sync). Remindian now keeps an in-memory parse cache and **reuses the previous parse for any file whose modification date and byte size are both unchanged** — so a watcher-triggered re-sync on a large vault re-parses just the file you edited instead of thousands. The cache is a pure performance layer: it always produces the complete task set, the stamp is captured *after* reading (so any later write is guaranteed to invalidate it), and the parse parameters (status markers, vault path) are part of the cache key — worst case it behaves exactly like a full re-scan, never a stale or partial result.

### Tests

- New `ObsidianServiceParseCacheTests` proves the invariant that matters: a cached scan is byte-for-byte equal to a cold, from-scratch scan across edits, same-size edits, deletions, new files, marker changes, and a 40-step randomized edit fuzz. Full suite green.

---

## v5.12.0 (June 2026)

Things 3 reliability — sync no longer feels "stuck" when macOS Automation permission is missing. No config or sync-state format change.

### Bug fixes

- **Things 3 sync hung or silently did nothing when Automation permission was denied (#56).** When macOS hadn't granted Remindian permission to control Things 3, every AppleScript call failed with error `-1743` (or `-1744`). The old code treated that like any transient failure: it retried with a launch preamble, ground through all five lists plus the Logbook, and could end up reporting an empty task set — which looked like a hang or, worse, like Things 3 had been wiped. Remindian now recognises the permission errors specifically, **fails fast with an actionable message** ("Open System Settings → Privacy & Security → Automation, turn ON the Things3 switch… or run `tccutil reset AppleEvents com.remindian.app`"), and skips the pointless retries. A denied permission is reported clearly in seconds instead of stalling the sync.
- **One unresponsive Things 3 list no longer aborts the whole fetch.** A timeout on a single list (e.g. a huge Logbook) used to throw away every other list's tasks. The fetch now continues with whatever lists respond and surfaces the failed ones as warnings, so a partial result beats no result.

### Tests

- New classifier tests assert `-1743`/`-1744` map to the actionable not-authorized error (no retry), other AppleScript errors keep their original message, and the guidance text names the exact Settings location and the `tccutil` fallback. Full suite green.

---

## v5.11.0 (June 2026)

Performance hardening + correctness fixes. No config or sync-state format change — existing installs upgrade transparently.

### Bug fixes

- **International characters stripped from TaskNotes filenames (#73).** The filename slug used an ASCII-only filter that *deleted* accented letters: "Från Mac till lördag" became `frn-mac-till-lrdag.md`. It now transliterates Latin diacritics (å→a, ö→o, ñ→n) so the file is `fran-mac-till-lordag.md`, and falls back to a stable `task-<id>` token when a fully non-Latin title (e.g. CJK) would otherwise produce an empty filename. The displayed task title was always preserved in the file's YAML frontmatter — this only affected the on-disk filename. Applied to all three slug sites (file creation, CLI create, CLI fallback). Thanks @bms53.
- **Silent data loss when reconnecting a task to an existing reminder.** In the dedup-reconnect path, the content push used `try?` and then stored the mapping with the current hash regardless — so if the push failed (EventKit hiccup, permission), the next sync saw "no change" and never retried, losing the update silently. Now the error surfaces in the sync result and the mapping is stored with an empty hash to force a retry on the next sync.

### Performance

A rearchitecture for large vaults — behavior is identical (the full pre-existing test suite passes unchanged), only the speed differs.

- **O(1) mapping lookups.** `SyncState` gained in-memory `obsidianId`/`remindersId` → mapping indexes. The sync engine's per-task `findMapping` calls were linear scans inside per-task loops — O(n²) on the mapping count. They're now O(1). The on-disk `sync_state.json` format is unchanged (only the `mappings` array is persisted; indexes are rebuilt on load).
- **Compile parser regexes once.** `SyncTask.fromObsidianLine` recompiled ~13 `NSRegularExpression` objects on every task line. They're now `static let` constants compiled once — a large win when scanning thousands of tasks. (Verified output-identical by the existing parser test suite.)
- **Micro-opts.** The dedup sort's mapping-existence check is now an O(1) index lookup, and two O(n²) `while contains("  ")` space-collapse loops became a single regex pass.

### Tests

- New `TaskNotesSlugTests` (slug transliteration, CJK fallback, filename-safety property test), `SyncStateIndexTests` (index/array consistency across add/update/remove/reconnect, Codable round-trip, legacy-payload decode, mutation fuzz), and `SyncEngineReconnectFailureTests` (push-failure surfaces error + forces retry; happy path stores real hash). Full suite ~250 cases, all green.

### Not in this release

- **macOS 12 Monterey support (#72).** The app is built on `MenuBarExtra` and `NavigationSplitView`, both macOS 13 APIs that underpin the entire menu-bar UI. Supporting Monterey would require an `NSStatusItem` rewrite — tracked as a possible future effort, gauging demand on #72.

### Thanks

@bms53 for #73.

---

## v5.10.1 (May 2026)

### Feature: Ignore specific status markers (#70)

Builds on the v5.9.0 custom-status-marker work (#63). Some plugin workflows use checkbox-shaped lines that **aren't actually tasks** — for example `[i]` for informational entries inside a task list. Until now those would parse as tasks and sync as reminders, which wasn't what users wanted.

New **Settings → Sync Options → Ignored markers** field. Comma-separated single characters: any line whose checkbox marker matches the set is dropped at the parser level — the sync engine never sees it.

Precedence: if a user puts the same character in both the open/completed lists and the ignored list, **ignored wins**. That's the safer default ("don't touch this" beats "treat as open"). Empty by default; existing users see zero behavior change until they configure it.

### Tests

New `IgnoredMarkersRegressionTests` — 9 tests covering: marker returns nil, back-compat (same input without ignored config still parses), ignored-beats-open precedence, ignored-beats-completed precedence, normal `[ ]`/`[x]` still work when ignored is configured, multiple ignored markers all respected, end-to-end vault scan skips ignored lines, Codable round-trip, and pre-v5.10.1 config decodes with empty default.

### Thanks

@itauberg for the clear feature request.

---

## v5.10.0 (May 2026)

### Cleaner Obsidian URI handling in Apple Reminders (#69)

Previously, when **Add task link to Reminders** was on, the `obsidian://` URL was written *both* into the reminder's native `url` field (where Apple Reminders renders it as a single clickable Obsidian icon) *and* appended into the reminder's notes body as a long percent-encoded line. The notes-side copy was visual clutter that obscured any real note content.

v5.10 makes the notes-side append opt-in. New **Settings → Sync Options → Also append URL to notes (legacy clients)** toggle, indented under the existing **Add task link to Reminders**. Defaults to **off** — including for users upgrading from v5.9.x, who'll see cleaner reminders on their next sync without touching anything. If you use a client that doesn't display the URL field (some older third-party Reminders apps), re-enable the toggle and the notes-side fallback comes back.

### Migration

Existing serialized configs decode the new `appendTaskLinkToNotes` field as `false` via `decodeIfPresent`. The first sync after upgrade rewrites the notes of any synced reminder to remove the old URL line. This is reversible (toggle the option back on, sync again, the URL reappears) — and not destructive: only the URL line gets stripped, any other notes content is preserved.

### Tests

New `ObsidianURIHandlingTests` — 5 tests:
- Clean-by-default: URL on `reminder.url`, NOT in notes.
- Opt-in append: URL in both places.
- No link at all when the master toggle is off.
- Pre-v5.10 config decodes with clean default (migration safety).
- Codable round-trip preserves the new toggle.

### Thanks

@Gouryella91 for the clear feature request with screenshots.

---

## v5.9.1 (May 2026)

### Bug fix: `maxCompletedTaskAgeDays` not honored on writeback (#68)

The age cutoff was only applied to the source scan (Step 1) and not to the Reminders → Obsidian writeback path (Step 6). Users with `enableNewTaskWriteback = true` and a long history of completed reminders in Apple Reminders saw every old completion written into their vault on the next sync — recreating the exact symptom that #11 was originally filed for.

The fix extracts the source-side filter into two reusable static helpers (`SyncEngine.completedTaskCutoffDate(for:)` and `SyncEngine.isCompletedTaskTooOld(_:cutoff:)`) and applies them on both sides. In the writeback loop the age filter runs **after** the v5.8.2 title-dedup so the dedup's `syncState.addOrUpdateMapping(...)` side-effect is preserved for old reminders whose titles match an existing vault task.

Also fixes a latent calendar-arithmetic fallback: the original `Calendar.date(byAdding:) ?? Date()` would have silently filtered every completed task if `byAdding:` returned nil. New fallback is `?? .distantPast`, which degrades to "keep everything" instead.

### Internal

- New designated `SyncEngine.init(source:destination:syncState:)` exposes the `SyncState` seam so tests can drive `performSync(...)` without touching the real Application Support directory. Production callers use the existing two-argument `convenience init` and are unaffected.

### Tests

- New `AgeFilterWritebackRegressionTests` — 9 tests total. 6 unit tests cover the helpers (boundary semantics, fallback to `lastModified`, disabled-setting short-circuit). 3 integration tests drive `performSync(...)` end-to-end with mock `TaskSource` / `TaskDestination` so the writeback call site itself is exercised — without these, a future refactor that inverted the `if` would pass the unit tests but reintroduce the bug. One integration test (`testWritebackPreservesDedupMappingForOldMatchedReminders`) specifically locks in the ordering with v5.8.2's title-dedup.

### Thanks

@mlsimon734 for filing the bug, doing the analysis, and submitting the PR — exemplary contribution.

---

## v5.9.0 (May 2026)

Four issues resolved, all reported on 2026-05-03 by @cjhille (a Task-Board / hierarchical-tag user). Shipped together because they share the same parser code surface and benefit from a coordinated release cycle.

### Features

- **Custom inline status markers (#63).** New `Settings → Sync Options → Custom status markers` configures which characters inside `[ ]` count as "open" or "completed". The standard `[ ]` (open) and `[x]`/`[X]` (completed) are always recognized. Plugins like Task-Board introduce additional markers: `[/]` in progress, `[?]` waiting, `[<]` ready, `[-]` cancelled. Add them via comma-separated single characters. Backwards-compatible: existing users with default config see zero behavior change. The completion-writeback path (`markTaskComplete` / `markTaskIncomplete`) now widens its replacement to handle any marker character, so marking a `[/]` task complete writes `[x]` (and removes the custom marker) rather than failing the "already complete" guard.

### Bug fixes

- **Hierarchical tag mapping (#64).** `resolveTargetList` now tries the most-specific hierarchical path first when matching against `listMappings`. For a task tagged `#task/work`, a mapping for `task/work` wins over a mapping for the bare `task`. Falls back to the root segment if there's no specific mapping (preserving legacy behavior). The full hierarchical path was already correctly preserved in the `tags` array — this fixes the routing side.
- **URL fragment `#section` parsed as tag (#65).** The parser now computes "protected ranges" — substrings where tag-like patterns must be ignored: HTTP/HTTPS URLs, wikilinks `[[Note#header]]`, and inline code spans. Tag-regex matches whose start position falls inside any protected range are dropped. Markdown links `[label](url)` and bare URLs are both covered. Implementation is pure (no content mutation) for auditability.
- **Subtask tag inheritance (#66 Phase 1).** Indented child tasks without their own `#tag` now inherit the `targetList` and routing tag from their nearest preceding less-indented parent. Implemented as a second pass over the parsed tasks in `ObsidianService.parseTasksFromFile` using a stack-based ancestor walk. Children with their own tag still win — inheritance only applies to untagged children. This solves the *list-routing* half of the subtask use case; real parent/child *nesting* at the destination (EKReminder `parentItem`, TickTick `parentId`, etc.) is a separate, larger feature deferred to a future release. Apple Reminders/EventKit notably does not expose a public parent/child API at all.

### Tests

- New `V5_9_0_RegressionTests` — 25 tests, one or more per issue, named to indicate which issue they guard (e.g. `test_65_urlWithHashFragmentNotParsedAsTag`). Includes the file-level integration tests for surgical edits on custom markers (#63), the resolution algorithm for hierarchical tags (#64), URL/wikilink/code-span protection (#65), and parent-tag inheritance with depth, siblings, and tagless-parent edge cases (#66).

### Internal

- `SyncTask.fromObsidianLine` gains optional `openMarkers` / `completedMarkers` parameters (default to the v5.8.x hardcoded sets, so existing call sites are untouched).
- `SyncTask.extractCheckbox(from:)` helper — single source of truth for what counts as a task checkbox, used by both the parser and the surgical-edit code in `ObsidianService`.
- `SyncTask.computeProtectedRanges(in:)` helper — exposed as `static` for unit testing and reuse.
- `SyncConfiguration.resolveTargetList` gains an optional `tags:` parameter (default `[]`, so existing callers continue to work).
- `ObsidianService.scanVault` / `parseTasksFromFile` gain optional marker-set parameters, threaded from `ObsidianTasksSource.scanTasks(config:)`.
- `SyncConfiguration` gains `obsidianTasksOpenMarkers` / `obsidianTasksCompletedMarkers` (mirrors the existing `taskNotesCompletedStatuses` pattern). Defensive `decodeIfPresent` ensures pre-v5.9.0 config files load with the historical defaults.

### Thanks

@cjhille for filing four well-documented issues with screenshots in one day.

---

## v5.8.2 (April 2026) — emergency fix

### Critical bug fix: runaway duplication in `/Inbox.md`

Users with `enableNewTaskWriteback = true` and recurring tasks in Apple Reminders saw their `/Inbox.md` accumulate dozens of duplicate completed task entries within minutes of each sync. Three independent defects compounded — fixing any one alone wouldn't have stopped the loop. All three are addressed.

- **`SyncEngine.swift` step 6 — recurrence history was being written out as new tasks.** When you complete a recurring reminder in Apple Reminders, iOS marks that instance complete and creates a fresh occurrence with a brand-new `calendarItemIdentifier`. The old mapping pointed to the original id, so every fresh occurrence (and every historical completion) looked unmapped to the sync engine and got appended to `/Inbox.md`. The fix: skip the inbox append when the reminder's title already exists somewhere in the vault, and re-attach the unmapped reminder to the existing Obsidian task's id instead.
- **`ObsidianService.appendTaskToInbox` — missing self-modification registration.** Every other file-mutating method in this service calls `FileWatcherService.shared.registerSelfModification(_:)` before writing. `appendTaskToInbox` was missing that call (it was the only such omission). Result: every append to `/Inbox.md` triggered the watcher's debounced sync callback, which ran another sync, which appended again. Compounded with the bug above, this created an unbounded duplication loop while the app was running. Now registered before write.
- **`SyncEngine.swift` step 6 — `obsidianId` was unstable across the append/reparse round-trip.** The line written to disk includes `#<targetList>` (the reminder's list name as a tag), but the mapping was stored using `rTask`, which has `tags = []`. On the next vault scan, the parsed task has the tag in its tags array, so the generated id differs and the mapping orphans itself immediately. Now we re-parse the just-written line through `SyncTask.fromObsidianLine` and use the parsed task's id for the mapping — guaranteeing stability across syncs.

If your `/Inbox.md` was affected, your file backups are in `~/Library/Application Support/Remindian/backups/` — the most recent backup before the duplicates started accumulating is your best restore point.

### Tests

- New `InboxWritebackRegressionTests` — 5 tests covering each defect independently:
  - `testAppendTaskToInboxRegistersSelfModification` — verifies the `FileWatcherService` accessor reports the path as self-modified after `appendTaskToInbox` returns.
  - `testAppendedLineParsesToStableObsidianId` — verifies the round-trip stability that step 6's mapping depends on.
  - `testAppendedLineWithNoListProducesStableId` — same, edge case where the reminder has no list name.
  - `testTitleIndexLookupHitsForExistingVaultTask` — verifies the dedup contract used by step 6 fires for the canonical recurrence-history scenario.
  - `testTitleIndexMissesForGenuinelyNewReminder` — verifies genuinely new reminders aren't accidentally skipped.

If any of these fail, the bug is back.

---

## v5.8.1 (April 2026)

### Bug Fixes

- **TickTick OAuth: `ERR_CONNECTION_REFUSED` on 127.0.0.1 (#61).** Two-part root cause uncovered while investigating: (a) the local OAuth callback server's `start()` returned immediately and dispatched the bind+listen to a background queue, so the browser could redirect to the loopback port before it was bound; (b) the app sandbox was missing the `com.apple.security.network.server` entitlement, which prevented the server from binding at all on production builds. Fixed both: `start()` now binds and listens synchronously (and `throw`s on bind failure so we never open the browser to a dead callback URL); the missing entitlement is now declared. Thanks to @qbisz-io for the report.
- **#62.1 — Hide Dock Icon: icon reappears after opening the main window.** `openMainWindow()` was unconditionally calling `NSApp.setActivationPolicy(.regular)`, overriding the `.accessory` policy set at launch. Now respects `config.hideDockIcon`.
- **#62.2 — "Open Main Window" + "Settings…" duplicate.** Both menu items showed the same window since v5.4.0 unified Settings into the main window's TabView. Removed the redundant "Settings…" entry per the reporter's suggestion.
- **#62.3 — Mappings trash button: stale UI.** `ForEach(Array(...enumerated()))` built against a snapshot, so SwiftUI didn't redraw when the underlying `@Published` array mutated. Refactored to `ForEach(syncManager.config.listMappings)` + `removeListMapping(id:)`. Same fix applied to file path and folder path mappings.
- **#62.4 — Auto-sync ON by default.** New `SyncConfiguration` instances now default `enableAutoSync` to `false`. Existing users keep their persisted preference; only fresh installs pick up the new default. Aligns with the existing onboarding intent ("don't auto-sync before the user has reviewed mappings").
- **#62.5 — HTTP API integration auto-fires on selection.** `requestDestinationAccess()` was triggering `performSync()` as a side effect when the user changed source/destination settings. Split the launch-time auto-sync into `performLaunchSyncIfReady()`, called once explicitly from `AppDelegate`. Runtime config changes now never trigger sync as a side effect.

### Tests

- `TickTickOAuthServerTests` — 2 tests verifying the port is listening immediately after `start()` returns, and that `start()` throws cleanly when the port is already in use.

### Thanks

@qbisz-io for #61, @fnsign for the detailed #62 breakdown.

---

## v5.8.0 (April 2026)

### Recurring tasks — Phase B (#57)

v5.7.0 fixed recurring tasks that originate in Obsidian (scenarios 1 & 2 of #57). This release closes the loop by reading and writing native `EKRecurrenceRule` on the Apple Reminders side, covering the remaining scenarios — recurring tasks that originate in Reminders sync correctly to Obsidian, and edits made on either side propagate.

- **`RecurrenceConverter`** — new bidirectional converter between Obsidian Tasks rule strings (e.g. `"🔁 every week"`, `"every month on the 15th"`) and `EKRecurrenceRule`. Handles daily/weekly/monthly/yearly with arbitrary intervals, "on the Nth" for monthly, FE0F emoji variation selectors, and the plugin's `"when done"` suffix (which Apple handles natively via completion date).
- **Reminders → SyncTask** — `SyncTask.fromReminder` now reads the first `EKRecurrenceRule` on a reminder and populates `recurrenceRule` with the equivalent Obsidian rule string. The Phase A line-number-aware ID logic and sibling-inheritance dedup then kick in, so recurring reminders stay correctly mapped through each occurrence.
- **SyncTask → Reminders** — `applyToReminder` parses `recurrenceRule` back to an `EKRecurrenceRule` when writing. Unparseable rules clear existing rules instead of leaving stale state. Rules you write in Obsidian now become native repeating reminders in Apple Reminders.
- **Hash includes recurrence** — `generateTaskHash` includes `recurrenceRule` so changing "every week" → "every 2 weeks" on either side is detected as a change and propagates via the normal writeback path.
- **Re-linking prefers matching rules** — when the sync engine has to re-attach a reminder to an Obsidian task by title (e.g. after an ID format migration), matching recurrence rules now add a 7-point score bonus. Disambiguates cases where multiple tasks share a title but only one is the recurring instance.
- **Grammar support**: `every day` · `every N days` · `every week` · `every N weeks` · `every month` · `every N months` · `every month on the Nth` · `every year` · `every N years`. More grammars can be added in future releases — unsupported strings are preserved as text and the existing completion-driven flow still works.

### Tests

- **`RecurrenceConverterTests`** — 27 unit tests covering parse, format, round-trip stability, ordinal rendering, FE0F tolerance, and semantic equivalence.
- **`PersistenceTests` additions** — schema-drift regression tests: v7 state payloads decode cleanly into current runtime, ancient v3 payloads don't crash decoding. (Tied to the init-path hardening from #58.)

### Thanks

Continuing thanks to @isabellabrookes for the original 4-scenario breakdown on #57.

---

## v5.7.1 (April 2026)

### Things 3 sync resilience (#56 follow-up)

Follow-up to feedback from @EPenR: when one Things 3 list is slow or unresponsive, sync was aborting the entire fetch — including the 4 other active lists and the Logbook — leaving the user with no data and a generic 30s-timeout error. It was also impossible to tell *which* list was stalling since the UI just said "Fetching from Things 3…" for the whole operation.

- **Per-list progress in the UI** — `"Fetching Things 3 (Today)…"`, `"Fetching Things 3 (Inbox)…"`, `"Fetching Things 3 (Logbook, last 7 days)…"`. You now see which list is in flight and can tell immediately where a stall is happening.
- **Continue on individual list timeout** — if `Today` times out, Remindian logs the failure and moves on to `Inbox`, `Anytime`, `Upcoming`, `Someday`, and the Logbook. Partial data is strictly better than no data. The skipped lists are surfaced as individual warnings in the sync result, not a single fatal error.
- **Per-list timing in debug.log** — each fetch logs its duration (e.g. `[Things3] Fetched 42 tasks from 'Today' in 2.34s`), so `~/Library/Application Support/Remindian/debug.log` pinpoints stalls. Failed lists log how long they waited before timing out.
- **New `progressCallback` on `TaskDestination` protocol** — allows destinations that do multi-step work to surface granular progress; other destinations inherit a no-op default.

Thanks @EPenR for the detailed testing and follow-up on #56.

---

## v5.7.0 (April 2026)

### Recurring tasks (#57 Phase A)

The Obsidian Tasks plugin creates a new line for each occurrence of a recurring task: when you complete `- [x] Pay rent 🔁 every month 📅 2026-01-01`, it inserts a new uncompleted `- [ ] Pay rent 🔁 every month 📅 2026-02-01` above. Previously Remindian stripped the `🔁` rule during parsing and generated the same `obsidianId` for both lines, so the sync engine treated them as one task — completing in Obsidian silently overwrote the new occurrence, or left the destination with duplicates piling up on each cycle.

- **Parser preserves recurrence rule** — `SyncTask.recurrenceRule: String?` now holds the captured rule text (e.g. `"🔁 every month"`, `"every 2 weeks when done"`) instead of discarding it.
- **Recurring tasks get line-number-aware IDs** — `generateObsidianId` includes the line number only when the task has a recurrence rule, so the completed copy and the new-uncompleted copy get distinct IDs. Non-recurring tasks keep content-stable IDs, so normal reordering still doesn't break sync mappings.
- **Pass (a) dedup updated** — Completed recurring copies stay in the sync map so the main loop can detect and propagate the completion to the destination. The new "Step 5 sibling inheritance" logic then transfers the reminder mapping from the completed sibling to the new uncompleted occurrence without creating a duplicate.
- **Sync state v7 → v8 migration** — Adds lineNumber to the recurring-task ID format. Existing non-recurring mappings are unchanged; the re-linking logic handles recurring mappings gracefully. Rare edge case: if you have an in-flight recurring completion at the exact moment you upgrade (completed in Obsidian but never synced), the completion event may need a second manual sync to propagate — subsequent completions work on the first sync.

Phase A covers scenarios 1 & 2 from #57 (tasks that originate in Obsidian). Scenarios 3 & 4 (tasks originating in Apple Reminders with native `EKRecurrenceRule`) are Phase B and are still under active development.

---

## v5.6.2 (April 2026)

### Bug Fixes
- **Things 3 task creation failed with 2+ tags** — AppleScript error `-1700` was returned when creating a to-do with 2 or more tags, because `tag names:{"a", "b"}` (list syntax) fails Things 3's coercion — the scripting dictionary declares `tag names` as TEXT. Both `createTask` and `createTasksBatch` now emit comma-separated string form (`tag names:"a, b"`). A single-tag task worked by accidental coercion, which is why this wasn't caught earlier. Without this fix, multi-tag tasks were silently dropped and accumulated as duplicates on subsequent syncs. Huge thanks to @joscdk (Jonas Schwartz) who diagnosed the root cause, provided a standalone AppleScript reproduction, and submitted the fix in PR #60. (#59)
- **"Task already deleted" no longer surfaces as sync error** — `deleteTask()` now swallows AppleScript error `-1728` (task ID not found). If the Things 3 task was removed by the user between fetches, that's a no-op, not a failure. Also from @joscdk's PR #60. (#59)

### Tests
- Added `Things3DestinationTests` covering multi-tag AppleScript property generation, leaf extraction for hierarchical tags, deduplication, and quote escaping — prevents regression of the tag-syntax bug fixed in PR #60.

---

## v5.6.1 (April 2026)

### Bug Fixes
- **Things 3 sync hanging indefinitely** — v5.6.0 only applied the 30s timeout to the Logbook fetch. Now ALL 8 AppleScript call sites have timeouts: fetching from 5 active lists (30s each), requesting access (10s), fetching available lists (15s), and task creation/deletion (30s with retry) (#56)
- **Open Backups Folder / Open Audit Log buttons** — Fixed buttons that silently did nothing on fresh installs by creating the directory/file if it doesn't exist yet

### Improvements
- **Real-time sync progress** — UI now shows step-by-step progress during sync ("Scanning vault...", "Fetching from Things 3...", "Comparing N tasks...", "Creating N tasks...") instead of a static "Syncing..." message
- **Async AppleScript retry** — Retry logic now uses async sleep instead of blocking `Thread.sleep`, preventing UI freezes during retry attempts

---

## v5.6.0 (April 2026)

### Bug Fixes
- **Things 3 sync stuck** — Fixed Logbook fetch that could hang indefinitely when iterating tasks with empty completion dates. Added 500-item cap and 30-second AppleScript timeout to prevent sync from blocking forever (#56)
- **TickTick onboarding** — "Grant Access" button during onboarding now correctly opens the TickTick OAuth flow instead of silently failing. Added proper "Connect TickTick" button in both onboarding and main permission views (#54)
- **Things 3 permission guidance** — Added "Open System Settings" button that links directly to Privacy & Security > Automation when Things 3 automation access is denied

### Improvements
- **AppleScript timeout wrapper** — All Things 3 AppleScript operations now have a 30-second timeout to prevent indefinite blocking
- **Logbook safety** — Tasks with empty completion dates are skipped during Logbook fetch, and iteration is capped at 500 items maximum

---

## v5.5.0 (March 2026)

### Bug Fixes
- **Universal Binary restored** — DMG now includes both arm64 and x86_64 architectures. Intel Mac users can run v5.5.0+ again (#50)
- **TickTick OAuth guard** — Selecting TickTick as destination now shows "Coming soon" instead of opening a broken OAuth page with "invalid_client" error (#49). TickTick OAuth registration is pending

---

## v5.4.0 (March 2026)

### Unified Single-Window Experience
- **Settings embedded in main window** — No more separate Settings window. General, Mappings, TaskNotes, and Advanced settings are now tabs alongside Conflicts and History in the main detail pane
- **Liquid Glass tabs** — All tabs (settings + activity) share the same tab bar with Liquid Glass treatment on macOS Tahoe
- **Fewer windows** — The app is now fully contained in a single window with sidebar + tabbed detail
- **Menu bar "Settings..."** now opens the main window directly

---

## v5.3.0 (March 2026)

### Native macOS Settings Window
- **Toolbar-style icon tabs** — Settings now opens the native macOS Settings scene, giving the classic Preferences look with icons + labels in the toolbar (like Mail.app, Xcode)
- **Brand icons** — Todoist, Things 3, TickTick, Asana, and Linear show their real logos in the destination picker (sourced from SimpleIcons, rendered as template images)
- **Grouped form style** — All settings sections use `.formStyle(.grouped)` for modern rounded-card sections (like System Settings)
- **Better tab icons** — "Mappings" tab uses swap arrows, "Advanced" uses horizontal sliders instead of wrench

---

## v5.2.0 (March 2026)

### Design Overhaul — Liquid Glass (macOS Tahoe)
- **NavigationSplitView dashboard** — On macOS 26+, the main window uses a native sidebar/detail split with automatic floating glass sidebar, replacing the legacy HSplitView
- **Glass toolbar** — Sync button and status move into the native toolbar, which gets automatic Liquid Glass treatment on Tahoe. Traffic lights (close/minimize/maximize) integrate naturally into the content area
- **Transparent titlebar** — All programmatically created windows (main, settings, about) use `titlebarAppearsTransparent` + `fullSizeContentView` on macOS 26+ for seamless glass
- **Glass sidebar sections** — Sync Status and Configuration panels use `.glassEffect(.regular)` directly on macOS 26+ instead of wrapping the entire view in a glass blob
- **Full backward compatibility** — macOS 13-15 users see the exact same UI as before. All glass is conditionally applied with `@available(macOS 26, *)`

### UI Improvements (all macOS versions)
- **Settings window size** — Default 750×700, minimum 650×550 (up from 550×580)
- **Settings scroll fix** — List Mappings tab now scrollable; no more content clipping
- **Flexible field widths** — Mapping input fields flex with window resize

---

## v5.1.0 (March 2026)

### UI Improvements
- **Fixed Settings layout** — List Mappings tab now scrolls properly; content no longer crops or overflows outside the window
- **Larger Settings window** — Default size increased to 750x700 with proper minimum size constraints
- **Flexible field widths** — Mapping input fields now flex with window resizing instead of using fixed widths
- **Liquid Glass (macOS Tahoe)** — Dashboard panels and Settings adopt Apple's Liquid Glass design on macOS 26+. Falls back gracefully on older macOS versions

---

## v5.0.0 (March 2026)

**First stable GA release.** Remindian is no longer beta.

### New Features
- **Tag exclusion (#47)** — Exclude tasks with specific tags from syncing (e.g., "Routine"). Configure in Settings > Exclude Tags
- **TaskNotes subdirectory scanning (#48)** — TaskNotes now recursively scans all subdirectories within the configured folder, so you can organize task notes by project
- **Homebrew tap (#35)** — Install via `brew tap Santofer/remindian && brew install --cask remindian`

### Performance
- **Faster Things 3 sync** — Tags are now set directly in the AppleScript batch call instead of separate URL scheme operations, eliminating per-task throttle delays

### Bug Fixes
- **Fixed crash-on-launch (#38)** — Eliminated all force unwraps across the entire codebase. Malformed URLs, corrupted data, or unexpected nil values are now handled gracefully instead of crashing
- **Version display** — About section now correctly shows the running version

---

## v4.3.1 (March 2026)

### New Features
- **Obsidian link in Things 3** — Tasks synced to Things 3 now include a clickable `obsidian://` link in the notes field, just like Apple Reminders. Click it to jump straight to the source file in Obsidian
- **Task Notes body synced** — The markdown body content of TaskNotes files (below the YAML frontmatter) is now included as the task notes in the destination

### Bug Fixes
- **Fixed MTN exit 126 in sandbox** — The macOS sandbox blocks CLI execution even with `chmod +x`. The app now automatically falls back to "Direct Files" mode when mtn CLI fails, which reads/writes task files directly without needing the mtn binary
- **10x faster Things 3 sync** — Task creation now uses batch AppleScript (up to 20 tasks per call) instead of one-at-a-time. URL scheme throttle reduced from 150ms to 50ms. 100 tasks should now sync in under a minute instead of 7-12 minutes
- **Fixed version display** — Xcode project build settings (`MARKETING_VERSION`) now stay in sync with `Info.plist`

---

## v4.3.0 (March 2026)

### Bug Fixes
- **Fixed Things 3 hierarchical tags (again)** — Tags like `person/name` now send only the leaf name (`name`) via URL scheme. Things 3 resolves the hierarchy natively; sending the full path caused percent-encoding (`person%2Fname`) which didn't match existing tags
- **Improved Things 3 sync speed** — Added 150ms throttle between URL scheme calls to prevent overwhelming Things 3 with rapid-fire updates. Reduced retry delay from 0.5s to 0.3s
- **Fixed first-launch auto-sync** — Onboarding no longer triggers an immediate sync. Users with large vaults were getting hundreds of tasks created in their destination on first launch before reviewing settings
- **Better MTN error messages** — Exit code 126 ("not executable") now shows a clear fix: `chmod +x /path/to/mtn`. Also pre-checks binary permissions before attempting to run
- **Updated About view** — Release date now shows March 2026

---

## v4.2.2 (March 2026)

### Bug Fixes
- **Fixed Things 3 hierarchical tags** — Tags like `person/name` were being expanded to both `person` and `person/name`, causing tasks to get tagged with the parent tag as a standalone tag. Now sends only the full tag path and lets Things 3 resolve the hierarchy natively

---

## v4.2.1 (March 2026)

### Bug Fixes
- **Fixed crash on launch** — Eliminated 6 force-unwrap (`first!`) calls on `applicationSupportDirectory` that could crash the app immediately on startup if the directory wasn't available. All persistence code now uses a safe `remindianAppSupportDir()` helper that returns nil instead of crashing
- **Hardened startup sequence** — Each initialization step in `AppDelegate` is now isolated with diagnostic logging, so one subsystem failure doesn't take down the entire app
- **Note for unsigned app users** — If macOS blocks the app with "damaged" or "quit unexpectedly", run `xattr -cr /Applications/Remindian.app` in Terminal before opening

---

## v4.2.0 (March 2026)

### New Features
- **Folder-to-list mapping** (#40) — Map entire vault folders to specific destination lists. All tasks in any file within the mapped folder (and subfolders) sync to the specified list. More specific folders take priority over broader ones (e.g., `Projects/Work/` beats `Projects/`). Configure in Settings > List Mappings
- **Dataview inline field support** (#41) — Parse `[key::value]` and `(key::value)` metadata from task lines. Recognized fields: `due`, `start`, `scheduled`, `completed`, `priority`, `tags`, `project`, `list`. Emoji-based metadata takes precedence; dataview fields fill in any gaps. Enable in Settings > Advanced > "Parse dataview inline fields"
- **Asana destination** (#42) — Sync tasks to Asana via the REST API v1. Tasks map to Asana tasks, lists map to Asana projects. Supports due dates, start dates, completion status, notes. Auth via Personal Access Token
- **Linear destination** (#43) — Sync tasks to Linear via the GraphQL API. Tasks map to Linear issues, lists map to Linear teams. Supports due dates, priority mapping (Urgent/High/Medium/Low), labels as tags, completion via workflow states. Auth via Personal API Key
- **Calendar Feed destination** (#44) — Generate a subscribable .ics (iCalendar) file from your tasks. Tasks become RFC 5545 VTODO entries with due dates, priorities, and completion status. Subscribe from Apple Calendar, Google Calendar, or any CalDAV client

### Bug Fixes
- **Fixed Todoist sync** (#39) — Todoist REST v2 API is 410 Gone. Switched to API v1 with proper paginated response handling (`{ "results": [...], "next_cursor": "..." }`) and fixed field name mismatch (`checked` instead of `isCompleted`)
- **Fixed destination switching** — `hasRemindersAccess` was blocking all non-Reminders destinations. Renamed to `hasDestinationAccess` with per-destination permission UI and automatic re-request on destination switch
- **Fixed Things 3 completion writeback** — Completing a task in Things 3 moves it to the Logbook, which wasn't being fetched. The sync engine saw the task as "deleted" and recreated it. Now fetches recently completed tasks (last 7 days) from the Logbook and correctly writes completion back to Obsidian. Also skips redundant destination updates when completion flows from Things→Obsidian
- **Fixed list filtering for completed tasks** — Already-mapped destination tasks are no longer filtered out by the allowed/excluded lists whitelist. This ensures completion writeback works even when tasks move to a different list (e.g. Things 3 Logbook)
- **Fixed cross-file dedup collapsing unique tasks** (#46) — Tasks with identical titles in different files (e.g. "Review imported meeting notes" in multiple meeting note files) were incorrectly collapsed into a single reminder. Dedup now only removes duplicates when one copy is in Inbox.md (writeback artifact)
- **Fixed MTN sandbox permission error** (#45) — `mtn` CLI invocation via `/bin/sh -l` failed with "Operation not permitted" because login shell tries to source `/etc/profile` which is blocked by the macOS sandbox. Removed `-l` flag; PATH is set explicitly
- **Fixed Things 3 auth token blocking sync** (#45) — Missing or invalid auth token was throwing errors that blocked all sync operations. Now gracefully skips update/move operations when no token is configured, allowing creation-only workflows
- **Improved Things 3 sync speed** (#45) — Removed unnecessary `launch` + `delay 0.5` from every AppleScript execution (saves ~0.5s per task operation). Reduced retry delay from 1.5s to 0.5s. Retry now adds `launch` only when needed
- **Added hierarchical tag support for Things 3** (#45) — Tags like `#person/name` now auto-expand to include parent tags (`person`, `person/name`) so Things 3 creates the correct tag hierarchy
- **Increased Settings panel minimum size** (#45) — Enlarged from 550×500 to 650×600 to prevent content truncation

### Technical Changes
- New `SyncConfiguration.FolderMapping` struct with `folderPath` and `remindersList` fields
- `resolveTargetList()` now checks folder mappings between file mappings and auto-capitalize (most specific folder wins)
- New `SyncTask.parseDataviewFields(from:into:)` static method parses both bracket and parenthetical syntax
- `ObsidianTasksSource.scanTasks()` applies dataview parsing when `enableDataviewFormat` is enabled
- Mapping priority: explicit tag > file path > folder path > auto-capitalize tag > default list
- New `AsanaDestination` with REST API, workspace/project resolution, paginated task fetching, rate limit retry
- New `LinearDestination` with GraphQL API, team/workflow state resolution, priority mapping, paginated issue fetching
- New `CalendarFeedDestination` with RFC 5545 .ics generation, VTODO entries, ICS parsing for round-trip
- `TaskDestinationType` enum expanded: `.asana`, `.linear`, `.calendarFeed` with display names and config properties
- `PermissionRequestView`, `OnboardingView`, `SettingsView` updated for all 7 destination types
- 16 new tests (65 total): folder mapping resolution, specificity, encoding, dataview field parsing, priority preservation, cross-file dedup

---

## v4.1.0-beta (March 2026)

### New Features
- **File-to-list mapping** (#37) — Map specific Obsidian files to specific destination lists. All tasks in a mapped file (e.g., `Projects/Work.md`) sync to the specified list without needing to tag each task individually. Configure in Settings > List Mappings

### Bug Fixes
- **Fixed Things 3 "application not running" error** — AppleScript blocks now use `tell application id "com.culturedcode.ThingsMac"` (bundle identifier) instead of `tell application "Things3"` (display name), which resolves reliably in sandboxed macOS apps. Write operations (`createTask`, `deleteTask`) also include an explicit `launch` command to ensure Things 3 is active before sending commands. This fixes the issue where dry run worked but actual sync failed with "application not running"

### Technical Changes
- New `SyncConfiguration.FileMapping` struct with `filePath` and `remindersList` fields
- New `resolveTargetList(tag:filePath:)` method encapsulates the full resolution chain: explicit tag mapping > file path mapping > auto-capitalize tag > default list
- `SyncEngine` uses `resolveTargetList` at all 6 list routing call sites
- 7 new tests covering file mapping resolution priority, encode/decode, and backward compatibility (49 total)

---

## v4.0.0-beta (March 2026)

### New Features
- **Todoist destination** — Sync tasks to Todoist via the REST API v1. Supports personal API token auth, project mapping, priority sync (high/medium/low), label/tag sync, and due date with optional time
- **TickTick destination** — Sync tasks to TickTick via the Open API v1. Uses OAuth 2.0 with automatic token refresh. Supports project mapping, priority sync, and due dates. Note: TickTick's Open API does not support tags/labels
- **Custom URL scheme** — `remindian://` URL scheme for OAuth callbacks (TickTick authorization flow)

### Technical Changes
- **Protocol evolution** — All `TaskDestination` CRUD methods (`createTask`, `updateTask`, `moveTask`, `deleteTask`, `getAvailableLists`) are now `async throws`, enabling REST API destinations alongside existing local destinations
- New `TodoistDestination` with full CRUD, rate limit retry (429 + Retry-After), priority/label/date mapping
- New `TickTickDestination` with OAuth 2.0 token management, project iteration (no global task endpoint), project-scoped operations
- New `OAuthCallbackHandler` singleton for `remindian://` URL scheme routing
- `SyncManager` gains `connectTickTick()`, `handleTickTickOAuthCode()`, `disconnectTickTick()` for TickTick OAuth lifecycle
- `SyncConfiguration` gains `.todoist` and `.tickTick` destination types with associated token/credential storage
- `SyncEngine.resolveConflict()` now `async throws` to match protocol changes
- Settings UI updated with Todoist API token field and TickTick connect/disconnect button

---

## v3.7.0 (March 2026)

### Bug Fixes
- **Fixed Things 3 duplicate syncing** — Task creation switched from URL scheme to AppleScript, which returns the task ID directly. Eliminates the unreliable title-based search that only checked Inbox/Today, causing duplicates when Things 3 routed tasks to projects or other lists
- **Fixed Things 3 "no app to open URL scheme" errors** — `NSWorkspace.shared.open(url)` return value is now checked and throws a clear error instead of silently failing
- **Fixed Things 3 tag changes not syncing** (#32) — `updateTask()` was not including tags in the URL scheme parameters, so tag/project changes from Obsidian never propagated to Things 3
- **Fixed Settings UX for default list vs project routing** (#33) — Added contextual help text explaining how the default list interacts with TaskNotes project/context routing. The default list is now clearly labeled as a fallback

### New Features
- **Obsidian Tasks global filter** (#36) — New "Global filter" field in Advanced settings. Only syncs tasks whose line contains the specified text (e.g., `#task`), matching the Obsidian Tasks plugin's global filter setting

### Technical Changes
- `Things3Destination.createTask()` rewritten to use AppleScript instead of URL scheme for reliable task ID retrieval
- `Things3Destination.updateTask()` now sends tags in URL scheme params
- New `Things3Error.urlSchemeNotHandled` error case for URL scheme failures
- New `updateTaskTags(withId:tags:)` helper for setting tags after AppleScript creation
- New `formatAppleScriptDate()` helper for AppleScript date literals
- Removed `findTaskIdByTitle()` — no longer needed with AppleScript-based creation
- `SyncConfiguration.globalFilter` property added with full encode/decode support
- `ObsidianTasksSource.scanTasks()` applies global filter post-scan

---

## v3.6.0 (February 2026)

### Bug Fixes
- **Fixed crash on launch** — `@ObservedObject` in MenuBarView caused the updater to be recreated on every SwiftUI redraw, crashing the app after a few seconds. Changed to `@StateObject` for stable ownership
- **Fixed tag writeback not forwarding tags** — `ObsidianTasksSource.updateTaskMetadata()` was not passing `newTags` to the underlying `ObsidianService`, silently dropping tag changes
- **Fixed TaskNotes projects not creating Reminders folders** — YAML values with quotes (e.g., `project: "My Project"`) kept literal quote characters, causing list creation to fail. Now strips YAML quotes during frontmatter parsing (#28)
- **Fixed auto-sync on first launch** — App was triggering a sync immediately after Reminders permission was granted, before the user completed onboarding. Now waits until onboarding is complete (#25)
- **Fixed Reset Sync State inconsistency** — The dashboard and Advanced settings had different Reset buttons with different behaviors. Both now use a confirmation dialog and perform a comprehensive reset: clears sync state mappings, sync log, debug log, and resets first-sync flag (#29, #30)

### New Features
- **Sync stop/cancel button** — Cancel a running sync at any time from the main window header or menu bar dropdown. Uses cooperative cancellation with checks at key sync points (#26)
- **Icon tooltips** — All sync status icons (created, updated, deleted, completions, metadata) now show descriptive tooltips on hover. Menu bar status dot also explains its color meaning (#31)
- **Redesigned Settings** — Split the cluttered Advanced tab into separate tabs: General, List Mappings, TaskNotes (conditional), and Advanced. TaskNotes configuration gets its own dedicated tab with organized sections for Integration, Status Mapping, Field Mapping, and List/Folder Source (#24)

### Technical Changes
- `MenuBarView` uses `@StateObject` instead of `@ObservedObject` for `UpdaterService.shared`
- `SyncManager` gains `currentSyncTask` tracking and `cancelSync()` method
- `SyncEngine` gains `_cancellationRequested` flag with `NSLock`-based thread safety and `requestCancellation()`/`isCancelled` API
- `SyncError.syncCancelled` added for clean cancellation reporting
- `TaskNotesSource.parseTaskNotesFile()` strips YAML single/double quotes from frontmatter values
- `SettingsView` split into `GeneralSettingsView`, `ListMappingsSettingsView`, `TaskNotesSettingsView`, `AdvancedSettingsView`
- New `FieldMappingRow` helper view for individual field mapping display
- Reset confirmation dialog shared between dashboard and advanced settings
- `.help()` tooltips added to all `StatBadge` and menu bar sync result icons

---

## v3.5.1 (February 2026)

### Bug Fixes
- **Auto-update now works on app launch** — The update checker was only initialized when the About window was opened. It now starts automatically when the app launches and checks every 24 hours (#23)
- **Update download works in sandboxed builds** — Replaced `Process()`-based DMG mount/install (blocked by sandbox) with browser-based download. Clicking "Download Update" opens the DMG in your browser for drag-install
- **Update notification in menu bar** — When an update is available, it now shows directly in the menu bar dropdown (no need to open the About view)
- **Fixed deprecated notification API** — Replaced removed `NSUserNotification` with modern `UNUserNotificationCenter` via `NotificationService`

---

## v3.5.0 (February 2026)

### New Features
- **Configurable field mapping for TaskNotes** — Map your YAML frontmatter field names to Remindian properties. If your TaskNotes uses custom fields (e.g., `deadline` instead of `due`, `importance` instead of `priority`), configure the mapping in Settings > Advanced > TaskNotes > Field Mapping (#19)
- **Project/context as Reminders list** — Choose which TaskNotes field determines the Reminders list/folder: `tags` (default), `project`, or `context`. Supports wikilinks (e.g., `project: [[My Project]]` → "My Project" list). Configurable in Settings > Advanced > TaskNotes > List/Folder Source (#20)
- **GoodTask tag writeback** — Tag changes in Reminders (e.g., via GoodTask's Kanban board) sync back to Obsidian `#tags`. Enable in Settings > General > Sync tag changes (#17)
- **Exclude Reminders lists** — Blacklist specific Reminders lists from sync (e.g., Groceries, Shared). Easier to manage than the whitelist when you only want to skip a few lists. Configure in Settings > Advanced > Reminders List Filtering (#21)

### Bug Fixes
- Fixed: Task completed in Obsidian (`- [x]`) was being reverted to incomplete on next sync when Reminders still showed it as incomplete. Source of truth (Obsidian) now correctly wins — Reminders is updated to match (#16)
- Fixed: Settings window too small and couldn't be resized — now resizable with scroll support in Advanced tab (#18)

### Technical Changes
- `TaskNotesFieldMapping` struct for configurable YAML field names (title, status, priority, due, scheduled, completedDate, tags, project, context)
- `SyncConfiguration` gains `taskNotesFieldMapping`, `taskNotesListField`, `excludedRemindersLists`, `enableTagWriteback` fields
- `TaskNotesSource` uses `fieldMapping` for all YAML read/write operations instead of hardcoded field names
- `TaskNotesSource` uses `listField` to determine `targetList` from project/context/tags/custom field
- `MtnCliTask` and `TaskNotesApiTask` gain `project`/`context` fields and `listField` parameter
- `stripWikilinks()` helper removes `[[` and `]]` brackets from field values
- `SyncEngine` completion sync direction fixed: when `oTask.isCompleted && !rTask.isCompleted`, sets `taskForReminders.isCompleted = true`
- `SyncEngine` filters excluded Reminders lists in both Step 2 (fetch) and Step 5 (creation)
- `MetadataChanges.newTags` enables tag writeback; `applyTagChange()` added to `ObsidianService`
- Settings window uses `minWidth`/`minHeight` with `idealWidth`/`idealHeight` for resizable layout

---

## v3.4.0 (February 2026)

### New Features
- **Custom status mapping for TaskNotes** — Configure which status values mean "completed" (e.g., `done`, `completed`, `cancelled`, `archived`, `shipped`). Also set custom status values for marking tasks complete/incomplete from Reminders. Configurable in Settings > Advanced > TaskNotes (#10)
- **Support for + prefix in list mappings** — Tasks tagged with `+Project` now map to Reminders lists just like `#tag`. Both `#` and `+` prefixes are supported (#14)

### Bug Fixes
- Fixed: List items with wikilinks (e.g., `- [[Sarah]] coming to stay`) were incorrectly parsed as tasks and created Reminders. Now only proper checkbox items (`- [ ]` / `- [x]`) are recognized (#13)

### Improvements (cherry-picked from [PR #8](https://github.com/Santofer/Remindian/pull/8) by [@tparsons9](https://github.com/tparsons9))
- **Flexible API response parsing** — HTTP API now supports wrapped responses (`{ success, data: [...] }`) and collection envelopes (`{ data: { tasks: [...] } }`), improving compatibility with different TaskNotes plugin versions
- **Better HTTP error handling** — API calls now check HTTP status codes and provide detailed error messages with response snippets
- **Smarter notification permissions** — Checks authorization status before prompting; logs detailed errors for denied or failed permission requests
- **Source/destination refresh before sync** — Ensures latest config settings (API URL, status mapping, etc.) are always used

### Technical Changes
- `SyncConfiguration` gains `taskNotesCompletedStatuses`, `taskNotesOpenStatus`, `taskNotesDoneStatus` fields
- Task checkbox detection now uses strict prefix matching (`- [ ] ` or `- [x] `) instead of loose `- [` prefix
- Tag regex updated from `#[\w-]+` to `[#+][\w-]+` to support both prefixes
- `remindersListForTag()` strips both `#` and `+` prefixes when matching
- `TaskNotesSource` uses configurable status mapping instead of hardcoded values
- `MtnCliTask.toSyncTask()` and `TaskNotesApiTask.toSyncTask()` accept `completedStatuses` parameter
- `TaskNotesApiEnvelope` and `TaskNotesApiTaskCollection` models added for flexible JSON decoding
- `NotificationService.requestPermission()` checks `getNotificationSettings` before requesting
- `SyncManager.performSync()` calls `updateSourceAndDestination()` to pick up config changes

---

## v3.3.0 (February 2026)

### New Features
- **Universal Binary (Intel + Apple Silicon)** — DMG now includes both arm64 and x86_64 architectures, fixing compatibility with Intel Macs (#7)
- **Launch at Login** — Option to automatically start Remindian when you log in (Settings > Appearance & Shortcuts)
- **Skip old completed tasks** — Configurable age limit to prevent syncing thousands of old completed tasks. Choose 7/30/90/180/365 days (#11)
- **Reminders list filtering** — Only sync specific Reminders lists (e.g., "Work, Personal") instead of all lists. Great for excluding shared lists like Groceries (#12)
- **Task link in Reminders** — Adds an `obsidian://` deep link in Reminders notes so you can jump directly to the task file (#9)

### Bug Fixes
- Fixed: DMG not working on Intel Macs — was arm64-only (#7)

### Technical Changes
- Build configuration now uses `ARCHS = $(ARCHS_STANDARD)` for universal binary output
- `SMAppService.mainApp` used for launch-at-login (macOS 13+)
- `SyncConfiguration` gains `launchAtLogin`, `maxCompletedTaskAgeDays`, `syncedRemindersLists`, `addTaskLinkToReminders` fields
- `SyncEngine` filters completed tasks by age before sync
- `SyncEngine` filters destination tasks by allowed Reminders lists
- `applyToReminder()` now optionally adds `obsidian://open` URL to notes

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
