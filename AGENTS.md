# Agent guidelines

## Project summary
blackoutd is an Objective-C macOS LaunchAgent daemon with a menu bar GUI.
It blacks out the built-in display when an external display is connected.

## Architecture
- `src/main.m` — CLI dispatch and daemon entry point (`blackoutd daemon` subcommand)
- `src/AppDelegate.m/.h` — NSApplication delegate; menu bar item, signal handlers,
  WindowServer readiness, state restoration
- `src/DisplayController.m/.h` — All CoreGraphics display operations; reconfiguration
  callback; blackout state machine
- `blackoutd.plist.template` — LaunchAgent plist template ({{BUNDLE_ID}} {{HOME}}
  substituted at install time by `make postinstall`)
- `src/Info.plist` — Embedded bundle metadata (required for WindowServer connection)

## Key constraints
- Target: macOS 13+, Apple Silicon
- Compiler: clang via Xcode Command Line Tools (no Xcode project file)
- No third-party dependencies
- Uses private symbol `CGSConfigureDisplayEnabled` (extern declaration only —
  resolved at runtime from CoreGraphics/SkyLight)
- Ad-hoc codesigned only (no Developer ID)
- Bundle ID: `io.github.toobuntu.blackoutd`
- LaunchAgent label: same as bundle ID

## Safety invariant
The built-in display MUST be restored when the last external display disconnects.
This check in `handleReconfiguration:flags:` is unconditional — it must never be
gated on `_applyingChange` or any other guard.

## Signal handling
| Signal  | Behaviour                          |
|---------|------------------------------------|
| SIGUSR1 | Enable blackout                    |
| SIGUSR2 | Disable blackout (restore built-in)|
| SIGHUP  | Reload preferences from NSUserDefaults |
| SIGTERM | Clean shutdown (restores built-in) |
| SIGKILL | Cannot be caught — see README Known Issues |

## NSUserDefaults suite
`blackoutd` (distinct from bundle ID to avoid macOS warning)

Keys:
- `autoBlackoutOnExternalConnect` (BOOL, default YES)
- `blackoutActive` (BOOL) — persisted blackout intent

## Testing checklist
- [ ] `blackoutd on` blacks out built-in
- [ ] `blackoutd off` restores built-in
- [ ] Unplugging external restores built-in unconditionally
- [ ] `blackoutd daemon stop` restores built-in before exit
- [ ] `blackoutd daemon start` after stop re-bootstraps agent
- [ ] `blackoutd status` reflects actual display state (not persisted state)
- [ ] Menu bar icon updates on state change
- [ ] Auto-blackout toggle applies immediately if external already connected
- [ ] Disabling auto-blackout restores built-in if currently blacked out
- [ ] `make clean; make; make reinstall` cycle succeeds without sudo for reinstall
