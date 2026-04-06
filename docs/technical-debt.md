<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Technical Debt

Prioritized list of open issues, missing infrastructure, and planned
improvements. Each item includes a problem statement, acceptance criteria,
and pointers to files that need changes.

---

## P0 — Wake auto-blackout broken

**Problem**: After sleep/wake with the external display connected and
auto-blackout enabled, the built-in display does not re-black out. The
user must manually run `blackoutd on` or use the menu bar toggle.

**Root cause (suspected)**: The `systemDidWake:` → `invalidateDisplayState`
flow clears stale state but does not re-arm auto-blackout. When the external
re-announces via `CGDisplayReconfigurationCallback`, the display system is
still settling and the callback may be suppressed by `_actionInProgress` or
the state machine may not recognize the re-announcement as requiring action.
A deferred 2-second check exists in `AppDelegate.m` but is unreliable.

**Acceptance criteria**:
- [ ] After any sleep/wake with external connected and auto-blackout ON,
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

## P2 — USB-C Alt Mode wake recovery

**Problem**: With the built-in suppressed and USB-C→HDMI as the sole display
path, the USB-C controller drops Alt Mode negotiation ~30 seconds after wake.
The external display goes black; the user must unplug/replug the cable.

**Fix (from displayrecommitd)**: On `systemDidWake:`, arm a quiet timer that
resets on each `CGDisplayReconfigurationCallback`. When the timer fires (display
pipeline has settled), issue a no-op CGConfig transaction so WindowServer absorbs
the reconnected display. Partially implemented via the deferred wake check in
`AppDelegate.m`; the remaining work is a proper quiet-timer in
`DisplayController` for more reliable timing.

**Acceptance criteria**:
- [ ] External display recovers after sleep/wake without user intervention
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

## P4 — Mach port IPC

**Problem**: The CLI communicates with the daemon via Unix signals
(SIGUSR1/SIGUSR2) and detects daemon presence by parsing `launchctl list`
output. Signals are fire-and-forget (no return value), and `launchctl list`
parsing is fragile.

**Acceptance criteria**:
- [ ] Named Mach port `io.github.toobuntu.blackoutd` registered at daemon
      startup
- [ ] `daemonPid()` replaced with `bootstrap_look_up()` — synchronous, no
      subprocess
- [ ] CLI commands return structured status from daemon via Mach message
- [ ] `launchctl list` parsing removed

**Files**: `src/main.m`, `src/AppDelegate.m`

---

## P5 — Version infrastructure

**Problem**: `CFBundleShortVersionString` in Info.plist is `0.1.0` and
`CFBundleVersion` is `1`. No `make release` target, no git tag convention,
no version bumping workflow.

**Acceptance criteria**:
- [ ] Version sourced from a single location (Info.plist or Makefile variable)
- [ ] `make release` target that tags, builds, and codesigns
- [ ] `blackoutd --version` prints the version string

**Files**: `src/Info.plist`, `Makefile`, `src/main.m`

---

## P6 — HANDOFF.md consolidation

**Problem**: HANDOFF.md is a large (~22 KB) prompt document from early
development that partially overlaps with CLAUDE.md, AGENTS.md, and now
docs/architecture.md and docs/technical-debt.md. Information is duplicated
and risks diverging.

**Acceptance criteria**:
- [ ] All unique technical content from HANDOFF.md migrated to the
      appropriate doc (architecture.md, technical-debt.md, CLAUDE.md)
- [ ] HANDOFF.md removed or reduced to a pointer file
- [ ] No duplicate bug descriptions across docs

**Files**: `HANDOFF.md`, `CLAUDE.md`, `docs/architecture.md`,
`docs/technical-debt.md`

---

## P7 — CI hardening

**Problem**: Some CI gaps remain.

- `clang-tidy` job gracefully skips if the tool is not found, but should
  hard-fail once the macos-latest runner reliably provides it.
- No invisible Unicode character check in pre-commit (supply chain attack
  mitigation).
- `spec/manual/TESTING.md` referenced but may be stale.

**Acceptance criteria**:
- [ ] clang-tidy job is required (not soft-skip) once runner availability
      is confirmed
- [ ] Pre-commit checks for invisible Unicode in staged files
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
