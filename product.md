# Perch: what's done and what isn't

Last updated: 8 November 2026

The target is the feature set on [NotchOwl's site](https://www.notchowl.com/) and [changelog](https://www.notchowl.com/changelog).

**Done** means it was run in the real app on the Mac and worked. Code that compiles or passes unit tests counts as not done until then.

## Done

**Opening and closing**
- Hover the notch to open, and move away to close
- Option-N opens and closes the panel, with the cursor ready in the task composer
- The panel stays open while you type, and Esc or clicking elsewhere closes it
- The keyboard goes back to your previous app on close

**Tasks**
- Add a task by typing
- Typed natural language fills in the day, time, reminder and project: "water plants friday at 9am #home"

**Reminders**
- The reminder card opens in the notch when a reminder is due
- 5 min snoozes it, and Done completes the task

**Focus**
- The timer starts and stops, and logs the active time (run through MCP, not the buttons)

**AI agents**
- The local MCP server runs, with a socket only your user can read
- Tested live: the handshake, listing all 15 tools, and adding and listing tasks, setting reminders, writing notes and running the timer

**Clips**
- Copied text is kept
- Items marked as private are never saved (tested with a simulated password manager item)
- Files marked as screenshots are picked up and ordinary images are ignored (tested with simulated files)

**App**
- App icon, in Finder and the menu bar and on the panel
- Data survives a relaunch
- Idle use is about 0% CPU and 32 MB of memory

## Not done: written, but not tried for real

**Look on the real screen** ([#2](https://github.com/pitis/perch/issues/2))
- Panel alignment with the notch, including at scaled resolutions
- Open and close animation
- WELCOME BACK greeting
- Timer, PAUSED and DONE beside the notch
- Menu bar icon and menu

**Tasks and Week** ([#3](https://github.com/pitis/perch/issues/3))
- Complete and un-complete, and the Completed tab
- Previous and next day
- Drag to reorder
- Double-click to rename
- Swipe left to delete, with Undo
- Overdue tab, with moving everything to today
- Task menu: Today, Tomorrow, Next week, Inbox, Delete
- Task editor: day, reminder, deadline, priority, project, repeat, focus length, notes and steps
- Priority, repeats and deadlines in typed text (unit-tested)
- Repeating tasks creating their next occurrence (unit-tested)
- Week view: Inbox beside the next 14 days, dragging between them, and adding from a column

**Notepad** ([#3](https://github.com/pitis/perch/issues/3))
- Typing and autosave
- Command-Return turns a line into a task (unit-tested)
- Word count and notes for other days

**Focus controls** ([#3](https://github.com/pitis/perch/issues/3))
- Start, Pause, Resume, Add 5 min and finish buttons
- Set time, custom minutes and stopwatch
- Task picker and starting focus from a task
- Clock styles

**Insights** ([#3](https://github.com/pitis/perch/issues/3))
- Weekly summary, completed vs planned, focus time, active days and peak hour (unit-tested, seen with sample data)
- Tasks and Focus chart, and hovering a bar
- History of finished tasks

**Customize** ([#3](https://github.com/pitis/perch/issues/3))
- Show or hide cards, and S, M or L widths
- Reorder with arrows or by dragging the handle
- Black & white mode and default focus length

**Two-way Apple Reminders sync, for iPhone and Apple Watch** ([#4](https://github.com/pitis/perch/issues/4))
- Never run against real Reminders, though its decisions are unit-tested
- Off by default, and it writes to real data, so try it with throwaway tasks first

**External monitors and full-screen** ([#5](https://github.com/pitis/perch/issues/5))
- A drawn notch on monitors, and following the pointer between screens
- Stepping aside for full-screen apps and Split View, with the top edge still opening it
- Settings › Show on and Notch on monitors
- Macs without a notch opening below the menu bar

**Voice** ([#6](https://github.com/pitis/perch/issues/6))
- Dictation in the task composer and Notepad, on-device only

**Clips with real files** ([#7](https://github.com/pitis/perch/issues/7))
- Real screenshots and screen recordings (off until you click "Show screenshots here", because macOS then asks for Desktop access)
- Copied images and files
- Click to copy, double-click to open and drag into other apps
- Dragging a file onto the notch
- Removing clips and Clear all

**Calendar** ([#8](https://github.com/pitis/perch/issues/8))
- Connect, today's events and Refresh, only seen with sample data so far
- Ticking off events locally

**Connecting AI clients** ([#9](https://github.com/pitis/perch/issues/9))
- Connect and Disconnect for Claude Code, the Claude app and Cursor (config editing is unit-tested)
- Restart button and Try asking suggestions
- A client starting Perch when it isn't running

**Apple Intelligence** ([#10](https://github.com/pitis/perch/issues/10))
- Priority and project suggestions for new tasks

**Reminders and focus in real conditions** ([#11](https://github.com/pitis/perch/issues/11))
- Chime sounds
- Several reminders at once, a reminder while the panel is open, and over full-screen apps
- Timer pausing when the Mac sleeps (unit-tested), and reminders ringing after wake
- macOS notifications while Perch is quit
- Midnight rollover
- Timer recovery after a force quit

**Settings and windows** ([#12](https://github.com/pitis/perch/issues/12))
- Settings window
- Full dashboard window
- Launch at login
- JSON backup export

## Not done: not built yet

- First-run permission setup or welcome tour ([#13](https://github.com/pitis/perch/issues/13))
- Picking any date from the date control and Reschedule ([#15](https://github.com/pitis/perch/issues/15))
- Resizing cards by dragging ([#16](https://github.com/pitis/perch/issues/16))
- Repeats set on iPhone, and custom repeat rules in the task editor ([#17](https://github.com/pitis/perch/issues/17))
- Languages other than English, numeric dates such as 12/25, and detecting recordings without their English file name ([#18](https://github.com/pitis/perch/issues/18))
- Full keyboard navigation and a VoiceOver pass ([#19](https://github.com/pitis/perch/issues/19))
- Restoring from a JSON backup, which goes beyond the reference product ([#20](https://github.com/pitis/perch/issues/20))

## Left out on purpose

Perch is a personal app built from source, so these aren't planned:

- Licensing and activation
- Notarization and DMG distribution
- Update button and update checks
- Usage analytics
- Bug report button
