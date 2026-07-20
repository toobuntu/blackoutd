<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

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

For first-time installation:

```sh
make
make install
```

Run `make install` as your normal logged-in user, **not** under `sudo`. The
Makefile invokes `sudo` internally only for the privileged writes to
`/usr/local/bin` and `/usr/local/share` and will prompt for your password.
The plist generation, LaunchAgent install, and `launchctl bootstrap` steps
must run as your user — running the whole `make` command under `sudo` would
make `$HOME` resolve to `/var/root` and `id -u` return `0`, which would
write the plist into root's LaunchAgents directory and target the wrong
launchd domain (`gui/0`).

This builds the binary, installs it to `/usr/local/bin/blackoutd`, installs the
LaunchAgent plist into your `~/Library/LaunchAgents/`, and bootstraps the agent
for your GUI session. If the agent is already installed and running,
`make install` will fail with a clear error; use `make reinstall` instead
(see [Upgrade](#upgrade)).

## Usage

```
blackoutd on                  Black out built-in display
blackoutd off                 Restore built-in display
blackoutd status              Show daemon and display status
blackoutd auto on|off         Enable/disable auto-blackout on external connect
blackoutd verbosity <0|1|2>   Set daemon log verbosity
blackoutd recovery <none|displaysleep>
                              Set post-wake cursor-on-black auto-recovery
blackoutd diagnose            Collect a diagnostic bundle for bug reports
blackoutd daemon start        Start daemon via launchctl
blackoutd daemon stop         Stop daemon and restore built-in display
```

Run `blackoutd` with no arguments for the full list, including the
experimental `recover` and `repro` tooling used to investigate the
cursor-on-black failure (maintainer-run).

## Upgrade

For end users upgrading an existing installation:

```sh
git pull
make clean && make
make reinstall
```

Run `make reinstall` as your normal logged-in user, **not** under `sudo`
(see the note in [Install](#install) above). `make reinstall` unloads the
running agent (if any), installs the new binary and resources to
`/usr/local/`, and bootstraps the new plist for your GUI session. This is
the correct flow for upgrades — `make install` alone fails when the agent
is already loaded (`launchctl bootstrap` returns exit 5 in that case).

For development iteration without re-installing to `/usr/local/bin`:

```sh
make clean && make && make dev
```

`make dev` does not require `sudo` at all. It bootouts the running agent,
regenerates the LaunchAgent plist pointing to the freshly built binary in
`build/`, and bootstraps the new plist. The CLI binary at
`/usr/local/bin/blackoutd` is not updated by `make dev`; run `make reinstall`
to refresh it for production use.

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

Set verbosity at runtime without restarting the daemon; the value persists
and the daemon reloads it immediately:

```sh
blackoutd verbosity 2      # verbose
blackoutd verbosity 1      # back to the default
```

## How it works

blackoutd uses the private `CGSConfigureDisplayEnabled` symbol (re-exported from
SkyLight.framework through CoreGraphics) to disable the built-in display at the
compositor level. The display is fully off — not just dimmed — while the daemon
process holds a live WindowServer connection that maintains the enabled state.

On external display disconnect, the built-in is unconditionally restored
regardless of user intent. Leaving a Mac with no usable display is never
acceptable.

After a sleep/wake cycle the daemon re-applies the blackout and, when the
external wakes to a cursor-on-black state (a macOS DCP/scanout stall it
detects from a WindowServer signal), recovers it with a display-sleep cycle.
This runs at wake-settle and is controlled by the `recoveryStrategy`
preference (default `displaysleep`); disable it with `blackoutd recovery
none`. See [ADR 0010](docs/decisions/0010-cursor-on-black-detection-and-recovery.md).

## Known issues

**Username change**: The LaunchAgent plist and log path are hardcoded to the
home directory at install time. If the macOS username is changed after
installation, run `make reinstall` (as your logged-in user, not under `sudo`)
from the source directory to regenerate the plist and re-register the agent
with the correct paths.

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

### Daemon presence and PID detection

`blackoutd status` and the signal-delivery commands (`on`, `off`, `auto`)
detect whether the daemon is running via `sysctl(KERN_PROC)` process
enumeration filtered by four identity checks: `p_comm == "blackoutd"`,
effective UID matches the calling user, parent is launchd (pid 1), and
executable path matches the `ProgramArguments[0]` registered in the
LaunchAgent plist. The four checks together are authoritative — no
non-daemon process can satisfy all four.

A `bootstrap_look_up()` fast path was considered and rejected because that
call may activate an on-demand service as a side-effect (per Apple's man
page). A presence probe should not have lifecycle side-effects.

The daemon-side `bootstrap_check_in()` call at startup is retained: it
holds the Mach service receive right declared by `MachServices` in the
plist, providing the foundation for v1.0 Mach IPC (which will replace
signal-based commands with structured request/response). It is not used
by the CLI for liveness.

See [ADR 0002](docs/decisions/0002-daemon-presence-detection.md) for the
full rationale.

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

`blackoutd diagnose` collects a diagnostic bundle for bug reports into a
timestamped directory under `/tmp/blackoutd-diag-*/`: daemon state, macOS
version, per-display CoreGraphics info (vendor, model, resolution, physical
size), hardware info via system_profiler, the DCP/framebuffer and connection
state used by the cursor-on-black investigation, and log data (daemon log,
system log filtered by the blackoutd predicate, pmset sleep/wake events). The
output prints the path to this directory.

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
