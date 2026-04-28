<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Technical Debt

Prioritized list of open issues, missing infrastructure, and planned
improvements. Each item includes a problem statement, acceptance criteria,
and pointers to files that need changes.

**Next up after v0.2 ships**: P4 (Mach IPC, finish v1.0 portion) — see below.

---

## ~~P0 — Wake auto-blackout broken~~ (FIXED in v0.2)

**Problem**: After sleep/wake with the external display connected and
auto-blackout enabled, the built-in display did not re-black out. The
user had to manually run `blackoutd on` or use the menu bar toggle.

**Root cause**: The `systemDidWake:` → `invalidateDisplayState` flow cleared
stale state but did not re-arm auto-blackout. When the external re-announced
via `CGDisplayReconfigurationCallback`, the display system was still settling
and the callback could be suppressed by `_actionInProgress` or fail to be
recognized as requiring action.

**Fix**: `systemDidWake:` now calls `[_displayController handleSystemWake]`,
which arms a quiet timer. The timer resets on every
`CGDisplayReconfigurationCallback` and fires when the display pipeline has
been quiet for 2 seconds. On fire it issues a no-op CGConfig recommit,
re-checks the safety invariant (no-external-while-blacked-out → restore),
and re-applies auto-blackout if external is present and not blacked out.

**Acceptance criteria**:
- [x] After any sleep/wake with external connected and auto-blackout ON,
      built-in blacks out within ~3 seconds of wake notification
- [ ] Verified: short sleep (<1 min), long sleep (>8 hr), `pmset sleepnow`,
      lid-close sleep
- [ ] Log shows `[state] ... — initiating blackout action` within 5s of wake

**Files**: `src/AppDelegate.m` (systemDidWake:), `src/DisplayController.m`
(handleSystemWake, resetWakeSettleTimer, wakeSettleTimerFired,
invalidateDisplayState)

---

## P1 — Safety invariant on restore (MITIGATED)

**Problem**: When the display compositor is in a broken state (e.g. after a
USB-C Alt Mode dropout), `disableBlackout` restores the built-in but it shows
only a cursor on a black screen — no desktop content.

**Mitigation**: A no-op CGConfig recommit (`recommitDisplayConfiguration`)
is now issued before `CGSConfigureDisplayEnabled(..., YES)` in
`setDisplay:enabled:`. This matches the displayrecommitd pattern and fixes
the confirmed repro.

**Hardening (PR#8 review follow-up)**: The safety invariant in
`handleReconfiguration:` is now evaluated unconditionally — before the
connectivity-flag filter and the `_actionInProgress` guard. Restoring the
built-in when no external is present is never gated on action state. The
post-wake settle handler `wakeSettleTimerFired` also re-checks the
invariant after the recommit, closing a 2-second window where state could
diverge if an external was unplugged during sleep without the in-sleep
callback firing.

**Remaining risk**: The recommit may not cover all compositor failure modes.
Monitor for new repros.

**Acceptance criteria**:
- [ ] Unplugging external with built-in blacked out always produces a usable
      built-in showing window content, not cursor-on-black
- [ ] Verified with both healthy and broken-compositor display state

**Files**: `src/DisplayController.m` (setDisplay:enabled:,
recommitDisplayConfiguration, handleReconfiguration:, wakeSettleTimerFired)

---

## ~~P2 — USB-C Alt Mode wake recovery~~ (FIXED in v0.2)

**Problem**: With the built-in suppressed and USB-C→HDMI as the sole display
path, the USB-C controller drops Alt Mode negotiation ~30 seconds after wake.
The external display goes black; the user must unplug/replug the cable.

**Fix (from displayrecommitd)**: On `systemDidWake:`, arm a quiet timer that
resets on each `CGDisplayReconfigurationCallback`. When the timer fires
(display pipeline has settled), issue a no-op CGConfig transaction so
WindowServer absorbs the reconnected display. The quiet timer in
`handleSystemWake` (see P0 fix) handles this: when the timer fires,
`recommitDisplayConfiguration` is called first, issuing a no-op CGConfig
transaction.

**Acceptance criteria**:
- [x] External display recovers after sleep/wake without user intervention
- [ ] No visible flicker during recovery
- [ ] Works on both battery and AC power

**Files**: `src/DisplayController.m`, `src/AppDelegate.m`

**Reference**: `displayrecommitd.m` in
[displayrecommitd](https://github.com/toobuntu/displayrecommitd/)

---

## P3 — Automated test suite

**Problem**: No automated tests exist for the daemon. The `spec/` directory
contains stubs from an early Ruby-based integration test attempt that are
incomplete. All testing is manual per the checklist in AGENTS.md.

**v0.2 progress**: Shell-based RSpec tests of the pre-commit hook and CI
unicode scanner were added in `spec/integration/precommit_unicode_spec.rb`
(behavioral coverage of the supply-chain hardening; not daemon code).

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

## P4 — Mach IPC command channel (PROMOTED — next priority after v0.2)

**Problem**: The CLI sends commands to the daemon via Unix signals
(SIGUSR1=on, SIGUSR2=off, SIGHUP=reload-prefs). Signals are fire-and-forget:
the CLI cannot tell whether the daemon successfully applied the command,
cannot receive structured error info (e.g. "no external display present"),
and cannot fetch state (`status` synthesizes its answer locally rather than
asking the daemon).

**v0.2 state**:

- Named Mach service `io.github.toobuntu.blackoutd` is registered via
  `MachServices` in the LaunchAgent plist.
- Daemon calls `bootstrap_check_in()` at startup to hold the receive right.
  This is currently held but unused — it is the foundation for v1.0 Mach
  IPC.
- CLI presence detection uses `sysctl(KERN_PROC)` enumeration with four
  identity checks (`p_comm`, effective UID, parent is launchd, executable
  path matches `ProgramArguments[0]`). `bootstrap_look_up()` was considered
  and rejected because it can have lifecycle side-effects on the daemon
  (potential on-demand activation per Apple's `man bootstrap_look_up`).
- `launchctl list` parsing removed.

See [ADR 0002](decisions/0002-daemon-presence-detection.md) for the full
rationale.

**v1.0 plan**: Replace signal-based commands with Mach messages. The CLI
sends a request message (operation code + parameters) to the daemon's
service port and waits for a reply (status code + optional payload).
Specifically:

- Define a small message protocol: request types (ENABLE, DISABLE, RELOAD,
  STATUS, AUTO_ON, AUTO_OFF), reply types (success + state, failure + reason).
- Daemon adds a `mach_msg_server` loop on the service port.
- CLI replaces `kill(pid, sig)` with `mach_msg` send/receive on a
  newly-allocated reply port.
- Eliminate sysctl PID discovery — the Mach service lookup IS the channel,
  no PID needed.
- `bootstrap_look_up()` from the CLI becomes part of normal command flow
  (lifecycle side-effects are now exactly what we want: the CLI is asking
  the service to do something).

**Acceptance criteria**:
- [x] Named Mach port `io.github.toobuntu.blackoutd` registered at daemon
      startup via `bootstrap_check_in()`
- [x] CLI presence detection no longer parses `launchctl list`
- [x] CLI presence detection has no side-effects on daemon lifecycle (v0.2)
- [ ] Daemon `mach_msg_server` loop handles request messages
- [ ] CLI sends typed request, receives typed reply
- [ ] `blackoutd status` reflects authoritative daemon state, not locally
      synthesized state
- [ ] `blackoutd on` reports success/failure rather than "delivered SIGUSR1"
- [ ] sysctl-based PID discovery removed (no longer needed)
- [ ] Signal handlers removed from `AppDelegate.m`

**Files**: `src/main.m`, `src/AppDelegate.m`, new `src/BDMessage.h` for the
protocol definitions, `blackoutd.plist.template`, `docs/decisions/` (new
ADR for the message protocol).

**Why bumped**: The current v0.2 design has daemon-side
`bootstrap_check_in()` retained as future-prep. Holding the receive right
without ever messaging it is a small but real loose end. Doing the v1.0
work next ties the half-implemented foundation to its purpose.

---

## ~~P5 — Version infrastructure~~ (PARTIAL — version sourced and --version flag added)

**Problem**: `CFBundleShortVersionString` in Info.plist was `0.1.0` and
`CFBundleVersion` was `1`. No `make release` target, no git tag convention,
no version bumping workflow.

**Done (v0.2)**: `CFBundleShortVersionString` bumped to `0.2.0`.
`blackoutd --version` prints the version string sourced from the embedded
Info.plist. `make release` target added — verifies a clean working tree,
builds the binary, and creates an annotated git tag. The target does not
push the tag, sign artifacts, or produce a packaged release; those are
manual follow-up steps printed at the end.

**Git tag convention**: Tags follow semantic versioning with a `v` prefix:
`v<MAJOR>.<MINOR>.<PATCH>` (e.g., `v0.2.0`, `v1.0.0`).

**Version bumping workflow**:
1. Update `CFBundleShortVersionString` in `src/Info.plist` (e.g., `0.3.0`)
2. Update `CFBundleVersion` (increment by 1)
3. Commit the version change: `git commit -m "chore: bump version to 0.3.0"`
4. Run `make release` to build and create the tag
5. Push the tag: `git push origin v<VERSION>`

**Remaining**: Packaged distribution (.pkg installer, Homebrew formula) is
deferred to v1.0 (P9 / Homebrew).

**Acceptance criteria**:
- [x] Version sourced from a single location (Info.plist)
- [x] `make release` target that verifies clean tree, builds, and tags
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
  mitigation).~~ **DONE in v0.2**: Pre-commit hook (`.githooks/pre-commit`)
  uses RedHat's grep approach
  ([RHSB-2021-007](https://access.redhat.com/security/vulnerabilities/RHSB-2021-007))
  for portability across macOS versions that no longer ship Python by
  default. CI `lint-unicode` job is the Python-based backstop on the Ubuntu
  runner using `unicodedata.category()` Cf/Cc detection.
- `spec/manual/TESTING.md` referenced but may be stale.
- Homoglyph attacks (CVE-2021-42694) not detected — would require Unicode
  confusables tables. Tracked in ROADMAP.md as future work.
- PUA character ranges (used by Glassworm-class supply-chain attacks) not
  scanned. PUA is category Co, not Cf/Cc, so the category-based approach
  does not cover them. Tracked as a follow-up in ADR 0001.

**Acceptance criteria**:
- [ ] clang-tidy job is required (not soft-skip) once runner availability
      is confirmed
- [x] Pre-commit checks for invisible Unicode in staged files
- [x] CI checks for invisible Unicode and validates UTF-8 encoding
      (rejects UTF-16/UTF-32 per project policy)
- [ ] Stale spec/ files cleaned up or completed
- [ ] Homoglyph defense (CVE-2021-42694) — deferred to future
- [ ] PUA range scanning in CI — deferred to future

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
