# Contributing to Remindian

Thanks for your interest in contributing! Here's how to get started.

## Reporting Bugs

- Open an [issue](https://github.com/Santofer/Remindian/issues) with a clear title
- Include your macOS version and the steps to reproduce
- Add screenshots or log output if possible (logs are in `~/Library/Application Support/Remindian/`)

## Suggesting Features

Open an issue tagged as a feature request. Describe the use case and why it would be useful.

## Pull Requests

1. Fork the repo and create a branch from `main`
2. Make your changes — keep commits focused and well-described
3. Test with a real Obsidian vault and verify sync works end-to-end
4. Open a PR with a clear summary of what changed and why

### Build

```bash
git clone https://github.com/Santofer/Remindian.git
cd Remindian
open ObsidianRemindersSync.xcodeproj
```

Requires macOS 13.0+ and Xcode 15.0+.

### Code Style

- Follow existing Swift conventions in the project
- Use `debugLog()` for diagnostic logging
- Keep sync logic in `SyncEngine.swift`, Obsidian parsing in `ObsidianService.swift`
- Surgical edits only — never reconstruct full task lines

### Important Notes

- **Obsidian is the source of truth** — all sync decisions follow this principle
- **Backups first** — any code that writes to Obsidian files must create a backup
- **Dry run support** — new sync features should respect `config.dryRunMode`
- Test with both timer-based and FSEvents-based sync modes

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
