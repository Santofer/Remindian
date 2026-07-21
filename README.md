<p align="center">
  <img src="screenshots/banner.jpeg" alt="Remindian — Stop switching. Start syncing." width="100%">
</p>

<p align="center">
  <a href="https://github.com/Santofer/Remindian/releases/latest"><img src="https://img.shields.io/github/v/release/Santofer/Remindian?style=flat-square&color=7C3AED&label=stable" alt="Latest Release"></a>
  <a href="https://github.com/Santofer/Remindian/releases/tag/v4.1.0-beta"><img src="https://img.shields.io/badge/beta-v4.1.0-8B5CF6?style=flat-square" alt="Beta"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-A78BFA?style=flat-square" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Santofer/Remindian?style=flat-square&color=7C3AED" alt="License"></a>
  <a href="https://github.com/Santofer/Remindian/stargazers"><img src="https://img.shields.io/github/stars/Santofer/Remindian?style=flat-square&color=8B5CF6" alt="Stars"></a>
</p>

<p align="center">
  <b>A native macOS menu-bar app that syncs your Obsidian tasks<br>to Apple Reminders, Things 3, Todoist, or TickTick.</b>
</p>

<p align="center">
  <a href="https://github.com/Santofer/Remindian/releases/latest"><img src="https://img.shields.io/badge/%E2%AC%87%EF%B8%8F%20Download-Remindian-7C3AED?style=for-the-badge" alt="Download Remindian"></a>
</p>

<p align="center">
  <em>Free and open source. If it saves you time, consider</em> <a href="https://www.buymeacoffee.com/santofer">buying me a coffee</a>!
</p>

---

## What it does

Your vault is the **source of truth**. Remindian syncs tasks from Obsidian into your chosen destination. Completions, due dates, start dates, priority, and tags sync back with surgical, metadata-preserving edits.

> **Three task sources** — [Obsidian Tasks](https://publish.obsidian.md/tasks/Introduction) plugin format, [TaskNotes](https://github.com/nicolo/obsidian-tasknotes) plugin, and a configurable **Generic Markdown** dialect for NotePlan & other plain-markdown task tools
>
> **Four destinations** — Apple Reminders · Things 3 · Todoist · TickTick

## Install

### Homebrew (recommended)

```sh
brew install --cask santofer/tap/remindian
```

To upgrade:

```sh
brew update && brew upgrade --cask santofer/tap/remindian
```

> **Which tap?** `santofer/tap` is the canonical one — use it. An older
> `santofer/remindian` tap also exists and is kept in sync, but having both
> tapped makes Homebrew ask for a fully-qualified name (`Cask remindian exists
> in multiple taps`). If you hit that, untap the legacy one:
> `brew untap santofer/remindian`.

### Direct download

**[Download the latest release](https://github.com/Santofer/Remindian/releases/latest)** — Universal Binary (Apple Silicon + Intel), macOS 13.0+ (Ventura).

> Since the app is not notarized yet, right-click the app and select **Open** on first launch to bypass Gatekeeper. Remindian includes a built-in auto-updater that checks for new versions on launch and every 24 hours, so you only do this once.

## Features

<table>
<tr>
<td width="50%">

### 🔄 Sync
- **Two-way sync** — Completions, dates, priority, tags sync back
- **Surgical file edits** — Never reconstructs task lines
- **Recurrence support** — Creates next occurrence automatically
- **Real-time sync** — File watcher triggers on vault changes
- **Safety abort** — Protects against vault unmount/scan failures
- **Dry run mode** — Preview changes without modifying anything

</td>
<td width="50%">

### 🗂️ Organization
- **Tag-based list mapping** — `#work` → "Work" list
- **File-to-list mapping** — Map entire files to lists
- **Project/context routing** — TaskNotes field-based routing
- **Folder filtering** — Whitelist or exclude vault folders
- **Cross-file deduplication** — Syncs only one copy
- **Configurable field mapping** — Remap YAML field names

</td>
</tr>
<tr>
<td>

### 📥 Sources
- **Obsidian Tasks** — `- [ ] task 📅 2024-01-20 #tag`
- **TaskNotes** — One YAML file per task (CLI/Files/HTTP)
- **Generic Markdown** — NotePlan & friends: `- [ ] task >2024-01-20 !!! #tag`
- **Custom status mapping** — `done`, `shipped`, `archived`

</td>
<td>

### 📤 Destinations
- **Apple Reminders** — via EventKit
- **Things 3** — via AppleScript + URL scheme
- **Todoist** — via REST API + token auth
- **TickTick** — via Open API + OAuth 2.0

</td>
</tr>
</table>

**Also includes:** **Pinned Tasks window** — a floating, always-on-top mini task manager that shows your open tasks grouped by date / priority / tag / recurrence, with live search and inline complete · **Natural-language quick-add** — type `Pay rent friday every month !! #home` and it parses the date, **recurrence (English & French)**, priority and tags · Due times + alarms for Apple Reminders · Today list in the menu bar (due-today/overdue glance + inline complete) · Shortcuts/Spotlight actions (Sync Now · Add Task) · Preview changes before applying (dry-run diff) · Undo last sync (restore vault files) · Multiple sync profiles (run several source→destination pipelines at once) · Auto-updater · Onboarding wizard · Global hotkey · GoodTask tag writeback · New task writeback to Obsidian inbox · Automatic file backups · Launch at login · macOS native (SwiftUI, no dependencies)

## Quick Start

1. **Download** the DMG from the [latest release](https://github.com/Santofer/Remindian/releases/latest)
2. **Drag** Remindian to your Applications folder
3. **Right-click → Open** on first launch (required for unsigned apps)
4. **Follow** the onboarding wizard to select your vault, grant access, and configure mappings
5. Tasks start syncing automatically

## Configuration

Open **Settings** from the menu bar icon:

| Tab | What it configures |
|-----|-------------------|
| **General** | Source & destination, vault path, sync interval, writeback toggles, notifications, default list, hotkey |
| **List Mappings** | Tag → list mappings, file → list mappings |
| **TaskNotes** | Integration mode, status mapping, field mapping, list/folder source |
| **Advanced** | Folder filtering, Reminders list filtering, dry run, sync state reset, global filter |

## How It Works

### Obsidian Tasks (default)

```markdown
- [ ] My task ⏫ 🛫 2024-01-15 📅 2024-01-20 #work
- [x] Completed task 📅 2024-01-10 ✅ 2024-01-09
- [ ] Recurring task 🔁 every week 📅 2024-03-01
```

### TaskNotes

```yaml
---
title: My task
status: open
priority: high
due: 2024-01-20
tags: [work]
project: "[[My Project]]"
---
```

Each task syncs with its due date, priority, and tags. Completions are written back as surgical edits — only the checkbox and completion date are modified.

## Build from Source

```bash
git clone https://github.com/Santofer/Remindian.git
cd Remindian
open ObsidianRemindersSync.xcodeproj
```

**Requirements:** macOS 13.0+, Xcode 15.0+. Builds a Universal Binary by default.

## Transparency

AI (Claude) was used as a development tool. All code is reviewed, tested on real data, and the full source is open for audit. The app is sandboxed, creates automatic backups, and includes dry run mode.

## License

[MIT License](LICENSE) — Made by **Santofer**

[CHANGELOG](CHANGELOG.md) · [CONTRIBUTING](CONTRIBUTING.md)
