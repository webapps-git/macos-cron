# Cron for macOS

A menu bar task scheduler for macOS. Each task is a workflow of actions that runs on a schedule, on system events, or on demand.

## Features

- **Workflows** built from 66 action types: shell scripts and script files, AppleScript, Shortcuts, files and folders (copy, move, rename, compress, write, replace text…), HTTP requests, notifications and dialogs, clipboard, system volume, Time Machine, sleep/restart/shutdown, and control of other tasks and of the scheduler itself.
- **Schedules**: several rules per task — repeat every N minutes/hours/days from a start time (optionally only until a time or for a duration each day), set times every day, every N weeks, monthly (days of the month, last day, or e.g. first Monday) and once; weekday filters, a validity period, a run limit, and what to do with times missed while the Mac slept. Checked once a minute.
- **Events**: app launch, system wake, before sleep, screen wake/sleep/lock/unlock, screen connected/disconnected/resolution changed, volumes mounted/unmounted, files created/changed/deleted in a folder (name patterns, subfolders, waits until a file is complete), applications launched or quit, network connected/lost/changed, power adapter/battery and battery below a level, idle time, and other tasks starting, stopping or being cancelled (optionally only chosen tasks and results). Events can be limited to at most one run every N minutes.
- **Error handling**: per action stop, continue or retry N times; conditions (file, internet, process, tasks, text comparison, Time Machine) can finish without an error, fail or continue.
- **Integration**: Shortcuts actions (run a task and optionally wait for its output, enable/disable, last run result, pause/resume the scheduler); `webapps-cron://run?task=Name` links for tasks that allow them; a "Run task" menu and the last error in the menu bar; "Show result" and "Run again" buttons in notifications.
- **Variables**: `{previous}`, `{step:N}`, `{task}`, `{date}`, `{time}`, `{file}` and `{app}` in action fields; scripts get the same values only as `CRON_*` environment variables, never pasted into the script.
- **Control**: per-step time limit for scripts, Stop button for running tasks, completion notifications, pause/resume from the menu bar.
- **History**: every run is kept with its steps, exit codes and output (up to 100 KB per run); copy or save the output; retention configurable in Settings (default 30 days, 200 runs per task).
- **Task management**: groups, search, sorting, multiple selection, duplicate, enable/disable from the list, export and import as JSON (imported tasks start disabled), delete with confirmation. Notifications: always, errors only (default) or never.
- 43 languages.

## Requirements

- macOS 15.0 or later, Apple Silicon or Intel (universal build).
- Xcode 26 or later to build (the project uses Swift 6.2 language features).

## Build

**Xcode:** create `Local.xcconfig` next to `Signing.xcconfig` with your team (`DEVELOPMENT_TEAM = ABCDE12345`; the file is not committed), open `Cron.xcodeproj` and run. Without a team, choose *Sign to Run Locally* under *Signing & Capabilities*.

**Command line** (builds Release and installs into `/Applications`):

```bash
CRON_ADHOC=1 ./build.sh
```

`CRON_ADHOC=1` signs the app ad hoc, so no Apple developer account is needed; the result runs on the Mac that built it. Without it, `build.sh` signs with the team from `Local.xcconfig`, or ad hoc when that file does not exist.

To share a ready-built app with other people, sign it with a Developer ID certificate and notarize it, otherwise Gatekeeper blocks it.

## Permissions

Some actions need macOS permissions. The Settings window shows their status and opens the right System Settings pane:

- Automation (AppleScript, controlling other apps)
- Accessibility
- Screen Recording (screenshots)
- Notifications
- Full Disk Access or Files and Folders, depending on the paths your scripts use

## Notes

- Cron is **not sandboxed**: it runs shell scripts and controls other apps with your user's privileges. Only run workflows you understand. For the same reason it cannot be distributed through the Mac App Store.
- Tasks and run history are stored in `~/Library/Application Support/Cron/`.
- Tests: `xcodebuild test -scheme Cron` (Swift Testing) and `python3 Tools/run_comprehensive_tests.py` (static checks: action catalog, localizations, project settings).

## License

MIT, see [LICENSE](LICENSE).
