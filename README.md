# Perch

A personal Mac workspace that lives in the notch: tasks, notes, focus timers, calendar events and recent clips, one hover away or on Option-N.

The feature set follows [NotchOwl's public feature list and changelog](https://www.notchowl.com/changelog). No code or assets come from it, and its app was never downloaded or inspected. See the pinned tracking issue for what's confirmed working.

## Build and run

Needs macOS 14 or later, Apple silicon and Xcode.

```sh
./scripts/build.sh            # builds dist/Perch.app
./scripts/build.sh --install  # also replaces /Applications/Perch.app and launches it
swift test                    # logic tests
```

Signing with your Apple Development certificate keeps macOS permissions across rebuilds. The script falls back to ad-hoc signing, which re-prompts every time.

## How it's put together

- `Sources/PerchCore`: everything testable and free of AppKit. The data model, natural-language parser, repeats, focus timer, insights, Reminders sync decisions, the MCP protocol and agent config editing. The `Workspace` class is the only writer of the data.
- `Sources/Perch`: the app. `NotchController` owns the panel, hover, hotkey and screens. `Services/` wraps EventKit, speech, the clipboard and the MCP socket. `Views/` is SwiftUI.
- `Perch --mcp` is what AI clients launch. It's a pipe from stdin and stdout to a Unix socket in the running app, readable only by your user.
- `Perch --snapshot <folder>` renders every screen to PNG with sample data, without needing Screen Recording permission.

Data lives in `~/Library/Application Support/Perch/`: `store.json` for the planner, and `clips.json` plus `Clips/` for clips, which stay out of the JSON backup.

## Left out on purpose

Licensing and activation, the update button, usage analytics and the bug report button. It's a personal app built from source.
