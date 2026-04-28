# blackoutd

A macOS menu bar daemon that blacks out the built-in display when an external
display is connected, preserving screen real estate and reducing distraction.

## Table of Contents

- [Background](#background)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Logging](#logging)
- [How it works](#how-it-works)
- [Known issues](#known-issues)
- [Tech notes](#tech-notes)
- [Contributing](#contributing)
- [License](#license)

## Background

blackoutd exists for MacBook users who work primarily on an external display but
use the built-in keyboard and trackpad. macOS mirrors or extends the desktop to
the built-in display whenever it is active — which wastes energy and, more
practically, means the built-in screen is visible to others nearby during video
calls even when you are looking at the external.

The tool was built specifically to suppress that. The built-in is fully disabled
at the compositor level when an external is connected, and automatically restored
when the external is disconnected, so the Mac is never left without a usable
display.

### Why not pmset?

`pmset displaysleepnow` turns off all displays immediately but wakes them on any
input and does not persist across sleep/wake. `pmset sleepnow` puts the whole
system to sleep.

Neither does what blackoutd does: keep the external display live and active while
suppressing only the built-in, persistently, with automatic re-application after
sleep/wake cycles and display reconnects.

Clamshell mode (lid closed) achieves a similar result but requires a power
connection and an external keyboard and mouse. blackoutd is designed for the
opposite situation — lid open, using the built-in keyboard and trackpad, external
display only.

## Requirements

**Runtime:**

- macOS 13 or later
- Apple Silicon Mac (tested on M2 MacBook Air)

**Build:**

- Xcode Command Line Tools: `xcode-select --install`

## Install

```sh
make
sudo make install
```

This builds the binary, installs it to `/usr/local/bin/blackoutd`, installs the
LaunchAgent plist, and bootstraps the agent for the current user.

## Usage

```
blackoutd on                  Black out built-in display
blackoutd off                 Restore built-in display
blackoutd status              Show daemon and display status
blackoutd auto on|off         Enable/disable auto-blackout on external connect
blackoutd --config            Print diagnostic info for bug reports
blackoutd daemon start        Start daemon via launchctl
blackoutd daemon stop         Stop daemon and restore built-in display
```

## Upgrade

For end users:

```sh
git pull
make clean && make
sudo make install
```

For development iteration without re-installing to `/usr/local/bin`:

```sh
make clean && make && make dev
```

`make dev` does not require `sudo`. It bootouts the running agent, regenerates
the LaunchAgent plist pointing to the freshly built binary in `build/`, and
bootstraps the new plist. The CLI binary at `/usr/local/bin/blackoutd` is not
updated by `make dev`; run `sudo make install` to refresh it for production
use.

## Uninstall

```sh
make uninstall
```

## Logging

blackoutd writes structured logs to stderr, captured to
`~/Library/Logs/blackoutd.log` via the LaunchAgent plist. Console.app will
find the log automatically under the Logs category. Log lines are tagged by
subsystem:

```
[startup]   session init and state restoration
[quit]      graceful termination
[prefs]     preference reload (SIGHUP)
[change]    display connectivity events; class=hardware|virtual|builtin on
            events that drive state changes; suppressed events log a reason instead
[external]  external display evaluation result (vendor, hardware vs. virtual)
[builtin]   built-in display actions and outcomes
[state]     decision logic and conclusions
[sleep]     sleep transition — display changes suppressed until wake
[wake]      wake transition — display change monitoring resumed
```

Example sequence for startup with external display connected:

```
[startup] — session started with builtInId=1
[startup] — verbosityLevel=1
[external] id=2 vendor=0x10ac (Dell) — hardware display detected
[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating blackout
[builtin] id=1 action=blackout result=pending isBlackedOut=0
[builtin] id=1 action=blackout result=complete isBlackedOut=1
[builtin] id=1 action=blackout result=settled isBlackedOut=1
```

Example sequence for live external display connect (callback path):

```
[change] id=2 event=connected class=hardware
[external] id=2 vendor=0x10ac (Dell) — hardware display detected
[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating blackout action
[builtin] id=1 action=blackout result=pending isBlackedOut=0
[builtin] id=1 action=blackout result=complete isBlackedOut=1
[builtin] id=1 action=blackout result=settled isBlackedOut=1
```

Example sequence for sleep/wake with external display remaining connected:

```
[sleep] — ignoring display changes
[change] id=2 event=disconnected — ignored, sleeping
[change] id=76 event=connected — ignored, sleeping
[wake] — resuming display change monitoring
[change] id=76 event=disconnected class=virtual
[external] id=2 vendor=0x10ac (Dell) — hardware display detected
[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating blackout action
[builtin] id=1 action=blackout result=pending isBlackedOut=0
[builtin] id=1 action=blackout result=complete isBlackedOut=1
[builtin] id=1 action=blackout result=settled isBlackedOut=1
```

Example sequence for sleep with external display unplugged during sleep:

```
[sleep] — ignoring display changes
[change] id=2 event=disconnected — external disconnect noted during sleep
[change] id=76 event=connected — ignored, sleeping
[wake] — resuming display change monitoring
[wake] — external disconnected during sleep — disabling blackout
[builtin] id=1 action=restore result=pending isBlackedOut=1
[builtin] id=1 action=restore result=complete isBlackedOut=0
[builtin] id=1 action=restore result=settled isBlackedOut=0
```

Verbosity is level 1 by default (semantic logs only). Level 2 adds
`[verbose=2]`-tagged lines with raw CGDisplayChangeSummaryFlags values and
decoded connectivity details, useful for diagnosing unexpected display events.

Enable verbose logging at runtime without restarting the daemon:

```sh
defaults write blackoutd verbosityLevel -int 2
killall -HUP blackoutd
```

Reset to default:

```sh
defaults delete blackoutd verbosityLevel
killall -HUP blackoutd
```

## How it works

blackoutd uses the private `CGSConfigureDisplayEnabled` symbol (re-exported from
SkyLight.framework through CoreGraphics) to disable the built-in display at the
compositor level. The display is fully off — not just dimmed — while the daemon
process holds a live WindowServer connection that maintains the enabled state.

On external display disconnect, the built-in is unconditionally restored
regardless of user intent. Leaving a Mac with no usable display is never
acceptable.

## Known issues

**Username change**: The LaunchAgent plist and log path are hardcoded to the
home directory at install time. If the macOS username is changed after
installation, run `sudo make install` from the source directory to regenerate
the plist and re-register the agent with the correct paths.

**Preferences migration**: Versions using the `local.blackoutd` bundle ID
stored preferences under `local.blackoutd.prefs`. That file is no longer read.
All settings default to safe values on first run (`autoBlackoutOnExternalConnect`
defaults to enabled). The old file can be removed:

```sh
defaults delete local.blackoutd.prefs
```

If migrating from the `local.blackoutd` LaunchAgent, unload it first:

```sh
launchctl bootout gui/$(id -u)/local.blackoutd
rm ~/Library/LaunchAgents/local.blackoutd.plist
```

**SIGKILL**: If the daemon is killed with `SIGKILL` while the built-in is blacked
out, the display cannot be restored programmatically until the WindowServer
re-enumerates displays. Disconnect and reconnect the external display, or log out
and back in. Use `blackoutd daemon stop` or the menu bar Quit option instead of
`kill -9`.

**Coexistence with BetterDisplay/Lunar**: If another display manager is running
with its own disconnect-on-external feature enabled, the two daemons will fight.
Disable that feature in the other app before using blackoutd.

## Tech notes

### SMAppService (future)

If blackoutd is ever packaged as `Blackout.app`, the `launchctl bootstrap/bootout`
subprocess calls in `main.m` should be replaced with
`[SMAppService mainAppService]` register/unregister. This requires the LaunchAgent
plist to live at `Blackout.app/Contents/Library/LaunchAgents/io.github.toobuntu.blackoutd.plist`
and the binary to run from inside the bundle. See `man SMAppService` and
[Apple Developer docs](https://developer.apple.com/documentation/servicemanagement/smappservice).

### Mach port presence detection

`blackoutd status` and other CLI commands detect whether the daemon is running
via `bootstrap_look_up()` against the named Mach port
`io.github.toobuntu.blackoutd`, registered in the LaunchAgent plist under
`MachServices`. This is synchronous and requires no subprocess. The daemon calls
`bootstrap_check_in()` at startup to hold the receive right; when the daemon is
not running, the lookup fails and the CLI reports "not running".

For signal delivery, the daemon PID is obtained via sysctl process enumeration
filtered by three identity checks: `p_comm == "blackoutd"`, parent is launchd
(pid 1), and executable path matches the `ProgramArguments[0]` registered in
the LaunchAgent plist. This avoids colliding with concurrent CLI invocations
of the same binary.

### Display ID stability

`CGDirectDisplayID` values can change across reboots. The built-in display on
Apple Silicon is reliably ID 1 in practice, but `discoverBuiltInID` uses
`CGDisplayIsBuiltin()` enumeration for correctness.

### CLI status and diagnostics

`blackoutd status` works even when the daemon is not running — it queries
display state directly via CoreGraphics and reads preferences from
NSUserDefaults. When the daemon is not running it reports "not running" and
exits with code 1; when running it prints the PID, display state, and
auto-blackout setting.

`blackoutd --config` prints diagnostic info for bug reports: daemon state,
macOS version, per-display CoreGraphics info (vendor, model, resolution,
physical size), and hardware info via system_profiler. Log data (daemon log,
system log filtered by the blackoutd predicate, pmset sleep/wake events) is
collected into a timestamped directory under `/tmp/blackoutd-diag-*/` to
avoid flooding the terminal. The output prints the path to this directory.

## Contributing

PRs are welcome. Please open an issue first to discuss significant changes.

For development setup:

```sh
git config core.hooksPath .githooks
```

Run `make clean && make` to verify the build, and ensure `reuse lint` and
`clang-format --style=file --dry-run --Werror` pass on changed files before
submitting.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full encoding policy and other
contribution guidelines.

## License

[GPL-3.0-or-later](LICENSES/GPL-3.0-or-later.txt) © Todd Schulman
