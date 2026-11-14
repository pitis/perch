# Perch

A personal macOS app that lives in the notch: tasks, notes, focus timers, calendar events and clips. Swift 6 toolchain in Swift 5 language mode, SwiftUI inside an AppKit panel, macOS 14+ on Apple silicon. It's built from source or installed from a release DMG.

## Commands

```sh
make check                                  # the gate: swift test (no linter is configured)
swift test --filter NLParserTests/testTimes # one test
./scripts/build.sh                          # builds and signs dist/Perch.app
./scripts/build.sh --install                # replaces /Applications/Perch.app and launches it
swift build && .build/debug/Perch --snapshot <folder>  # renders every screen to PNG with sample data
make shots out=<folder>                     # the same, from where this branch forked and from this checkout
make worktree name=<slug> branch=<type>/<slug>  # see Worktrees
make update                                 # merge the latest base into this branch
make setup                                  # once per clone: enables .githooks/
make icon                                   # rebuilds scripts/AppIcon.icns after the bird changes
make dmg                                    # dist/Perch-<version>.dmg, from a clean checkout (see Releasing)
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
- **Perch's bird is drawn in `Views/AppMark.swift`, never an SF Symbol.** Apple's license doesn't allow SF Symbols in an app icon or logo. The icon, the menu bar, the panel header and the reminder card all use it. After changing it, run `make icon` and commit `scripts/AppIcon.icns` and `docs/images/icon.png`.
- **Don't use popovers or sheets inside the notch panel.** `NotchController.mayAutoClose` doesn't know about them, so the panel would close underneath them. Build inline overlays like `TaskEditor`, and use `Menu` freely.
- **Blocking file access stays off the main thread.** Touching a protected folder can block on a macOS prompt.
- **Don't touch the Desktop folder unless `captureScreenshots` is on.** It's off by default, because watching that folder is what triggers the prompt.
- **Clips stay out of `AppData`,** so clipboard contents never end up in a JSON backup. Never store pasteboard items marked as concealed or transient.
- **Config files edited by `AgentConfig` hold other people's settings and sometimes credentials.** Keep the backup, keep the file permissions, and refuse to overwrite anything unparseable.

## Decisions

- **Spec:** feature parity with NotchOwl, using only its public site and [changelog](https://www.notchowl.com/changelog). Never download or inspect its app, and never use its name, logo or assets.
- **Left out on purpose:** licensing and activation, the update button, usage analytics, the bug report button.
- **Reminders sync:** the most recent edit wins. Each repeat occurrence is its own reminder with no recurrence rule: a repeat set in the Reminders app becomes the task's repeat and comes off the reminder, and one Perch can't express stays in Reminders and clears the task's repeat here, even one set later in Perch. Moving that task to the Inbox takes the rule off too, because Reminders can't repeat a reminder with no date, so it then repeats nowhere. Perch treats every alarm at a fixed time or at the due time as its own. A location alarm set on iPhone stays, and so does an early reminder while the task has a time, but a repeat's next occurrence starts without them. Deadlines travel as a `Deadline: yyyy-MM-dd` last line in the notes. Many items vanishing at once unlinks tasks rather than deleting them, and so does any missing reminder on the first sync after a backup restore.
- **Signing:** the Apple Development certificate, because a stable signature keeps macOS permissions across rebuilds. No hardened runtime. Releases are signed the same way and not notarized, which needs a paid Developer ID, so a downloaded copy opens the first time through Open Anyway.

## Testing on the real Mac

The user runs this app for real, so testing must not interrupt them or touch their data.

- **Never launch copies under a new bundle ID, or do anything else that raises macOS permission prompts.** Each new ID makes macOS ask again, which already caused repeated prompts on the user's screen.
- **Don't change the user's clipboard, or print its contents.** `pbcopy` loses images and formatting even if you restore it.
- **Keep live test data away from the real store** by setting `CFFIXED_USER_HOME` to a short path such as `.build/e2e`. The socket is `<home>/Library/Application Support/Perch/mcp.sock`, and macOS allows 103 bytes, so the fake home must resolve to an absolute path of at most 60. Otherwise the app logs it and turns MCP off. From a worktree, `.build/e2e` is already too long, so use `/tmp/perch-<n>` there.
- **`./scripts/build.sh --install` replaces the copy the user runs every day.** Only run it from `main`, or after asking.
- **A fake home is a first launch,** so Perch opens its setup window, which takes focus. Unless you're testing setup itself, first write `{"tasks":[]}` to `<home>/Library/Application Support/Perch/store.json` (`StoreTests` checks that it loads).
- **That fake home changes what you're testing.** It also redirects the Desktop, and launching from a shell attributes permissions to the parent process, so prompts behave differently. Only `open` matches a real launch.
- **Ask before** turning on Reminders sync or clicking Connect for an AI client. Those write to real Reminders and to `~/.claude.json`.

## Tracking work

Issues are at [pitis/perch](https://github.com/pitis/perch/issues), with the pinned [#1](https://github.com/pitis/perch/issues/1) as the feature checklist. Label `verify` means built but not yet run for real, and `gap` means not built. `product.md` lists the same status feature by feature, and the [Perch board](https://github.com/users/pitis/projects/6) shows every open issue but the #1 checklist by status. Keep all three accurate, and only mark something done after running it for real rather than because the code compiles or the logic tests pass.

- **Board statuses:** Needs decision (waiting on the user's answer, label `question`), Todo (`gap`, or a `bug` without `verify`), In progress (a PR is open), In review (`verify`: merged, waiting to be run for real), Done (closed). The board moves nothing by itself, so steps 5 and 8 below move each issue.
- **Every new issue goes on the board** with its status: `gh project item-add 6 --owner pitis --url <issue>`, then `gh project item-edit 6 --owner pitis --url <issue> --field Status --value "<status>"`. A new item can take a few minutes to show up. Until then use the id form: `--id` from `item-add --format json --jq .id`, `--project-id` from `gh project view 6 --owner pitis --format json`, and the field and option ids from `gh project field-list 6 --owner pitis --format json`.

## Ticket flow

An issue named or linked in chat **is the instruction to run this whole flow, end to end, without asking whether to start.** Stop and ask only for product decisions the issue doesn't answer, never for mechanics.

1. Read the issue fully. Check for an existing PR and branch (`gh pr list --state all`, `git branch -a`).
2. Work in **a worktree**, never by switching branches in the main checkout (other sessions share it, so keep it on `main`). New work: `make worktree name=<slug> branch=<type>/<slug>` (`feat/`, `fix/`, `chore/`, `perf/`), named right from the start, because a PR's branch can't be renamed. Add `base=origin/<branch>` to stack on an open PR. For an existing branch, use its worktree and run **`make update` before writing code**.
3. Implement test-first where the logic lives in `PerchCore`. A test proves a fix only if it failed before the fix.
4. Verify with `make check`. A change to anything on screen also gets `make shots out=<folder outside the repo>`: look at the screens it touches, before and after. Anything that needs the running app follows *Testing on the real Mac*.
5. Push with `git push -u origin HEAD` (new branches don't track anything yet) and open the PR with `gh pr create`, then move its issue to In progress on the board. Title: the effect, in a plain sentence. Body: what changed, why, how it was tested, and the issue. Write `Closes #<n>` only if the change was run for real; otherwise `Refs #<n>`, and after the merge a `gap` or `bug` issue becomes `verify` (see *Tracking work*).
6. **Every PR that changes what's on screen carries before/after screenshots**, from `make shots`, of only the screens it touches. Write `body.md` in the shots folder as a `| Before | After |` table with one row per screen (`| ![Before](./before-workspace.png) | ![After](./after-workspace.png) |`), then `gh pr comment <n> --body-file <folder>/body.md --attach <folder>/before-workspace.png --attach <folder>/after-workspace.png …`. `gh` uploads each file and rewrites its reference.
7. **Right after opening the PR, without being asked,** run `/pr-review-toolkit:review-pr` and `/ponytail:ponytail-review` on the PR's own diff (`git diff origin/main...HEAD`; a stacked PR's base is its parent branch). There are no other reviewers, so these are the review. Fix every Critical and Important finding on the same branch without waiting, re-run the checks (and the shots, if the screens changed again), push, and post one PR comment listing each finding and its fix. Declining a finding is a stated ruling, not silence. A finding that needs a product decision stays unfixed and goes to the user. Then report the same in chat. The PR is ready for the user only after this step.
8. **Merge only on the user's go,** from the main checkout: check `git status` in the worktree, `git worktree remove worktrees/<n>--<slug>`, then `gh pr merge <n> --squash --delete-branch`. A branch that's still checked out in a worktree can't be deleted. Then move the issue on the board: Done if the PR closed it, otherwise In review once it has `verify`.

## Worktrees

- `make worktree` creates `worktrees/<PR number>--<slug>` inside the main checkout (gitignored). The number is the branch's PR if it has one. Otherwise it's one more than the highest issue, PR or local worktree number. That's a guess, and the folder keeps it even if the PR gets another number. A new branch starts from the latest `origin/main`, or from `base=origin/<branch>`. An existing branch is checked out as it is. Each worktree has its own `.build`, so its first build is a full one. It also fast-forwards the main checkout's `main`, because sessions started there read its `AGENTS.md`.
- `make update` merges `origin/main` into the branch, or the stacked base until that base's PR is merged or its branch is deleted. From then on it follows `main`. When the base was squash-merged, it first records the squash as already merged, so the base's changes arriving again from `main` don't conflict. On a conflict it makes no merge, and prints the conflicted files and the `git merge` to run.
- A closed PR's worktree goes the same way as a merged one: check `git status` there, then `git worktree remove worktrees/<n>--<slug>` and `git branch -D <branch>`.

## Git

- **Never `--no-verify`.** There's no CI: `.githooks/` (enabled by `make setup`) and `make check` before every push are the whole gate. Fix the cause or stop and ask. Hooks only run on branches that contain `.githooks/`, and `make update` brings it to older ones.
- **Never force-push or rebase a pushed branch.** Catch up with `make update`. The same goes for `commit --amend` and `reset --hard` on pushed commits.
- One issue = one PR, and review fixes go on the same branch. Squash-merge only. No `#NNN` in commit messages, only in PR bodies.
- No AI attribution anywhere: commits, PR bodies and comments (no `Co-Authored-By`, no "Generated with"). The hooks only catch Claude's co-author trailer and "generated with" line, in commit messages and staged lines. The rest is up to you.
- PR screenshots and test evidence stay out of the repo. Only the README's images live in `docs/images/`.

## Releasing

Only on the user's go.

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `scripts/Info.plist` in a PR.
2. Once it's merged, in the main checkout on an up-to-date `main`: `make dmg`. It refuses uncommitted changes, so the DMG matches a commit.
3. `git tag v<version> && git push origin v<version>`, then `gh release create v<version> dist/Perch-<version>.dmg --prerelease --title "Perch <version>" --notes-file <notes>`. The notes say what changed, what's confirmed working (`product.md`), and how to get past the not-notarized warning.
