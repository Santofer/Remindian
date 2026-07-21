# Working on Remindian

Notes for anyone (human or agent) doing maintenance on this repo.

## Before starting a maintenance session

Sweep **all four** inboxes, not just the obvious one. Issue #85 happened because
only the public issue tracker was ever checked, so a High-severity private
security advisory sat untriaged for a month:

```sh
gh issue list --repo Santofer/Remindian --state open            # public issues
gh pr list   --repo Santofer/Remindian --state open             # pull requests
gh api repos/Santofer/Remindian/security-advisories \
  --jq '.[] | "\(.ghsa_id) \(.state) \(.severity) \(.summary)"'  # ← easy to forget
```

Security advisories are **not** visible in `gh issue list`. They must be checked
explicitly. Note that the API does not expose advisory *comments*, so a reporter
pinging you there is invisible — when an advisory is open, reply through it in the
web UI, and say so in the public thread if the reporter is waiting.

### Never discuss unfixed vulnerabilities in public

This is a hard rule, and it has already been broken once. When a reporter has a
private advisory open *and* a public issue, the tooling can only write to the
public one — which creates real pressure to answer everything there. Do not.

In a public thread you may:

- acknowledge the report and apologise for delays,
- describe vulnerabilities that are **already fixed and released** (release notes
  and CHANGELOG entries for shipped fixes are normal and expected),
- say that remaining work is tracked in the advisory.

You must **not**, in public:

- enumerate unfixed findings, even as a to-do list,
- pair a severity with a component for anything unpatched (that alone is enough
  to point an attacker at the weak spot),
- explain why a fix is blocked in a way that describes the live weakness.

If answering properly needs those details, that answer belongs in the advisory —
ask the maintainer to post it there rather than writing it in the issue.

## Releasing

`scripts/update-casks.sh <version> <dmg>` is the only supported way to publish the
cask. It refuses to publish unless:

1. the URL the cask will actually request returns **HTTP 200**, and
2. the published asset's SHA-256 matches the DMG that was just built.

Both guards exist because of #84: the cask asked for `Remindian-v<version>.dmg`
while releases publish `Remindian-<version>.dmg`, and every `brew install` 404'd
for a month before a user noticed. Do not hand-edit the cask's `url` without
re-running the script.

There are **two taps**, and the script pushes to both:

- `Santofer/homebrew-tap` — **canonical**, what the README tells people to use.
- `Santofer/homebrew-remindian` — legacy; kept in sync only so it can't serve a
  stale build (it was pinned at 5.5.0 and actively *downgraded* users).

After releasing, verify through real Homebrew, not just curl:

```sh
brew update && brew fetch --cask santofer/tap/remindian
```

## Testing

Unit tests do not exercise the main thread or the GUI — a green suite has shipped
launch crashes before. For anything touching startup, sync triggers, or windows,
run the real app (`/Applications/Remindian.app`) before releasing.

New test files must be registered in `ObsidianRemindersSync.xcodeproj/project.pbxproj`
in four places (PBXBuildFile, PBXFileReference, the group's children, and the test
target's Sources phase) or they silently never run.

## Bug classes that have bitten this repo

- **Duplicate-key traps.** Building a `Dictionary` from user-controllable keys —
  a literal or `Dictionary(uniqueKeysWithValues:)` — is a `fatalError` on a
  duplicate, not a throw, so `try?` does not catch it. Use `uniquingKeysWith:`.
  (#80 crashed every launch this way.)
- **Narrowing the scan deletes reminders.** Anything that reduces which source
  tasks are scanned makes previously-synced tasks look deleted, and the engine
  removes their reminders. The configured inbox file must always stay in scope. (#81)
- **`DateFormatter` does not prefix-match.** A date-only format returns `nil` for
  a datetime string rather than truncating it. Parse most-specific-format-first. (#82)
- **AppleScript escaping must escape `\` before `"`.** Task content is
  attacker-influenced; escaping only the quote allowed injection into
  `NSAppleScript`. Use `Things3Destination.appleScriptEscape`. (GHSA-3q2g-hmqg-qj5r)
