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

**Fix**: `systemDidWake:` now calls `[_displayController handleSystemWake]` to
arm a quiet timer. The timer resets on every `CGDisplayReconfigurationCallback`
and fires when the display pipeline has been quiet for 2 seconds. On fire it
re-applies auto-blackout if external is present and not blacked out.

**Files changed**: `src/DisplayController.m/.h`, `src/AppDelegate.m`

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

**Fix**: The quiet timer in `handleSystemWake` (see P0 fix) also handles P2:
when the timer fires, `recommitDisplayConfiguration` is called first, issuing a
no-op CGConfig transaction so WindowServer absorbs the reconnected display state.

**Files changed**: `src/DisplayController.m/.h`

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

**Done (v0.2)**: Named Mach port registered via `MachServices` in the LaunchAgent
plist. Daemon calls `bootstrap_check_in()` at startup to hold the receive right.
CLI uses `bootstrap_look_up()` (synchronous, no subprocess) + sysctl process
enumeration to find the daemon PID for signal delivery. `launchctl list` parsing
removed.

**Remaining (v1.0)**: Replace signal-based CLI commands with Mach messages.
`launchctl list` parsing is gone; full Mach IPC is a v1.0 item.

**Files changed**: `src/main.m`, `src/AppDelegate.m`, `blackoutd.plist.template`

---

## ~~P5 — Version infrastructure~~ (PARTIAL — version sourced and --version flag added)

**Done (v0.2)**: `CFBundleShortVersionString` bumped to `0.2.0`. `blackoutd --version`
prints the version string sourced from the embedded Info.plist.

**Remaining**: `make release` target, git tag convention.

**Files changed**: `src/Info.plist`, `src/main.m`

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
