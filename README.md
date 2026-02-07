# Codex Menu Bar

Codex Menu Bar is an open-source macOS menu bar app for monitoring Codex usage limits in real time.

## Why this app

- See session and weekly usage without opening the web app
- Track multiple Codex accounts in one place
- Sync credentials from Codex CLI (`codex login`)
- Keep account data local on your Mac
- Use a lightweight native Swift/SwiftUI app

## Open Source

- Repository: [4Artursmith/codex-menu-bar](https://github.com/4Artursmith/codex-menu-bar)
- License: [MIT](LICENSE)
- Contributions: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security policy: [SECURITY.md](SECURITY.md)

## Install

### Download Release

Download the latest build from:

- [Latest Release](https://github.com/4Artursmith/codex-menu-bar/releases/latest)

Then:

1. Download `Codex-Menu-Bar.zip`
2. Extract it
3. Move `Codex Menu Bar.app` to `/Applications`
4. Launch the app

## Build from source

Requirements:

- macOS 14+
- Xcode 15+

```bash
git clone https://github.com/4Artursmith/codex-menu-bar.git
cd codex-menu-bar
open "Codex Usage.xcodeproj"
```

Build and run in Xcode with `Cmd + R`.

## Quick setup

### Option A (recommended): Codex CLI login

1. Run `codex login` in Terminal
2. Open Codex Menu Bar
3. In app settings, add/sync current Codex account

### Option B: manual session key

1. Open the app settings
2. Add your Codex session key
3. Select organization
4. Save and refresh usage

## Features

- Session usage and weekly usage cards
- Manual and auto refresh
- Multi-profile account management
- Menu bar usage icon customization
- Notifications for usage thresholds
- Optional terminal statusline integration

## Notes

- This project is independent and community-maintained.
- The app name and branding are `Codex Menu Bar`.

