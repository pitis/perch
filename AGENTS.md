# Perch

A personal macOS app that lives in the notch: tasks, notes, focus timers, calendar events and clips. Swift 6 toolchain in Swift 5 language mode, SwiftUI inside an AppKit panel, macOS 14+ on Apple silicon. There's one user, and it's built from source.

## Commands

```sh
swift test                                  # logic tests (no linter is configured)
swift test --filter NLParserTests/testTimes # one test
./scripts/build.sh                          # builds and signs dist/Perch.app
./scripts/build.sh --install                # replaces /Applications/Perch.app and launches it
swift build && .build/debug/Perch --snapshot <folder>  # renders every screen to PNG with sample data
```

`--snapshot` is how to look at UI changes: shells here have no Screen Recording permission, so `screencapture` fails.

## Architecture

- **`Sources/PerchCore`** holds all the logic and doesn't import AppKit, which is why it's testable. **`Sources/Perch`** is the shell: `NotchController` (panel, hover, hotkey, screens), `AppHub` (shared state, wake timer, saving), `Services/` (EventKit, speech, clipboard, MCP socket) and `Views/`.
- **`Workspace` is the only writer of app data**, always on the main thread. The UI, Reminders sync and MCP all go through it, so there's nothing to merge. Every change fires `onChange`, which saves after a short delay, re-arms the wake timer and schedules a sync.
- **Almost nothing polls while idle:** only the 1s clipboard check and a 5-minute Reminders sync. A single timer is aimed at `Workspace.nextWake()`, the next reminder or countdown end.
- **MCP has two ends.** `MCPServer` is pure line-in, line-out JSON-RPC. The running app serves it on a Unix socket, readable only by the user, in `~/Library/Application Support/Perch/`. `Perch --mcp`, which AI clients launch, only pipes stdio to that socket and starts the app if needed.
- **Reminders sync splits decisions from effects.** `Reconciler.plan` is pure and tested and returns actions, and `RemindersSync` applies them through EventKit. Remote writes are committed first, and local changes only happen if that succeeds.

## Rules the code relies on

- **Days are local `yyyy-MM-dd` strings** (`Day`), so a task stays on Friday across time zones and string order is date order. A nil `day` means the Inbox.
- **New persisted fields must use `lenient` in the type's custom `init(from:)`.** Synthesized decoding would throw on older files and lose the user's data.
- **Don't use popovers or sheets inside the notch panel.** `NotchController.mayAutoClose` doesn't know about them, so the panel would close underneath them. Build inline overlays like `TaskEditor`, and use `Menu` freely.
- **Blocking file access stays off the main thread.** Touching a protected folder can block on a macOS prompt.
- **Don't touch the Desktop folder unless `captureScreenshots` is on.** It's off by default, because watching that folder is what triggers the prompt.
- **Clips stay out of `AppData`,** so clipboard contents never end up in a JSON backup. Never store pasteboard items marked as concealed or transient.
- **Config files edited by `AgentConfig` hold other people's settings and sometimes credentials.** Keep the backup, keep the file permissions, and refuse to overwrite anything unparseable.

## Decisions

- **Spec:** feature parity with NotchOwl, using only its public site and [changelog](https://www.notchowl.com/changelog). Never download or inspect its app, and never use its name, logo or assets.
- **Left out on purpose:** licensing and activation, the update button, usage analytics, the bug report button.
- **Reminders sync:** the most recent edit wins. Each repeat occurrence is its own reminder with no recurrence rule. Deadlines travel as a `Deadline: yyyy-MM-dd` last line in the notes. Many items vanishing at once unlinks tasks rather than deleting them.
- **Signing:** the Apple Development certificate, because a stable signature keeps macOS permissions across rebuilds. No hardened runtime.

## Testing on the real Mac

The user runs this app for real, so testing must not interrupt them or touch their data.

- **Never launch copies under a new bundle ID, or do anything else that raises macOS permission prompts.** Each new ID makes macOS ask again, which already caused repeated prompts on the user's screen.
- **Don't change the user's clipboard, or print its contents.** `pbcopy` loses images and formatting even if you restore it.
- **Keep live test data away from the real store** by setting `CFFIXED_USER_HOME` to a short path such as `.build/e2e`. Longer paths fail, because Unix socket paths are limited to 104 characters. The app logs this and turns MCP off.
- **That fake home changes what you're testing.** It also redirects the Desktop, and launching from a shell attributes permissions to the parent process, so prompts behave differently. Only `open` matches a real launch.
- **Ask before** turning on Reminders sync or clicking Connect for an AI client. Those write to real Reminders and to `~/.claude.json`.

## Tracking work

Issues are at [pitis/perch](https://github.com/pitis/perch/issues), with the pinned [#1](https://github.com/pitis/perch/issues/1) as the feature checklist. Label `verify` means built but not yet run for real, and `gap` means not built. `product.md` lists the same status feature by feature. Keep both accurate, and only mark something done after running it for real rather than because the code compiles or the logic tests pass.
