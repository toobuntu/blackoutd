<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Technical Debt

Prioritized list of open issues, missing infrastructure, and planned
improvements. Each item includes a problem statement, acceptance criteria,
and pointers to files that need changes.

---

## ~~P0 — Wake auto-blackout broken~~ (FIXED)

**Problem**: After sleep/wake with the external display connected and
auto-blackout enabled, the built-in display does not re-black out. The
user must manually run `blackoutd on` or use the menu bar toggle.

**Root cause (suspected)**: The `systemDidWake:` → `invalidateDisplayState`
flow clears stale state but does not re-arm auto-blackout. When the external
re-announces via `CGDisplayReconfigurationCallback`, the display system is
still settling and the callback may be suppressed by `_actionInProgress` or
the state machine may not recognize the re-announcement as requiring action.
A deferred 2-second check exists in `AppDelegate.m` but is unreliable.

**Fix**: `systemDidWake:` now calls `[_displayController handleSystemWake]` to
arm a quiet timer. The timer resets on every `CGDisplayReconfigurationCallback`
and fires when the display pipeline has been quiet for 2 seconds. On fire it
re-applies auto-blackout if external is present and not blacked out.

**Acceptance criteria**:
- [x] After any sleep/wake with external connected and auto-blackout ON,
      built-in blacks out within 3 seconds of wake notification
- [ ] Verified: short sleep (<1 min), long sleep (>8 hr), `pmset sleepnow`,
      lid-close sleep
- [ ] Log shows `[state] ... — initiating blackout action` within 5s of wake

**Files**: `src/AppDelegate.m` (systemDidWake:), `src/DisplayController.m`
(invalidateDisplayState, handleReconfiguration:flags:)

---

## P1 — Safety invariant on restore (MITIGATED)

**Problem**: When the display compositor is in a broken state (e.g. after a
USB-C Alt Mode dropout), `disableBlackout` restores the built-in but it shows
only a cursor on a black screen — no desktop content.

**Mitigation**: A no-op CGConfig recommit (`recommitDisplayConfiguration`)
is now issued before `CGSConfigureDisplayEnabled(..., YES)` in
`setDisplay:enabled:`. This matches the displayrecommitd pattern and fixes
the confirmed repro.

**Remaining risk**: The recommit may not cover all compositor failure modes.
Monitor for new repros.

**Acceptance criteria**:
- [ ] Unplugging external with built-in blacked out always produces a usable
      built-in showing window content, not cursor-on-black
- [ ] Verified with both healthy and broken-compositor display state

**Files**: `src/DisplayController.m` (setDisplay:enabled:,
recommitDisplayConfiguration)

---

## ~~P2 — USB-C Alt Mode wake recovery~~ (FIXED)

**Problem**: With the built-in suppressed and USB-C→HDMI as the sole display
path, the USB-C controller drops Alt Mode negotiation ~30 seconds after wake.
The external display goes black; the user must unplug/replug the cable.

**Fix (from displayrecommitd)**: On `systemDidWake:`, arm a quiet timer that
resets on each `CGDisplayReconfigurationCallback`. When the timer fires (display
pipeline has settled), issue a no-op CGConfig transaction so WindowServer absorbs
the reconnected display. The quiet timer in `handleSystemWake` (see P0 fix)
handles this: when the timer fires, `recommitDisplayConfiguration` is called first,
issuing a no-op CGConfig transaction so WindowServer absorbs the reconnected
display state.

**Acceptance criteria**:
- [x] External display recovers after sleep/wake without user intervention
- [ ] No visible flicker during recovery
- [ ] Works on both battery and AC power

**Files**: `src/DisplayController.m`, `src/AppDelegate.m`

**Reference**: `displayrecommitd.m` in
[displayrecommitd](https://github.com/toobuntu/displayrecommitd/)

---

## P3 — Automated test suite

**Problem**: No automated tests exist. The `spec/` directory contains stubs
from an early Ruby-based integration test attempt that are incomplete. All
testing is manual per the checklist in AGENTS.md.

**Acceptance criteria**:
- [ ] Unit tests for display classification logic (displayIsHardwareBacked,
      vendor ID → hardware/virtual decision)
- [ ] Unit tests for state machine transitions (enable/disable blackout,
      sleep/wake, external disconnect during sleep)
- [ ] Integration tests for CLI subcommands (status output format, exit codes)
- [ ] CI runs tests on every PR

**Files**: New test directory (framework TBD — XCTest or a lightweight C test
harness), `Makefile` (test target), `.github/workflows/ci.yml`

---

## ~~P4 — Mach port IPC~~ (PARTIAL — presence detection done)

**Problem**: The CLI communicates with the daemon via Unix signals
(SIGUSR1/SIGUSR2) and detects daemon presence by parsing `launchctl list`
output. Signals are fire-and-forget (no return value), and `launchctl list`
parsing is fragile.

**Done (v0.2)**: Named Mach port registered via `MachServices` in the LaunchAgent
plist. Daemon calls `bootstrap_check_in()` at startup to hold the receive right.
CLI uses `bootstrap_look_up()` (synchronous, no subprocess) + sysctl process
enumeration to find the daemon PID for signal delivery. `launchctl list` parsing
removed.

**Remaining (v1.0)**: Replace signal-based CLI commands with Mach messages.
CLI commands should return structured status from daemon via Mach message.

**Acceptance criteria**:
- [x] Named Mach port `io.github.toobuntu.blackoutd` registered at daemon
      startup
- [x] `daemonPid()` replaced with `bootstrap_look_up()` — synchronous, no
      subprocess
- [ ] CLI commands return structured status from daemon via Mach message
- [x] `launchctl list` parsing removed

**Files**: `src/main.m`, `src/AppDelegate.m`, `blackoutd.plist.template`

---

## ~~P5 — Version infrastructure~~ (PARTIAL — version sourced and --version flag added)

**Problem**: `CFBundleShortVersionString` in Info.plist is `0.1.0` and
`CFBundleVersion` is `1`. No `make release` target, no git tag convention,
no version bumping workflow.

**Done (v0.2)**: `CFBundleShortVersionString` bumped to `0.2.0`. `blackoutd --version`
prints the version string sourced from the embedded Info.plist. `make release`
target added for tagging and building releases.

**Git tag convention**: Tags follow semantic versioning with a `v` prefix:
`v<MAJOR>.<MINOR>.<PATCH>` (e.g., `v0.2.0`, `v1.0.0`).

**Version bumping workflow**:
1. Update `CFBundleShortVersionString` in `src/Info.plist` (e.g., `0.3.0`)
2. Update `CFBundleVersion` (increment by 1)
3. Commit the version change: `git commit -m "chore: bump version to 0.3.0"`
4. Run `make release` to create the tag and build
5. Push the tag: `git push origin v<VERSION>`

**Remaining**: Git tag convention and version bumping workflow are now documented
above. The `make release` target creates annotated tags and ensures a clean
working tree.

**Acceptance criteria**:
- [x] Version sourced from a single location (Info.plist or Makefile variable)
- [x] `make release` target that tags, builds, and codesigns
- [x] `blackoutd --version` prints the version string

**Files**: `src/Info.plist`, `Makefile`, `src/main.m`

---

## ~~P6 — HANDOFF.md consolidation~~ (DONE)

Unique content migrated to CLAUDE.md (BetterDisplay research, development
hardware, displayprobe2.m reference). HANDOFF.md removed.

---

## P7 — CI hardening

**Problem**: Some CI gaps remain.

- `clang-tidy` job gracefully skips if the tool is not found, but should
  hard-fail once the macos-latest runner reliably provides it.
- ~~No invisible Unicode character check in pre-commit (supply chain attack
  mitigation).~~ **DONE**: Added to `.githooks/pre-commit` and CI `lint-unicode`
  job.
- `spec/manual/TESTING.md` referenced but may be stale.

**Acceptance criteria**:
- [ ] clang-tidy job is required (not soft-skip) once runner availability
      is confirmed
- [x] Pre-commit checks for invisible Unicode in staged files
- [ ] Stale spec/ files cleaned up or completed

**Files**: `.github/workflows/ci.yml`, `.githooks/pre-commit`, `spec/`

---

## P8 — Light modes (future)

**Problem**: Ring light and panel light modes are designed
(`docs/light-modes-design.md`) but not implemented. These repurpose the
built-in display as a supplemental light source during blackout.

**Acceptance criteria**:
- [ ] Ring light mode renders a centered annulus on the built-in
- [ ] Panel light mode fills the built-in with a solid color
- [ ] Light modes respect the safety invariant (external disconnect restores
      built-in to normal)
- [ ] Settings (size, color, mode) persisted in NSUserDefaults
- [ ] Menu bar integration per design spec

**Files**: New `src/LightModeController.h/.m`, `src/AppDelegate.m`,
`src/DisplayController.m`, `docs/light-modes-design.md`

---

## P9 — SMAppService migration (future)

**Problem**: If blackoutd is ever packaged as `Blackout.app`, the
`launchctl bootstrap/bootout` subprocess calls should be replaced with
`[SMAppService mainAppService]` register/unregister. This requires the plist
to live inside the app bundle.

**Acceptance criteria**:
- [ ] LaunchAgent managed via SMAppService API
- [ ] No `launchctl` subprocess calls
- [ ] Binary runs from inside `Blackout.app` bundle

**Files**: `src/main.m`, `Makefile`, `blackoutd.plist.template`
