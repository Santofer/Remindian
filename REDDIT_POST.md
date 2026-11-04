# Reddit Post Draft for r/ObsidianMD

**Title:** Remindian v5.6 — Liquid Glass UI, community PRs merged, and the road to the App Store

**Body:**

Hey r/ObsidianMD,

I wanted to share what's been happening with Remindian, the free macOS app that syncs your Obsidian tasks to Apple Reminders, Things 3, TickTick, Todoist, and more.

## Community-driven since day one

This project wouldn't be where it is without all of you. Bug reports, feature requests, pull requests — everything that's improved in the last few months came from real users hitting real problems and taking the time to tell me about it.

Two community members recently submitted pull requests that are now merged:

- **@ebrock** added automatic retry with exponential backoff for those cryptic EventKit `-3002` errors that were driving Apple Reminders users crazy. The app now recovers silently from transient failures and shows human-readable error messages when something actually goes wrong.
- **@dillius** rewrote the writeback line-tracking logic to be position-aware (fixing a subtle bug with recurring tasks), switched all persistence to atomic writes, and contributed over 1,400 lines of tests. His first time writing Swift, by the way.

I'm genuinely grateful. Open source at its best.

## What's new in v5.6

- **Liquid Glass UI on macOS Tahoe** — If you're running macOS 26, Remindian now has a fully native Liquid Glass interface. Unified single-window with NavigationSplitView sidebar, glass-effect panels, and pill-style tabs. Settings, conflicts, and history are all in one window. On Ventura/Sonoma/Sequoia, the app looks and works exactly as before.
- **Things 3 sync no longer hangs** — The Logbook scan could loop indefinitely on large libraries. Now capped at 500 items with a 30-second timeout.
- **TickTick OAuth actually works during onboarding** — The "Grant Access" button was silently failing. Fixed with a proper "Connect TickTick" flow.
- **EventKit resilience** — Automatic retry for transient Reminders errors (thanks @ebrock).
- **Bulletproof writeback** — Position-aware offsets, atomic file writes, comprehensive test coverage (thanks @dillius).
- **Universal Binary** — arm64 + x86_64. Intel Mac users, you're back.

## The $99 question

Here's the thing I'm a bit embarrassed to keep bringing up, but it genuinely matters for the user experience: Remindian isn't notarized. Every new user has to open Terminal and run `xattr -cr /Applications/Remindian.app` before the app will launch. For people who aren't comfortable with the command line, that's a dealbreaker.

The Apple Developer Program costs $99/year. That's it — one payment and every future release gets:

- **Notarization** — Double-click to install, no Terminal, no Gatekeeper warnings
- **App Store listing** — Discoverability and automatic updates
- **The door opens for an iOS companion app** — something I've been sketching out

We're at **$60 raised** so far. $39 to go.

I don't run ads, I don't collect data, and the app is fully open source. If Remindian saves you even a few minutes a week, and you're in a position to chip in, it would mean a lot:

- **GitHub Sponsors:** https://github.com/sponsors/Santofer
- **Buy Me a Coffee:** https://buymeacoffee.com/santofer

And if you can't contribute financially — that's completely fine. Filing issues, testing releases, telling a friend about the app, or even just starring the repo helps more than you'd think.

## Links

- GitHub: https://github.com/Santofer/Remindian
- Download: https://github.com/Santofer/Remindian/releases/tag/v5.6.0
- Homebrew: `brew tap Santofer/remindian && brew install --cask remindian`
- Full changelog: https://github.com/Santofer/Remindian/blob/main/CHANGELOG.md

Thanks for everything. Seriously.

-- Santofer

---

*Built with SwiftUI. AI (Claude) was used as a development tool — all code is reviewed and the full source is open for audit.*
