<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Technical Debt

Prioritized list of open issues, missing infrastructure, and planned
improvements. Each item includes a problem statement, acceptance criteria,
and pointers to files that need changes.

P0–P9 are the original v0.2-cycle entries (some FIXED, some still open).
P10–P19 were added during the post-PR#8 second-pass review (see commit
history for context). P20+ were added later — including P21 (shebang
exec-bit), P22 (bump tool), P23 (verbosity CLI subcommand), and P24
(sandbox helpers). New entries are append-only; do not renumber.

**Current top priority — P20 (cursor-on-black recovery gap)**: a confirmed
production bug where the external display can enter a stuck render state
that the daemon does not detect or recover from. Read P20 first. The
related err=1014 family of safety-invariant violations was diagnosed
from the 2026-04-29 logs and *partially* addressed in
`src/DisplayController.m`; see the "Hardening (2026-04-29)" subsection in
P1 — the 2026-05-19 wrong-constant defect recorded there (retry gated on
`kCGErrorCannotComplete`=1004, not the real `1014`) is now fixed in
318c69c: the retry arms on any non-`kCGErrorIllegalArgument` failure.
P20 is still open: the cursor-on-black state can occur without a sleep
cycle, so it sits outside the err=1014 fix's reach.

**Next up after P20 is resolved or quarantined**: P4 (Mach IPC, finish
v1.0 portion).

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
- [ ] Verified: short sleep (<1 min), long sleep (DarkWake observed),
      `pmset sleepnow`, lid-close sleep
- [ ] Log shows `[state] ... — initiating blackout action` within 5s of wake

**Files**: `src/AppDelegate.m` (systemDidWake:), `src/DisplayController.m`
(handleSystemWake, resetWakeSettleTimer, wakeSettleTimerFired,
invalidateDisplayState)

**Note (P10)**: The dispatch_source churn from `resetWakeSettleTimer` on
every callback is a known efficiency wart — see P10.

---

## P1 — Safety invariant on restore (MITIGATED, with 2026-04-29 hardening)

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

**Hardening (2026-04-29 — err=1014 family)**: Two confirmed incidents
on 2026-04-29 (logs in `docs/debug/blackoutd-diag-20260429-{155245,200620}/`)
showed the safety invariant violated by `CGCompleteDisplayConfiguration`
returning error `1014` and leaving daemon state desynced from reality.
Two distinct triggers, same family:

> **Defect (found 2026-05-19):** `1014` is NOT `kCGErrorCannotComplete`.
> The public `CGError` enum ends at `kCGErrorNoneAvailable` = `1011`;
> `kCGErrorCannotComplete` is `1004` (verified against `CGError.h`).
> `1014` is an internal CoreGraphics error — the `1012`–`1014` range is
> reserved for unnamed internal errors (per the historical CG error
> list), so it has no public symbol. All three captured incidents
> returned `1014`: 2026-04-29 14:42 & 17:28 (pre-fix build, establishing
> the value) and 2026-05-19 12:10 (post-fix build — the sleep-gating
> guards are present, so the retry guard was compiled in too, yet two
> bare `result=failed err=1014` lines appear with no "arming retry":
> dispositive). The guard's *intent* is sound — retry only a transient
> blocked call, not programming errors like `IllegalArgument` — and
> `kCGErrorCannotComplete` is the documented name matching that intent;
> it simply does not match the value this hardware actually returns
> (`1014`). Fix on the branch: keep the transient-only intent but match
> `1014` too — simplest is to retry on any failure that is not
> `kCGErrorIllegalArgument` (already handled as "synced"), bounded by
> `kBDMaxFailedActionRetries`. Related concurrency issue: P25.
>
> **Resolved (318c69c):** implemented as proposed — the guard now retries
> on any failure that is not `kCGErrorIllegalArgument`, bounded by
> `kBDMaxFailedActionRetries`. Verified in `applyEnable:`; observed firing
> (`err=1014 — arming retry 1/3`) in
> `docs/debug/blackoutd-diag-20260525-150108`.

- **14:42 incident**: the wake-settle timer fired during a wake → back-to-sleep
  sequence; `wakeSettleTimerFired` issued CG calls that blocked through
  3 minutes of sleep and returned err=1014 on next wake. Built-in
  remained `_isBlackedOut=YES` with no recovery path.
- **17:28 incident**: the +2s settle handler in `applyEnable:` fired
  while `_systemSleeping=YES`, triggered the "missed during action
  window" restore, and got err=1014. Externals stuck in mirror mode
  until next display change.

The fix has three parts, all in `src/DisplayController.m`:

1. `wakeSettleTimerFired` early-returns if `_systemSleeping=YES`. Defers
   the work to the next post-wake settle cycle.
2. `applyEnable:`'s `dispatch_after` settle handler clears
   `_actionInProgress` regardless but skips the post-action invariant
   check when sleeping.
3. On any failure other than `kCGErrorIllegalArgument` from
   `setDisplay:enabled:` (notably the internal `1014`; the original
   `kCGErrorCannotComplete` guard was the wrong-constant defect, fixed in
   318c69c), `applyEnable:` arms the wake-settle timer to drive a retry
   through the existing pipeline. Bounded by `_failedActionRetries`
   (file-static const `kBDMaxFailedActionRetries=3`); reset on success and
   on `invalidateDisplayState` (called from `systemDidWake:`).

**Remaining risk**: The recommit may not cover all compositor failure modes.
Monitor for new repros. **Update**: a separate failure mode is tracked
under P20 — the cursor-on-black state is reachable without an unplug
event, so neither the restore-path recommit nor the wake-settle recommit
fires. The 2026-04-29 fix narrows the daemon's exposure to err=1014 but
does not address P20's recovery gap.

**Acceptance criteria**:
- [ ] Unplugging external with built-in blacked out always produces a usable
      built-in showing window content, not cursor-on-black
- [ ] Verified with both healthy and broken-compositor display state
- [x] `wakeSettleTimerFired` and `applyEnable:` settle handler both
      respect `_systemSleeping` (no CG calls during sleep)
- [x] err=1014 from `setDisplay:enabled:` triggers retry via wake-settle
      with bounded retry count — **fixed in 318c69c: the guard now retries
      on any non-`kCGErrorIllegalArgument` failure (observed firing in
      `-150108`). The nested-CG-transaction hazard remains under P25.**
- [ ] Verified: sleep-during-settle scenarios reproduce in dev and the
      new daemon log shows `[wake] — settle timer fired but system is
      sleeping; deferring` (and absence of err=1014). Send daemon log
      back if anomalies.

**Files**: `src/DisplayController.m` (setDisplay:enabled:,
recommitDisplayConfiguration, handleReconfiguration:, wakeSettleTimerFired,
applyEnable:, invalidateDisplayState)

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
- [ ] Each "verified" checkbox in this file backed by a test in `spec/` or
      a dated entry in `spec/manual/TESTING.md` (P19)

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

The sysctl PID lookup is O(processes) per CLI invocation, fine for current
interactive use but wasteful if a script polls `blackoutd status`. Mach IPC
removes the need for sysctl PID discovery entirely (the service lookup IS
the channel, no PID needed), so this concern is folded into v1.0 rather
than addressed separately.

See [ADR 0002](decisions/0002-daemon-presence-detection.md) for the full
rationale.

**v1.0 plan**: Replace signal-based commands with Mach messages. The CLI
sends a request message (operation code + parameters) to the daemon's
service port and waits for a reply (status code + optional payload).
Specifically:

- Define a small message protocol: request types (ENABLE, DISABLE, RELOAD,
  STATUS, AUTO_ON, AUTO_OFF, VERBOSITY), reply types (success + state,
  failure + reason).
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
- [ ] P23 (verbosity subcommand) currently dispatches via SIGHUP +
      NSUserDefaults; migrate it to the Mach IPC VERBOSITY message and
      verify identical behavior.

**Files**: `src/main.m`, `src/AppDelegate.m`, new `src/BDMessage.h` for the
protocol definitions, `blackoutd.plist.template`, `docs/decisions/` (new
ADR for the message protocol).

**Why bumped**: The current v0.2 design has daemon-side
`bootstrap_check_in()` retained as future-prep. Holding the receive right
without ever messaging it is a small but real loose end. Doing the v1.0
work next ties the half-implemented foundation to its purpose.

---

## ~~P5 — Version infrastructure~~ (PARTIAL — version sourced, --version flag, bump tool added)

**Problem**: `CFBundleShortVersionString` in Info.plist was `0.1.0` and
`CFBundleVersion` was `1`. No `make release` target, no git tag convention,
no version bumping workflow.

**Done (v0.2)**: `CFBundleShortVersionString` bumped to `0.2.0`.
`blackoutd --version` prints the version string sourced from the embedded
Info.plist. `make release` target added — verifies a clean working tree,
builds the binary, and creates an annotated git tag. The target does not
push the tag, sign artifacts, or produce a packaged release; those are
manual follow-up steps printed at the end.

**Done (post-v0.2)**: `scripts/bump.sh patch|minor|major` reads
`CFBundleShortVersionString` from `src/Info.plist` via PlistBuddy,
computes the next version, bumps both `CFBundleShortVersionString` and
`CFBundleVersion`, and creates a `chore: bump version to X.Y.Z` commit.
`scripts/bump.sh undo` reverses the most recent bump commit (verifying
it touches only Info.plist) and deletes the matching local tag if it
points at HEAD. `scripts/bump.sh show` prints the current version. See
P22 for the closed-out spec.

**Git tag convention**: Tags follow semantic versioning with a `v` prefix:
`v<MAJOR>.<MINOR>.<PATCH>` (e.g., `v0.2.0`, `v1.0.0`).

**Version bumping workflow**:

```sh
scripts/bump.sh minor                       # 0.2.0 -> 0.3.0; commits
make release                                # tags v0.3.0; builds
git push origin HEAD --follow-tags          # pushes branch + tag
```

To undo a bump that has not yet been pushed:

```sh
scripts/bump.sh undo                        # reverts commit + deletes local tag
```

**Rollback (after `make release` has tagged)**: `make release` has no
automatic teardown. The flow is preflight (refuses dirty tree or
pre-existing tag) → build (failure prevents tag creation) → `git tag -a`
(atomic). If you discover after tagging that the release was wrong
(signing didn't take, version bump was wrong), clean up manually:

```sh
git tag -d v<VERSION>
# (do not push the deletion; the tag has not been pushed yet)
```

If the tag has already been pushed, deleting from the remote is a more
deliberate action and is not part of routine release practice. See P17
for hardening proposals.

**Remaining**: Packaged distribution (.pkg installer, Homebrew formula) is
deferred to v1.0 (P9 / Homebrew).

**Acceptance criteria**:
- [x] Version sourced from a single location (Info.plist)
- [x] `make release` target that verifies clean tree, builds, and tags
- [x] `blackoutd --version` prints the version string
- [x] Bump helper per P22 (`scripts/bump.sh`)
- [ ] Hardening per P17 (semver validation, release-undo target, dry-run)

**Files**: `src/Info.plist`, `Makefile`, `src/main.m`, `scripts/bump.sh`

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
- ~~No REUSE 3.0 license-header check in CI.~~ **DONE in scaffolding PR**:
  `lint-reuse` job runs `fsfe/reuse-action` on every PR.
- ~~Files in `scripts/` that begin with a `#!` shebang must be mode 0755,
  but no automated check enforces it.~~ **DONE (post-v0.2)**: `lint-perms`
  job and pre-commit stanza enforce mode `100755` on `scripts/*.sh` and
  `.githooks/*` files. See P21.
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
- [x] CI checks REUSE 3.0 compliance (`lint-reuse` job)
- [x] CI / pre-commit checks shipped-script executable bit (`lint-perms`)
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

**Note**: P12 (file factoring) should land *before* P8. Adding light-mode
code to today's already-crowded `DisplayController.m` would compound the
problem rather than create it.

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

---

## P10 — `_actionInProgress` is heuristic, not a barrier

**Problem**: `applyEnable:` sets `_actionInProgress = YES` and clears it
after a fixed 2-second `dispatch_after`. Real disconnect events arriving
inside that window are filtered by the safety-invariant short-circuit
(P1 fix), but the rest of `handleReconfiguration:`'s logic — including
auto-blackout decisions on external **connect** events — is suppressed.

If an external is unplugged and replugged quickly (under 2 s), the connect
event may be missed entirely. No user has reported this; the pattern is
uncommon. The design is brittle.

A secondary efficiency note: the wake-settle timer is rebuilt
(`dispatch_source_t` create + cancel) on every callback during a wake
storm. macOS pipeline churn at wake routinely produces 30+ callbacks; we
allocate and destroy 30+ dispatch sources per wake. Functionally correct
but wasteful — replace with `dispatch_source_set_timer` to reset the fire
date on a single source.

**Acceptance criteria**:
- [ ] `_actionInProgress` replaced with a signaling mechanism that
      distinguishes "echo of our own action" from "new external event"
      (e.g., a short queue of pending operation tokens, or per-display
      sequence numbers).
- [ ] Verified: rapid plug/unplug cycles (<2 s) do not desync state.
- [ ] Single `dispatch_source_t` reused across resets within a wake cycle
      (efficiency cleanup).

**Files**: `src/DisplayController.m`

---

## P11 — Sleep-time disconnect detection is a single ivar

**Problem**: `_externalDisconnectedDuringSleep` is a sticky boolean. If
two displays are connected at sleep and one is unplugged during sleep,
the daemon cannot tell which. Single-display setups (the only configuration
the maintainer currently uses) are unaffected, but the daemon does not
encode that limitation.

**Acceptance criteria**: pick one and document it.
- Either: declare single-external-display as the supported configuration
  in `docs/architecture.md` and add a clarifying comment in
  `DisplayController.m`.
- Or: replace the ivar with a per-`CGDirectDisplayID` set of
  disconnected-during-sleep IDs, evaluated at wake.

**Files**: `src/DisplayController.m`, `docs/architecture.md`

---

## P12 — File factoring: AppDelegate / DisplayController / MenuBar

**Problem**: `AppDelegate` and `DisplayController` share too many
responsibilities. `AppDelegate` owns signals, sleep/wake observers,
NSUserDefaults, the menu bar, WindowServer-readiness wait, and the Mach
port hold. `DisplayController` owns the display state machine, callback
handling, verbosity, recommit transactions, and the wake-settle timer.

Sleep/wake state is split across both: `AppDelegate` calls
`displayController.systemSleeping = YES` and `invalidateDisplayState`,
but `DisplayController` owns the wake-settle timer triggered by
`AppDelegate`'s wake handler. This works but is not a clean separation.

A cleaner factoring:

- `DaemonLifecycle` — signals, launchd, Mach port, prefs.
- `DisplayController` — everything display-related, including its own
  sleep/wake observers.
- `MenuBar` — UI presentation only, no business logic.

**Acceptance criteria**:
- [ ] Sleep/wake observers move into `DisplayController`.
- [ ] `AppDelegate` becomes a thin orchestrator (or splits into
      `DaemonLifecycle` + a residual delegate).
- [ ] No regression in functional tests (manual checklist in AGENTS.md).

**Why before P8**: Light modes will land in display code; pre-existing
crowding makes the change harder. Refactor first.

**Files**: `src/AppDelegate.m`, `src/DisplayController.m`,
`src/MenuBar.h/.m` (new), possibly `src/DaemonLifecycle.h/.m` (new).

---

## P13 — Stringly-typed NSUserDefaults keys

**Problem**: `@"autoBlackoutOnExternalConnect"` appears in 3 files.
`@"blackoutActive"` appears in 2. `@"verbosityLevel"` appears in 2. All
are spelled correctly today; all will not be tomorrow.

**Acceptance criteria**:
- [ ] New header `src/Preferences.h` (or similar) declares each key as
      `extern NSString *const kBDPrefAutoBlackout`, etc.
- [ ] All readers and writers reference the constant.
- [ ] No string literal of a defaults key remains in `.m` files.

**Files**: `src/AppDelegate.m`, `src/main.m`, new `src/Preferences.h`,
new `src/Preferences.m` (for the const definitions).

---

## P14 — User-disabled vs system-disabled blackout — needs ADR

**Problem**: `kBlackoutActiveKey` is set when blackout is enabled and
cleared when disabled. "Disabled because the user clicked the menu item"
and "disabled because the external was unplugged during sleep" are stored
identically. On re-plug after a sleep-disconnect cycle, only the
auto-blackout setting determines whether to re-blackout — the user's prior
intent is lost.

This may be the right design (auto-blackout means auto-blackout) or it may
be a bug (user explicitly turned blackout off, but plugging in again turns
it back on). Worth deciding deliberately.

**Acceptance criteria**:
- [ ] New ADR documenting the chosen behavior and rationale.
- [ ] Implementation matches the ADR.
- [ ] Logging makes the distinction visible (e.g., `[state] blackout
      disabled — user-initiated` vs `[state] blackout disabled —
      external-disconnected`).

**Files**: `docs/decisions/0005-*.md` (new ADR), `src/AppDelegate.m`,
`src/DisplayController.m`.

---

## P15 — `runLaunchctl` / `runShellToFile` / `runToFile` / `runAndPrint` consolidation

**Problem**: `src/main.m` has four NSTask wrappers with subtle differences:

- `runLaunchctl(args)` — runs `/bin/launchctl` with args, returns exit code.
- `runShellToFile(file, cmd)` — runs `/bin/sh -c`, captures stdout to a
  file.
- `runToFile(file, path, args)` — generic, captures stdout to a file.
- `runAndPrint(path, args)` — runs, prints to our stdout.

These can collapse to one or two helpers. ~30 lines of duplicate plumbing
removed.

**Acceptance criteria**:
- [ ] Single `runProcess(path, args, output)` where `output` is one of
      `stdout` / file-path / `discard`.
- [ ] All call sites updated.
- [ ] No behavior change.

**Files**: `src/main.m`.

---

## P16 — Verify `reuse annotate` behavior with YAML frontmatter

**Problem**: Markdown files with YAML frontmatter (ADRs in
`docs/decisions/`, Claude Code skills in `.claude/skills/<name>/SKILL.md`)
follow two different SPDX-placement conventions:

- ADRs: SPDX inside frontmatter, prefixed with `#` (YAML comments).
- Skills: SPDX in an HTML comment block AFTER the closing `---`.

The on-disk files were created or normalized by hand. It is not currently
verified that running `scripts/annotate.sh` (which calls
`reuse annotate --style=html`) on a fresh frontmatter-bearing file produces
the right placement for either convention.

Update: `scripts/annotate.sh` placed the SPDX inside the ADR frontmatter,
prefixed with `#` (YAML comments). This means the Claude skills will
presumably need to be handled as a special case. Manual verification might
still be necessary.

**Acceptance criteria**:
- [ ] Construct minimal repros: `tmp-skill.md` (skill-style frontmatter)
      and `tmp-adr.md` (ADR-style frontmatter), each with no SPDX.
- [ ] Run `reuse annotate --style=html --copyright="Test" --license=MIT`
      on each, capture stdout/diff.
- [ ] If output matches the documented convention: confirm in
      `CONTRIBUTING.md` and add a regression test in `spec/`.
- [ ] If output diverges: either (a) update `scripts/annotate.sh` to
      produce the right placement (e.g., teach it to insert the SPDX block
      after frontmatter for skill files), or (b) update `CONTRIBUTING.md`
      to admit that one or both conventions are hand-maintained, with a
      note advising contributors to verify post-annotate output.
- [ ] Either (c) document a `REUSE.toml`-based alternative for directory
      trees of homogeneous files (e.g., all skills covered by a single
      `[[annotations]]` entry), and decide whether to adopt it.

**Files**: `scripts/annotate.sh`, `CONTRIBUTING.md`, possibly a new
`spec/integration/annotate_frontmatter_spec.rb`, possibly `REUSE.toml`.

**Why this is a debt item, not a chat answer**: This needs an actual
shell invocation against the actual `reuse-tool` version installed in
the project. Claude Code can run that. Chat sessions cannot.

---

## P17 — `make release` hardening

**Problem**: The release flow has minor sharp edges, none of them blocking
but worth tightening before v1.0.

- No semver format validation. A typo in `CFBundleShortVersionString`
  (e.g., `0..2.0` or `0,2,0`) is passed to `git tag` unchanged and yields
  a malformed tag.
- No automatic teardown after a partial release. If the build succeeds and
  the tag is created but then signing or post-tag verification fails,
  cleanup is the manual `git tag -d v<VERSION>`.
- No dry-run mode. The first observable side effect of `make release` is a
  new git tag.
- No commit-linkage check. Nothing verifies the version bump was committed
  with the right subject prefix (`chore: bump version to ...`); the
  preflight only checks for a clean working tree.

**Acceptance criteria**:
- [ ] `preflight` validates that `$(VERSION)` matches a strict semver
      regex (`^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$`).
- [ ] New `make release-undo` target deletes the local `v<VERSION>` tag
      and prints a reminder if the tag was already pushed.
- [ ] Optional `make release-dry-run` prints the actions that would be
      taken without taking them.

**Note**: `scripts/bump.sh` (P22) also validates semver during bump; the
duplicate validation in `make release` is defense in depth in case
someone hand-edits Info.plist.

**Files**: `Makefile`, possibly a `scripts/release.sh` if the logic
outgrows Makefile recipes.

---

## P18 — `find_unicode_control2--*/` reference material in source tree

**Problem**: `scripts/find_unicode_control2--2021-11-01-1136/` is the
RedHat diagnostic Python script referenced from ADR 0001. It is not used
by the project. It is in the working tree because the maintainer
downloaded it during the design phase.

The directory is gitignored (per `_user-claude-config/` and similar
patterns in `.gitignore`) — verify this is the case post-PR-merge.

**Acceptance criteria**: pick one.
- Move to `docs/decisions/0001-references/` with a README and commit it
  as historical reference.
- Or remove from the working tree entirely (the ADR links to the
  authoritative Red Hat URL).
- Or keep as gitignored working-copy reference and add a note in the ADR
  that it's locally available but not tracked.

**Files**: `scripts/find_unicode_control2--2021-11-01-1136/`,
`docs/decisions/0001-trojan-source-detection-strategy.md`, `.gitignore`.

---

## P19 — Verified-checkbox provenance

**Problem**: This file's "Acceptance criteria" sections include checkboxes
labeled "Verified: ..." with no associated test or dated manual record.
After v0.2 ships, several of these are claimed as done but the verification
is in the maintainer's head.

**Acceptance criteria**:
- [ ] Each "Verified: ..." checkbox in this file is backed by either:
  - a test file under `spec/` (preferred — automatically re-verified by
    CI), or
  - a dated entry in `spec/manual/TESTING.md` recording which build was
    tested, against which hardware, on which date.
- [ ] `spec/manual/TESTING.md` exists or is removed (currently
      referenced but its presence and freshness are uncertain).
- [ ] As part of v0.3 work, ADRs 0002 and 0003 are re-read against the
      shipped code and any drift is corrected (one-time check; not a
      recurring criterion).

**Files**: `docs/technical-debt.md`, `spec/manual/TESTING.md`,
`docs/decisions/0002-*.md`, `docs/decisions/0003-*.md`.

---

## P20 — External-display "cursor on black" failure mode (TOP PRIORITY — needs reproduction with logs)

**Problem**: Two confirmed occurrences of a state where the external
display shows only a cursor on a black screen, with no window content
rendering. The maintainer reports:

- **Repro 1**: built-in remained blacked out, external black with cursor.
  Hot-corner display sleep did NOT recover the external. Required physical
  unplug of both data and power cable to recover.
- **Repro 2**: built-in was restored (safety invariant fired), external
  still black with cursor. Hot-corner display sleep DID recover the
  external.

Maintainer's hypothesis: `recommitDisplayConfiguration` was not firing
when it should have.

**2026-04-29 update**: Logs from these two incidents
(`docs/debug/blackoutd-diag-20260429-{155245,200620}/`) revealed an
adjacent failure mode: `CGCompleteDisplayConfiguration` was being
called while the system was sleeping, blocking for minutes and
eventually returning error `1014` (an undocumented code — NOT
`kCGErrorCannotComplete`, which is `1004`; see the P1 defect note). The
sleep-gating parts of the P1 hardening address that family; the
err=1014 *retry* path — initially a no-op (wrong-constant guard) — now
fires as of 318c69c (see P1 and P25). However, the
underlying P20 failure mode — cursor-on-black without a sleep cycle —
was not the root cause of those incidents and is still open.

**2026-05-21 update (corroborating evidence from the SP2309W work)**: the
`inject_edid` investigation produced direct evidence bearing on this gap, though
not a captured repro of P20 itself.

- The no-op CG recommit (`recommitDisplayConfiguration`) is confirmed to reach
  the DCP and force a real reconfiguration, not merely nudge daemon state: in
  the SP2309W work, inject + recommit renegotiates the link end to end (the
  negotiated connection mode flips, measured via BetterDisplay's
  `get -connectionMode`). That supports hypothesis C (a recommit-style nudge
  forces the pipeline to re-attach) and the recommit-based recovery candidates.
- The renegotiation is **not instant** — it lands a few seconds after the
  recommit. Any recovery path must let the link settle before judging success;
  an immediate check sees the stale (broken) state.
- Correction to an earlier draft of this note: a display-sleep cycle does **not**
  reproduce cursor-on-black — it *clears* it. The maintainer encounters
  cursor-on-black only on wake from *system* sleep; a manual display-sleep cycle
  (hot corner) forces a fresh renegotiation that recovers the external
  (consistent with Repro 2). So the open puzzle is not a missing recommit but why
  blackoutd's existing *system-wake* recommit does not already clear it. The
  latency and re-attach-race findings make mistiming plausible — the wake-settle
  recommit may fire before the external has finished re-attaching, nudging a
  half-attached pipeline — which points back at wake-settle timing and the
  err=1014 retry gap (P1/P25) rather than at adding a display-wake subscription.

Still open: none of this was captured as a `verbosityLevel=2` diag bundle during
a genuine occurrence (the data below is still what's needed). Add one item to
that list — capture the connection mode (BetterDisplay `get -connectionMode`, or
a native reader once it exists) *during* the broken state, to distinguish "stuck
in a bad mode" from "no active mode".

**2026-07-19 update — capture gate met; first surviving detector
candidate.** Cohort 2 (matrix runs 011+) delivered the required ≥3
black / ≥3 clean settled `verbosityLevel=2` captures during genuine
occurrences, satisfying the "Diagnostic data needed" list below via the
`repro` workflow. The field diff found the first black/clean splitter
to survive n ≥ 3: a WindowServer hotplug-coalescing log marker, 10/10
black wakes vs 0/15 clean across both cohorts, supporting hypothesis A
(link drop during sleep, coalesced on wake). Full diff record,
mechanism reading, caveats, and next steps under P29 (2026-07-19
update). **2026-07-20**: the marker stands at 56/56 vs 0/33 across
runs 1–104, and the detector-gated displaysleep auto-recovery is
implemented in the daemon (`recoveryStrategy` pref, `blackoutd
recovery` subcommand) — the acceptance-criteria recovery path for
hypothesis A/C is landed; see P29 (2026-07-20 update).

**Architecture analysis confirming the gap**:

`recommitDisplayConfiguration` fires from exactly two paths today
(verified by reading `src/DisplayController.m`):

1. `setDisplay:enabled:YES` — when the built-in is being restored. Does
   NOT fire when blackout stays enabled.
2. `wakeSettleTimerFired` — only after `NSWorkspaceDidWakeNotification`
   (system sleep/wake). Does NOT fire on display-sleep events
   (hot-corner, `NSWorkspaceScreensDidSleepNotification`) and does NOT
   fire on Alt Mode dropout that occurs without a sleep cycle.

If the external enters the broken state without a system sleep/wake,
no recommit is issued. Repro 1 fits this pattern: built-in stayed
blacked out (no restore-path recommit), and no system wake occurred
(no settle-timer recommit).

The strict safety invariant in `handleReconfiguration:` only fires when
`hasActiveExternalDisplay` returns `NO`. A display in the cursor-on-black
state is still "active" from CoreGraphics' perspective: it has a
`CGDirectDisplayID`, it's enabled, it has a real vendor ID. So the
invariant does not trigger. **This is a real recovery gap, not a
violation of the existing invariant.**

**Hypotheses (untested)**:

- **A — Alt Mode dropout without system sleep**: USB-C controller drops
  Alt Mode under load, thermal events, or power-profile transitions.
  No `CGDisplayReconfigurationCallback` is fired (the display is still
  "connected" from macOS's view), so no recommit is issued.
- **B — DCP driver state divergence**: `dcpext` enters an internal bad
  state. CoreGraphics doesn't know to invalidate the display. The
  hardware still emits a valid-looking signal but the rendering
  pipeline is stuck.
- **C — Compositor lost reference to the external surface**: After some
  internal CG event we don't observe, the compositor stops rendering
  to the external. A no-op CGConfig recommit forces re-attach.

Hypotheses A and C both predict that a periodic or display-sleep-triggered
recommit would resolve the issue. Hypothesis B may not be solvable from
user-space and may match Repro 1 specifically (physical reconnect required).

**Diagnostic data needed**:

The 2026-04-29 logs surfaced the err=1014 family but the underlying
cursor-on-black state without a sleep cycle is not yet reproduced
with logs at hand. Required to make further progress:

- [ ] Full contents of `/tmp/blackoutd-diag-*/` from a future
      cursor-on-black occurrence, captured at `verbosityLevel=2`.
- [ ] `pmset -g log` output spanning ~1 hour before and after the
      occurrence (looking for sleep, DarkWake, wake events; power-source
      transitions; lid close/open).
- [ ] `system_profiler SPDisplaysDataType -detailLevel mini` captured
      DURING the broken state (not after recovery).
- [ ] `ioreg -lw0 -r -c IODisplayConnect` and
      `ioreg -lw0 -p IOService -n dcpext` captured during the broken
      state.
- [ ] Power state during the incident: battery, AC, or transitioning?
- [ ] Lid state during the incident: open, closed, or transitioning?
- [ ] User actions immediately before the incident: closing apps,
      changing displays in System Settings, plugging in a USB device?
- [ ] Was the daemon process still alive? Verify with
      `launchctl list io.github.toobuntu.blackoutd` and
      `pgrep -fa blackoutd`.

**Acceptance criteria**:

- [ ] Logs from at least one new repro analyzed; root cause identified or
      bracketed to one of hypotheses A, B, or C.
- [ ] If hypothesis A or C is confirmed: implement a recovery path that
      issues `recommitDisplayConfiguration` in response to the trigger.
      Candidates (pick one or compose):
  - Subscribe to `NSWorkspaceScreensDidWakeNotification` (display wake
    from hot corner / display sleep) in addition to
    `NSWorkspaceDidWakeNotification`. Trigger the same wake-settle path.
  - New CLI command `blackoutd recommit` for manual recovery. Invokes
    `recommitDisplayConfiguration` via signal or (post-P4) Mach IPC.
  - Periodic low-frequency recommit while blackout is enabled
    (e.g., every 5 minutes; only fires if external is present).
- [ ] If hypothesis B is confirmed: document the external-hardware
      limitation in README "Known issues" and mark as a hardware-class
      bug not fixable from user-space.
- [ ] Manual repro test added to `spec/manual/TESTING.md` so future
      regressions are caught.
- [ ] If a code fix is implemented: regression test in `spec/` if
      possible, otherwise a dated entry in `spec/manual/TESTING.md`.

**Files**: `src/DisplayController.m`, `src/AppDelegate.m`, possibly
`src/main.m` (for new CLI command), `spec/manual/TESTING.md`,
README "Known issues" section.

**Workflow**: This is a hardware-dependent debugging task. The chat-side
analysis (architecture + hypotheses, above) is done. Execution requires
running diagnostic commands on the maintainer's machine during or after
a repro. Suggested sequence:

1. Maintainer collects the diagnostic data above on next occurrence with
   `verbosityLevel=2` already set (one-step via `blackoutd verbosity 2`,
   shipped in P23).
2. Maintainer either (a) shares the data files in chat, or (b) opens a
   Claude Code session with the data files staged in `/tmp/` and asks
   Claude Code to analyze them.
3. Claude Code iterates on instrumentation (additional `[verbose=2]`
   log lines in `handleReconfiguration:`) and tests fix hypotheses via
   `make dev` cycles.

---

## ~~P21 — Shebang executable-bit hygiene~~ (DONE)

**Problem**: Files in the repo that begin with a `#!` shebang must be
mode `0755` to be executable when invoked directly. Two scripts
(`scripts/annotate.sh`, `scripts/rewrite-pr-as-merge-commit.sh`) were
silently regressed to `0644` by file-write tooling that respects the
user's umask.

**Done**:

- The two affected scripts were restored to `0755` in commit `c7eec89`
  ("Mark scripts/ shebang files as executable").
- `lint-perms` job added to `.github/workflows/ci.yml`. Iterates
  `scripts/*.sh` and `.githooks/*` (excluding dotfiles like
  `.gitignore`); fails the run on any file whose git-tracked mode is
  not `100755`. Emits a `::error file=...::missing execute bit` line
  that GitHub renders inline in the PR Files-changed view, with a
  `Fix:` suggestion using `chmod 755` plus
  `git update-index --chmod=+x`.
- Pre-commit hook stanza added to `.githooks/pre-commit` (right after
  the branch-block check). Same logic against the staged file's mode
  via `git ls-files --stage`. Catches the regression at commit time
  before it reaches CI.
- Branch protection ruleset updated to require `lint-perms` as a
  status check (see `docs/branch-protection.md`).

**Acceptance criteria**:

- [x] Affected scripts at mode `0755` with the bit recorded in git's
      index.
- [x] Pre-commit hook check for the staged-mode bit on
      `scripts/*.sh` and `.githooks/*`.
- [x] CI backstop in `.github/workflows/ci.yml` (`lint-perms` job).
- [x] Required status check in branch protection ruleset.
- [ ] Documentation note in `CONTRIBUTING.md`: when re-creating a script,
      verify the executable bit afterward (the `lint-perms` failure
      message is self-explanatory; add a one-liner if a contributor
      hits the issue first). Deferred to a follow-up commit if it
      becomes an actual friction point.

**Files (touched)**: `.githooks/pre-commit`, `.github/workflows/ci.yml`,
`docs/branch-protection.md`.

---

## ~~P22 — `scripts/bump.sh` for ergonomic version bumping~~ (DONE)

**Problem**: P5 documented the version-bump workflow as a 2-step manual
edit of `src/Info.plist`. Both steps were clerical and easy to get
wrong: a semver typo, a missed `CFBundleVersion` increment, an
inconsistency between the two fields.

**Tradeoffs evaluated**:

- **Use [Tim Hårek's git-bump](https://timharek.no/blog/introducing-git-bump/)
  as-is**: external dependency for a small need; it's tag-driven, but
  blackoutd's source-of-truth for the version is `Info.plist`, not
  tags. Drift would be inevitable. Rejected.
- **Add `BUMP=major|minor|patch` arg to `make release`**: conflates
  bumping with releasing. You can't bump-only without taking the build
  hit. Make recipes that wrap PlistBuddy and semver arithmetic become
  hard to read. Rejected.
- **Standalone `scripts/bump.sh`**: matches the existing pattern
  (`scripts/annotate.sh`, `scripts/rewrite-pr-as-merge-commit.sh`).
  Project-specific, small, POSIX `/bin/sh` for portability.
  **Accepted.**

**Done**: `scripts/bump.sh` ships with subcommands `patch | minor |
major | undo | show`. POSIX `/bin/sh`, `set -eu`, no GNU extensions.
The implementation deviates from the original P22 spec in two ways
worth noting:

1. **Auto-commits**: bump.sh runs `git commit --message="chore: bump
   version to X.Y.Z"` after writing Info.plist. The original spec said
   "Does NOT commit (the maintainer reviews and commits manually)";
   the deviation matches the user's git-bump-style preference for a
   single command that produces the bump commit. Review is done via
   `git show HEAD` after the fact rather than `git diff` before the
   commit. Atomic refusal: refuses to run if the working tree is dirty
   or if the current branch is `main` (caught earlier than the
   pre-commit hook would).
2. **No `--dry-run` flag**: the auto-commit means the only durable
   side effect is one new commit, which `bump.sh undo` reverses
   cleanly. A dry-run mode is therefore lower-value than originally
   thought. Can be added if a use case appears.

Validation in bump.sh: rejects pre-release suffixes (`-rc1` etc.) and
leading zeros (which would otherwise trip POSIX shell's octal arithmetic
on inputs like `08`). Updates both `CFBundleShortVersionString` and
`CFBundleVersion` (the latter incremented by 1) atomically — PlistBuddy's
in-place edit is sufficient because failures abort before commit and
`git checkout HEAD -- src/Info.plist` reverses any partial writes.

**Acceptance criteria**:

- [x] New script `scripts/bump.sh` (POSIX `/bin/sh`, `set -eu`).
- [x] Takes one positional arg: `patch | minor | major | undo | show`.
- [x] Reads current `CFBundleShortVersionString` from `src/Info.plist`
      via `/usr/libexec/PlistBuddy`.
- [x] Validates the current value against a strict semver regex; refuses
      if it doesn't parse.
- [x] Computes the new version per the bump kind.
- [x] Updates both `CFBundleShortVersionString` and increments
      `CFBundleVersion`.
- [x] Has a `--help` / `help` invocation.
- [x] Mode `0755` (per P21 — to be set by the maintainer before commit;
      the lint-perms hook will catch it if forgotten).
- [x] `undo` subcommand reverses the most recent bump commit and
      deletes the matching local tag if it points at HEAD.
- [N/A] **Deviation**: auto-commits rather than print-diff-only.
- [N/A] **Deviation**: no `--dry-run` flag.

**Workflow** (matches P5 documentation):

```sh
scripts/bump.sh minor                   # 0.2.0 -> 0.3.0; commits
make release                            # tags v0.3.0; builds
git push origin HEAD --follow-tags      # pushes branch and tag
```

If you discover the bump was wrong:

```sh
scripts/bump.sh undo                    # reverts commit + deletes local tag
```

**Files**: `scripts/bump.sh`. P5 documentation updated in this same
revision.

---

## ~~P23 — `blackoutd verbosity <level>` CLI subcommand~~ (DONE)

**Problem**: Increasing daemon verbosity was a two-step procedure
(documented in P20's workflow):

```sh
defaults write blackoutd verbosityLevel -int 2
killall -HUP blackoutd
```

Both steps are required (the daemon only reads the defaults on
startup or on SIGHUP). When debugging a transient repro, the friction
of the two-step procedure (with potential typos, daemon-not-running
ambiguity) was undesirable.

**Done**: New subcommand `blackoutd verbosity <0|1|2>` in `src/main.m`
collapses both steps into one. Implementation specifics:

- New `setVerbosity(const char *value)` static function. Validates the
  argument is a decimal numeric (rejects e.g. `verbosity high` rather
  than letting `strtol` silently produce 0), then bounds-checks 0–2.
- Writes to NSUserDefaults under suite `blackoutd`, key `verbosityLevel`,
  using `setInteger:forKey:` and `synchronize`.
- Calls `daemonPid()` (existing helper from the daemon-presence
  detection) to find the daemon. If running, sends SIGHUP, which the
  daemon's existing `_sighupSource` handler routes to
  `[AppDelegate reloadPreferences]`, which calls
  `_displayController.verbosityLevel = newValue`.
- Reads back the level it just wrote and reports it to the user (rather
  than echoing the input) so the message reflects what the daemon will
  actually see.
- Daemon-not-running case is non-error: defaults persist, value applies
  on next start.

The `status` and `--config` outputs were also extended to print the
current `verbosity` line so the maintainer can verify the value
without invoking `defaults read`.

**Tradeoff against P4 (Mach IPC) — accepted**: this subcommand uses
signal-based prefs reload, which P4 plans to replace with Mach IPC.
Adding it now ties into the deprecating mechanism. The cost is small
(~30 lines added; one call site to migrate when P4 lands). The QoL win
during P20 debugging justifies the early implementation. Tracked as a
sub-bullet under P4's acceptance criteria.

**Acceptance criteria**:

- [x] New subcommand `blackoutd verbosity <0|1|2>`.
- [x] Validates the integer level (0, 1, or 2).
- [x] Writes to NSUserDefaults under suite `blackoutd`, key
      `verbosityLevel`.
- [x] Sends SIGHUP to the daemon if it's running. If not, reports
      that the change takes effect on next start.
- [x] Subcommand listed in `blackoutd --help` (printUsage()).
- [x] `verbosity` line added to `blackoutd status` and
      `blackoutd --config` output.
- [ ] Manual test: from a terminal, `blackoutd verbosity 2`, observe
      `[prefs] verbosityLevel=2` in the daemon log; `blackoutd
      verbosity 1` reverses it.

**Files (touched)**: `src/main.m`.

---

## ~~P24 — Sandbox helper scripts for fresh-clone Claude Code sessions~~ (DONE)

**Problem**: Recent incidents involving agentic AI tools deleting
production data ([Replit / PocketOS](https://mashable.com/article/ai-agent-deletes-data-30-hour-service-outage-pocketos),
[Claude database wipe](https://hothardware.com/news/claude-confesses-to-wiping-entire-database-in-seconds))
made it clear that the existing capability filtering in
`.claude/settings.json` is necessary but not sufficient for high-risk
tasks. The right second layer for non-routine work is a fresh clone
with no remote (or a repointed-to-local origin), so even if the
permission rules fail, the worst-case blast radius is limited to the
sandbox dir.

The maintainer's initial sketch:

```sh
cd sandbox/
gh repo clone <repo>
git remote --verbose > remotes.log
git remote remove $(git remote)
# ... iterate ...
git remote add < remotes.log              # invalid syntax
git push --set-upstream origin HEAD
```

did not quite work — `git remote --verbose` produces two lines per
remote (one fetch, one push), `git remote remove` only takes one name
at a time, and `git remote add < file` is not a valid invocation. A
proper helper script encapsulates the pattern.

**Done**: Two scripts, POSIX `/bin/sh`, mirror the patterns documented
in `docs/claude-code-isolation.md`:

- `scripts/sandbox-enter.sh [--mode=MODE] [--parent=DIR] <source-repo>`
  clones `<source-repo>` to `<parent>/<repo-name>-sandbox-<timestamp>`.
  Captures the source's remotes BEFORE cloning (since `git clone` of a
  local path makes origin point at the source path, not at the
  source's GitHub URL) and writes them to
  `.sandbox-remotes/saved.tsv` inside the sandbox. Modes:
  - `no-remote` (default): removes all remotes.
  - `repoint-origin`: leaves origin pointing at the source path (the
    natural result of `git clone <local>`).
  - `add-local`: restores origin to the GitHub URL and adds a `local`
    remote pointing at the source path.
- `scripts/sandbox-exit.sh [--push] [--push-target=REMOTE]`
  reads `.sandbox-remotes/saved.tsv`, removes any current remotes,
  restores from the saved file. With `--push`, fetches and pushes the
  current branch to the target remote (default `origin`).

`.gitignore` updated to ignore `.sandbox-remotes/` so an inattentive
`git add .` in the sandbox doesn't commit remote URLs into the source
tree.

**Future consolidation** (deferred — track here so it isn't forgotten):
the maintainer is considering unifying `scripts/bump.sh`,
`scripts/sandbox-enter.sh`, `scripts/sandbox-exit.sh`, and the personal
`aiwt`/`aiwt-done` shell functions into a single tool with subcommands
— either compiled (Go, Rust) or in Ruby using the `semver` gem. Pros:
single cohesive CLI, shared validation, easier discovery. Cons: build
and dependency footprint vs. the current dependency-free POSIX shell
scripts. Not in scope for the current PR; revisit when more shared
machinery accumulates.

**Acceptance criteria**:

- [x] `scripts/sandbox-enter.sh` and `scripts/sandbox-exit.sh` ship.
- [x] Three modes implemented (no-remote, repoint-origin, add-local).
- [x] Source remotes captured pre-clone (so add-local can restore the
      GitHub URL).
- [x] `.sandbox-remotes/` gitignored.
- [x] Documentation in `docs/claude-code-isolation.md` references the
      new scripts and explains when to choose each mode.
- [ ] Mode `0755` (the maintainer must `chmod 755` the new scripts
      before committing — the lint-perms pre-commit hook from P21 will
      block the commit otherwise).
- [ ] Manual test: enter a sandbox with `--mode=no-remote`, verify
      `git remote -v` is empty; run sandbox-exit.sh; verify remotes
      are restored.

**Files (added)**: `scripts/sandbox-enter.sh`, `scripts/sandbox-exit.sh`,
`.gitignore`, `docs/claude-code-isolation.md`.

---

## P25 — Safety-invariant restore re-enters `applyEnable:` and nests CG transactions

**Problem**: The unconditional safety-invariant check in
`handleReconfiguration:` (and `wakeSettleTimerFired`) calls `applyEnable:`
even when a restore is already in flight. Because
`CGCompleteDisplayConfiguration` pumps the run loop while it waits on
WindowServer, a reconfiguration callback can fire *inside* the blocked
`setDisplay:enabled:` of restore #1, re-enter `handleReconfiguration:`,
find `hasExternal=0`, and launch a nested restore #2 — a second
`CGBegin`/`CGSConfigureDisplayEnabled`/`CGComplete` transaction nested
inside the first. The current source comment ("re-entering `applyEnable:`
here is safe") is true for daemon *state* but not for nested CG
*configuration* transactions: during post-wake pipeline churn the nested
commits return `1014`.

Confirmed in `docs/debug/blackoutd-diag-20260519-214316/` (daemon log,
12:10:25–12:10:46): the restore from "external disconnected during sleep"
logged `result=pending` + recommit but never completed; the invariant
path then logged a second `result=pending` + recommit; the external
flapped back (id=46 hardware → id=2 virtual) mid-transaction; both
restores ended `result=failed err=1014` ten seconds apart, with no retry
armed (see the P1 wrong-constant defect — the two failures are two
distinct blocked CG calls, not a retry sequence).

**On the "no-op recommit is harmless" assumption**: it holds for the bare
`recommitDisplayConfiguration` transaction (an idempotent nudge). It does
NOT extend to a re-entrant `applyEnable:`, which carries a real
`CGSConfigureDisplayEnabled` mutation committed `kCGConfigurePermanently`.
Nesting *configuration* transactions is the hazard, not the recommit.

**Proposed fix** (keep detection unconditional; serialize the commit):

- Detection stays exactly as-is — the invariant must keep firing before
  the connectivity and `_actionInProgress` filters (P1 requirement).
- Before issuing a *new* CG transaction in `applyEnable:`, coalesce: if an
  action toward the same desired `_isBlackedOut` target is already in
  flight, record the intent and let the in-flight action (or the next
  settle-timer pass) converge, rather than nesting a second transaction.
- Pair with the P1 retry-guard fix: retry on any non-success that is not
  `kCGErrorIllegalArgument`, bounded by `kBDMaxFailedActionRetries`.

**Acceptance criteria**:

- [ ] No two overlapping `action=restore result=pending` lines without an
      intervening `result=complete`/`failed` in a single wake cycle.
- [ ] Re-entrant invariant detection still fires (unchanged) but does not
      launch a nested CG configuration transaction.
- [ ] err=1014 (or any non-`IllegalArgument` failure) arms the bounded
      wake-settle retry — i.e. the P1 retry path actually executes.
- [ ] Reproduced against a 12:10-style sleep → wake → external-flap
      sequence; daemon log shows the retry arming and no nested pending
      restores.

**Files**: `src/DisplayController.m` (applyEnable:, handleReconfiguration:,
wakeSettleTimerFired). Relates to P1 (retry guard) and P10
(`_actionInProgress` is heuristic).

---

## P26 — SP2309W RGB / EDID color correction (scope decision pending)

**Problem**: The Dell SP2309W's CTA-861 extension advertises YCbCr 4:4:4
and 4:2:2 it cannot render, so macOS periodically negotiates YCbCr and the
panel shows a pink cast. There is no flashable firmware fix (factory EDID
only). The reactive workaround — a `WatchPaths` launchd agent calling
BetterDisplay's `set -connectionMode=encoding:rgb+…` — is proprietary and
is a second actor competing with blackoutd's reconfiguration callback.

A FOSS preventive approach exists: inject a YCbCr-stripped virtual EDID via the
private `IOAVServiceSetVirtualEDIDMode`, then drive renegotiation with a no-op
CG recommit (prototype in the maintainer's `inject_edid/` tree; the original
`IOAVControllerForceHotPlugDetect` was dropped — it tore the link to standby).
On Apple Silicon the filesystem `/Library/Displays/.../Overrides/` mechanism
does NOT work; runtime injection is the only host-side option. It is **not**
owner-scoped: the mapping survives the injecting process exiting and survives
display sleep, and is wiped only by full system sleep — so it must be re-applied
on each system wake, not held by a resident ref.

**Scope decision (first acceptance criterion)**: host the correction inside
blackoutd as a distinct `DisplayColorController` module (one resident actor,
owns the reconfiguration callback, can flag its own induced hotplug) versus
a separate standalone daemon (cleaner separation, but reintroduces the
two-actor race the 12:10 incident shows is dangerous). Recommendation leans
toward a blackoutd module, gated so injection happens on external connect
and post-settle only — never an unconditional hotplug during churn.

**Modularity (see ADR 0009)**: if it lands in blackoutd, the quirk is
opt-in and isolated so other users never carry it — its own translation unit
(`src/quirks/DisplayColorController.{h,m}`) compiled only under
`make QUIRKS=sp2309w` (`BLACKOUTD_QUIRK_SP2309W`), keyed to vendor `0x10AC` /
product `0xD01D` even when built in, attached through one narrow generic core
hook rather than a quirk framework (YAGNI — no other quirks are planned).

**Prerequisite (answered 2026-05-21)**: the standalone `inject_edid` work
confirms the virtual EDID survives process exit and display sleep, reverts on
full system sleep, and that inject + recommit renegotiates the panel to RGB end
to end (BetterDisplay-verified), with a few-seconds settle. So a non-resident
one-shot re-applied on each system wake is sufficient; see ADR 0002 (now
Confirmation: met) and `inject_edid` D1 / `investigations/connection-mode.md`.

**Acceptance criteria**:

- [ ] Scope decided (blackoutd module vs. standalone daemon); ADR 0009 moved
      to `accepted` if it lands in blackoutd.
- [ ] Quirk is opt-in: a default `make` compiles no quirk symbols;
      `make QUIRKS=sp2309w` includes them; quirk acts only on `0x10AC`/`0xD01D`.
- [ ] Injection verified to apply RGB — done for the standalone tool: the
      negotiated mode flips `YCbCr 4:4:4 Limited` → `RGB Full` (CEA byte 131
      `0xF1` → `0xC1` is the leading proxy). RGB does NOT survive system sleep,
      so the criterion is **re-applied on wake** (via the wake-settle), not
      "survive wake"; verify once hosted, with no competing actor.
- [ ] BetterDisplay + `restore_rgb.sh` watchdog retired.
- [ ] No interaction with the safety invariant (the induced hotplug is
      recognized as self-originated, not treated as an external event).

**Priority**: below P20 and P4. Optional — this is "its own concept" and
may stay out of blackoutd entirely.

**Files**: if hosted in blackoutd, `src/quirks/DisplayColorController.{h,m}`
compiled only under `make QUIRKS=sp2309w`; default builds omit it. Prototype in
`inject_edid` (`src/inject_edid.m`). See ADR 0009.

---

## P27 — Migrate NSLog to os_log with a subsystem

**Problem**: The daemon logs via `NSLog`. That routes to Apple's unified
logging, so retention is already automatic (no file to rotate — `newsyslog`
does not apply, provided the launchd plist does not redirect
`StandardOutPath`/`StandardErrorPath` to a real file; confirm it sends them to
`/dev/null` or omits them). But `NSLog` lands in the default subsystem with no
categories, so the logs cannot be filtered cleanly and the `[state]`/`[builtin]`/
`[change]` tags are ad hoc text rather than queryable metadata.

**Change**: adopt `os_log` with subsystem `io.github.toobuntu.blackoutd` and a
small set of categories (e.g. `state`, `builtin`, `change`, `wake`). Then
`log show --predicate 'subsystem == "io.github.toobuntu.blackoutd"'` replaces
grepping free text, and diag bundles can filter by category.

**Acceptance criteria**:

- [ ] All `NSLog` call sites in `src/` use `os_log`/`os_log_error` with the
      subsystem and an appropriate category.
- [ ] The launchd plist routes std streams to `/dev/null` (or omits them); no
      unbounded plaintext file is produced.
- [ ] The diag-collection step filters by subsystem rather than process-name
      text matching.

**Priority**: low (hygiene; current logging works). Not a `newsyslog` task.
Interim (2026-05-26): `make dev` and `make reinstall` rotate
`~/Library/Logs/blackoutd.log` via `scripts/rotate-log.sh` during the
bootout→bootstrap gap (agent stopped, fd released), keeping 5 archives — so the
file stays bounded across rebuilds until this migration lands and removes it.

**Files**: `src/*.m` (every `NSLog`), the launchd plist template, the diag
script. Rationale recorded in the shared logging ADR (repo-foundation
`0009-logging-os_log-vs-newsyslog`) with the file-log alternative recipe in
repo-foundation `docs/newsyslog-log-rotation.md`.

---

## P28 — `systemDidWake:` early-return skips the post-settle recommit

**Problem**: On the disconnected-during-sleep wake path, `systemDidWake:`
restores the built-in and `return`s before calling `handleSystemWake`. The
wake-settle quiet timer (ADR 0003) is therefore never armed on that path,
so on a *successful* restore the settle handler `wakeSettleTimerFired`
never runs: no post-settle recommit (P2 / ADR 0003) and no P0 re-blackout.
The daemon ends `isBlackedOut=0` with the external present and
auto-blackout enabled — both displays active — and the external is never
re-absorbed by the settle recommit. ADR 0003's own confirmation criterion
(`[wake] — recommit after settle: ok` must appear on every user wake;
absence indicates the quiet timer never fired) is the detector: the line
is absent in the failing captures and present in the succeeding one.

**Empirical basis (2026-05-25, verbosityLevel=2)**:

- `blackoutd-diag-20260525-122138` and `-135711`: lid-closed sleep; the
  external's coalesced flap callback (`flags` carrying both `add` and
  `remove`) arrives *during* sleep, sets `_externalDisconnectedDuringSleep`,
  the wake takes the early-return path, the restore succeeds, no
  `recommit after settle` line appears, and the daemon ends
  `isBlackedOut=0` (both displays active).
- `-150108`: same path, but the restore additionally hits an err=1014
  storm during a dark-wake / re-sleep thrash (see P25); WS confirms the
  restored built-in returns mirror-primary=external, so it shows the
  external's black source — both panels black with the lid open.
- `-155349`: lid-open sleep. The coalesced flap arrives *after*
  `NSWorkspaceDidWakeNotification` clears `_systemSleeping`, so the flag is
  NOT set, the wake takes the normal path, and the settle timer fires
  (`recommit after settle: ok`). Convergence is correct (`isBlackedOut=1`).
  But cursor-on-black STILL occurred and was cleared only by a hot-corner
  display-power cycle ~14 s after the recommit. Key result: the post-settle
  recommit fired and did NOT recover the external — the display-power cycle
  did. So cursor-on-black is independent of the early-return path and of the
  recommit.

The differentiator is a race (flap-before-wake-notification vs after), not
the lid directly; lid-closed clamshell sleep appears to bias the flap to
arrive during sleep.

**Corrections to existing entries (data-driven, this session)**:

- **err=1014 retry now fires.** P1's acceptance checkbox and P20's note
  state the retry "never arms (wrong-constant guard, 1004 vs 1014)." That
  was fixed in PR#12 (commit 318c69c): the guard now retries on any
  non-`kCGErrorIllegalArgument` failure, and `-150108` shows
  `err=1014 — arming retry 1/3` firing. Those notes are stale.
- **Alt Mode dropout not observed.** None of the four 2026-05-25 captures
  exhibits the "~30 s spontaneous Alt Mode dropout" described in P2, ADR
  0003, and the displayrecommitd README. The only post-wake display-power
  transition in `-155349` is the deliberate hot-corner recovery, not a
  spontaneous hotplug-out. Treat the dropout as *hypothesized*, not
  *established*, until reconfirmed with data.
- **The post-settle recommit does not recover cursor-on-black.** In
  `-155349` the recommit fired (`recommit after settle: ok`) and the
  external stayed black until a hot-corner display-power cycle. P2 / ADR
  0003 / the README imply the no-op CGConfig recommit re-absorbs the
  external; this capture shows it is insufficient on its own — recovery
  needs a stronger action (a display-power cycle, as the hot corner does;
  cf. BetterDisplay's `_reinitializeOnWake`). Open question for P20: is the
  recommit insufficient by *mechanism*, or did it merely fire too early
  (+2 s quiet) before the external finished re-attaching? A manual recommit
  fired late, during the black, would distinguish the two.
- **Cursor-on-black is intermittent and path-independent.** `-170616`
  (lid-closed sleep, old daemon, the buggy early-return path) was clean;
  `-155349` (normal path) was not. So cursor-on-black is neither
  deterministic nor tied to the early-return path.

**Proposed fix**: in `systemDidWake:`, do not `return` after the
disconnected-during-sleep restore — fall through to
`[_displayController handleSystemWake]` so the settle timer arms and the
ADR 0003 flow (post-settle recommit + safety re-check + P0 re-blackout)
runs on every wake, as ADR 0003 already specifies. Keep the immediate
safety restore. Pairs with P25 (avoid nested CG transactions) and P1
(retry budget) for the err=1014 thrash variant, which this change does not
by itself resolve. Scope: (A) fixes the convergence bug only. Per the
recommit finding above it is NOT expected to resolve cursor-on-black, whose
recovery needs a display-power-cycle-class action tracked under P20.

**Landed (14a76a3, "Run wake-settle flow on disconnect path"):**
`systemDidWake:` no longer `return`s after the disconnected-during-sleep
restore — it falls through to `[_displayController handleSystemWake]` on
both paths (verified in source). The convergence fix is in; the empirical
acceptance criteria below (a fresh `verbosityLevel=2` capture on this path)
remain for the maintainer to confirm.

**Acceptance criteria**:

- [ ] `[wake] — recommit after settle: ok` appears on the
      disconnected-during-sleep path, not only the normal path.
- [ ] After a disconnected-during-sleep wake with external present and
      auto-blackout on, the daemon converges to `isBlackedOut=1` (not both
      active).
- [ ] A fresh `verbosityLevel=2` capture shows the settle recommit firing
      on this path and correct convergence. Cursor-on-black recovery is NOT
      expected from this change (`-155349` shows the recommit insufficient);
      that recovery is tracked under P20.
- [ ] No regression on the normal wake path (`-155349` behavior).

**Files**: `src/AppDelegate.m` (`systemDidWake:`). Relates to ADR 0003 and
P0, P1, P20, P25.

---

## P29 — Cursor-on-black: DCP/scanout failure below WindowServer

**Observation (2026-05-25, builds g19–g25, verbosityLevel=2; FALSIFIED
2026-05-26 — see below)**: cursor-on-black on the external *appeared* to
correlate with how the external re-attaches on wake.

- Black wakes: the external's reconfig callback is `flags=0x133e`
  (`add|remove|enabled|disabled|…`) — a coalesced down-then-up "flap"
  (`-122138`, `-135711`, `-150108`, `-155349`, `-192959`, `-212847`).
- Clean / recovered wakes: `flags=0x111e` (`add|enabled`, no remove bit), no
  post-wake external hardware event, or the external reconnecting during sleep
  without a post-wake flap (`-170616`, `-213717`, and every recovery).

Tally: black (maintainer-observed) `-122138`, `-135711`, `-150108`, `-155349`,
`-192959`, `-212847`, `-222732`, `-223301`, `-225050`, `-001343`, `-015528`; clean
`-170616`, `-213717`, `-220028`, `-222940`, `-224742`, `-230242`, `-001426`.
**Counterexample found (`-001343`)**: a black wake whose own incident reconnect
was `0x111e`, not a flap (see Falsified, below). The flag does not separate
black from clean.

**Classify per-wake, not by grep.** Each bundle's `daemon-log.txt` is a
cumulative `tail -500` spanning multiple pids and prior incidents, so a `grep
0x133e` on a bundle surfaces *residual* flaps from earlier incidents — e.g. the
`-223301` 22:31:30 flap reappears in the later `-224742` and `-230242` logs.
Classification must read the capture's *own* wake. Verified that way this
session: `0x111e` clean at own wake on `-220028`, `-222940`, `-224742`,
`-230242`; `0x133e` flap on `-223301` (22:31:30). Note the flap is sometimes
logged at the post-wake reconnect and sometimes at an in-sleep reconnect (no
verbose flag while sleeping), a further reason grep is not a classifier.

**Falsified (2026-05-26) — the reconfig flag does not discriminate.** Scripted
repro (deterministic): `sudo pmset schedule wake "$(date -j -v+15S "+%m/%d/%y
%H:%M:%S")"; pmset sleepnow; sleep 90; ./build/blackoutd diagnose`. In `-001343`
(black, maintainer-confirmed, before recovery) the incident wake (00:12:21)
brought the external back at **`0x111e`** — the supposedly "clean" flag — and
the screen was black regardless. So `0x133e`⇔black / `0x111e`⇔clean is wrong:
`0x111e` can be black. The flap was a coincidental correlate of the earlier
lid-close / trackpad wakes, not the cause or a reliable predictor. Recovery via
hot corner in `-001426` produced **no** reconfiguration callback at all (no
re-enumeration), so "recovery = clean re-enumeration" is also not general.
Consequence: a fix cannot key on the reconfig flag.

**Mechanism also falsified (2026-05-26) — the black is below WindowServer.**
`-001343`'s `windowserver.txt` was read: at the black wake (00:12:20) the
external got a *full, healthy* bring-up — `Display 2 hot plug 1`, `41 timing
modes`, `set power state 1`, `IOMobileFramebufferOpenByName: Framebuffer
found=1`, a complete `[ Display:Mode ]` block, and **`Display 2 set to previous
mode 27`** with `current mode == preferred mode == 2048×1152 fmt:YCbCr444_10bit`.
Across that one log, black wakes (22:31 `-223301`, 00:12 `-001343`), clean wakes
(22:47 `-224742`, 23:02 `-230242`), and the 22:32:54 hot-corner recovery are
**indistinguishable** at the WindowServer layer — same `set to previous mode
27`, same framebuffer-found, same `current mode`. So the mode IS set (to the
preferred mode) on black wakes; the black originates below CoreGraphics, in the
DCP/scanout. This kills the "missing mode-set" mechanism and, with it, the
`CGConfigureDisplayWithDisplayMode`-to-preferred fix (current already ==
preferred, so the call is a no-op). It also means blackoutd has **no CG-visible
signal** that the display is black — a detection problem, not just a recovery
problem.

In `-192959` WS (`ws-20260525-201956.log`): the black wake (19:27:23) shows
**no `[ Display:Mode ]` enumeration** for display 2 across ~47 s of black —
only a storm of `PKGWindowMoveOnMatchingDisplayChangedSeed failed to move
window … (invalid)` and `_CGXPackagesSetWindowConstraints: Invalid window`
(windows placed on a display with no valid scanout). The recovery wake
(19:29:40) emits a full `[ Display:Mode ]` block (41 timing / 8 color modes,
"set to previous mode 27", `2048 x 1152 fmt:YCbCr444_10bit`) and the external
renders. Mode-block count by minute: 85 at 19:29, 0 at 19:27. (The
`fmt:YCbCr444_10bit` here is the encoding macOS *mis-negotiates* from the
SP2309W's defective EDID — the panel is really 8-bit RGB and has no YCbCr decode
path; see ADR 0009 / `inject_edid/docs/sp2309w-display-notes.md`. It is
orthogonal to cursor-on-black: the black is the *absence* of a mode-set, not the
encoding. Do not conflate the two investigations.) **(2026-05-26: `-001343`'s
black wake DID emit a full `[ Display:Mode ]` block with `set to previous mode
27` — contradicting the "no `[ Display:Mode ]` at black" reading taken from
`-192959`. Either `-192959`'s window cut off its mode block or the two are
distinct failure modes; the deterministic `-001343` evidence supersedes for the
mechanism. The `…failed to move window… (invalid)` storm also runs continuously
here, ~170/min for hours, so it is not a black-specific marker.)**

**Mechanism (revised 2026-05-26)**: the black is a DCP/scanout failure *below*
WindowServer. On a black wake the external is enumerated, powered (`set power
state 1`), framebuffer-opened, and set to its preferred mode (mode 27) —
WindowServer / CoreGraphics see a fully configured, healthy display. Nothing at
the CG layer distinguishes black from rendering, so no CG-layer operation
(recommit, mode-set, reconfigure) can detect *or* fix it. Only a display-power
cycle recovers it (hot corner), acting at the DCP/scanout level. Note the
natural wake already toggles `setEnabled 0→1` / `power state 0→1` without
recovering, so the effective recovery is the hot corner's deeper display-sleep
(DCP link re-init), not a CG power-state toggle. The flap (`0x133e`) and the
"missing mode-set" idea are both falsified above.

**Recommit efficacy — open, not settled**: blackoutd's post-settle recommit
and displayrecommitd's are *identical* — `CGBeginDisplayConfiguration` +
`CGCompleteDisplayConfiguration(…, kCGConfigureForSession)`, nothing changed
between. In the two captured black cases (`-155349`, `-192959`) it fired
*early* (~+3 s) and black persisted (~129 s in `-192959`); a no-op transaction
re-commits the current config and may not, on its own, install a mode. This
does NOT establish the recommit is useless in all cases: it was brought into
blackoutd because it was believed to recover *some* occurrences (see
`docs/architecture.md`, ADR 0003, the displayrecommitd repo, and
`displayrecommitd/scripts/displayprobe2.m`), and a *late* recommit (well after
the flap settles) is untested. Treat "recommit recovers cursor-on-black" as
unproven in either direction pending a late-recommit test. (The Alt Mode
"+30 s dropout" framing in P2 / ADR 0003 / the README is separately unobserved
in 2026-05-25 data; see P28.)

**Update (2026-05-25, build g26 — late recommit tested, negative)**: the
automatic late-recommit probe ran in `-223301`. The settle recommit plus all
four late recommits (settle+5/15/30/60 s) logged `ok`, yet the external stayed
black through all of them (~66 s) until a hot-corner display-power cycle
produced a clean `0x111e` re-enumeration and recovered it. So a *late* recommit
does not recover this cursor-on-black either — the no-op recommit is now
empirically insufficient both early and late in the captured cases. `-225050`
confirms `-223301`: late recommits 1/4–3/4 fired `ok` while black, the screen
stayed black, and only the hot-corner power cycle recovered it (n=2; the
cycle-1 settle+60 s fire was correctly preempted when the hot corner slept the
system). The late recommit has served its purpose and can be disabled.
The silent-recovery hypothesis (that "clean" wakes are flaps quietly fixed by a
recommit) is also refuted: `-222940` (clean) shows a genuine `0x111e`
enumeration, not a `0x133e` flap; and `-223301` shows recommits do not silently
fix a flap.

**Recovery candidates.** The flap is not a usable trigger (falsified above), so
a fix must apply on *every* wake-with-external (in `wakeSettleTimerFired`),
not key on a reconfig flag. Heed the known dead ends in `AGENTS.md` first:
`IOServiceRequestProbe` on `DCPDPDeviceProxy` returns `kIOReturnUnsupported`
(`0xe00002c7`) on Apple Silicon (confirmed in displayrecommitd);
`CGDisplaySleep`/`CGDisplayWake` and `pmset displaysleepnow` flicker. The
realistic, untried candidates are:

1. A *late* CG recommit — **tested g26, negative** (`-223301`/`-225050`: all
   fired `ok`, black persisted, hot corner recovered). Ready to disable.
2. Explicit mode-set via `CGConfigureDisplayWithDisplayMode` to the preferred
   mode — **predicted no-op, do not pursue**: `-001343`'s WS shows the black
   wake already at `current == preferred` mode 27, so re-setting it changes
   nothing (the same reason the recommit fails). A CG-layer operation cannot
   fix a below-CG scanout failure.
3. Display-power cycle that reaches the DCP (hot-corner equivalent) — the only
   approach with evidence behind it (the hot corner is the sole observed
   recovery). Flicker is accepted by the maintainer for a definitive fix. Open:
   which API reproduces the hot corner's effect — a *CG* power-state toggle
   (`CGDisplaySleep`/`Wake`) likely does NOT suffice (the natural wake already
   toggles `power state 0→1` without recovering); candidates that reach the DCP
   link are `IODisplayWrangler` `IORequestIdle` (private) or `pmset
   displaysleepnow` (sudo). Both flicker.

**Detection is the harder half.** Because black is invisible at the CG layer
(see Mechanism), blackoutd cannot tell a black wake from a good one. A fix that
power-cycles on *every* wake-with-external would flicker every wake; a targeted
fix needs a below-CG black signal (a DCP / `dcpext` scanout property in
`ioreg.txt` — the `inject_edid --mode` reader is the place to look). If neither
is acceptable, document the manual hot-corner recovery and treat auto-recovery
as out of scope.

**Open / to confirm**:

- ~~Does `0x133e` reliably predict black?~~ **Answered: no** (falsified
  2026-05-26; `-001343` was black at `0x111e`). The reconfig flag is not a
  classifier.
- ~~Manual/late recommit recovers?~~ **Answered: no** (g26 late recommit tested
  negative, `-223301`/`-225050`). A `blackoutd recommit` CLI is therefore low
  value.
- ~~What mode does the black wake hold vs preferred?~~ **Answered: the
  preferred mode** (`-001343` WS: black wake at `current == preferred` mode 27).
  The black is below CoreGraphics, not a mode mismatch.
- New central question: is there a below-CG (DCP / `dcpext`) property that
  distinguishes black from rendering, to drive *detection*? Look in `ioreg.txt`
  via the `inject_edid --mode` reader. Without one, only an unconditional
  power-cycle-on-wake (flicker) or manual hot-corner recovery remain.

**Update (2026-05-26) — below-CG confirmed; a candidate detector; role reversal.**
- *Mechanism confirmed.* Same-wake ioreg diff (`-015528` black vs `-015648`
  recovered) isolates the change to the external `dcpext` node: `DCPPowerState`
  0→4 and `DCPPowerAssertionCount` 0→1 (the `DCPDPDeviceProxy` /
  `DCPAVVideoInterfaceProxy` proxies also (re)register on recovery). The
  built-in `dcp` stays `DCPPowerState=4` throughout. So black = external DCP not
  powered to scanout, below CoreGraphics — as the WS evidence implied.
- *Candidate detector (promising, unverified).* External `dcpext`
  `DCPPowerState` reads 0 in both controlled black captures (`-001343`,
  `-015528`) and 4 in their recoveries (`-001426`, `-015648`) — a clean 0/4
  split. BUT two uncontrolled captures break it: `-085729` (external active)
  read 0 and `-093747` (black, mid-saga) read 4 — likely capture-instant timing
  (powersave ramp / role-reversal). DPMS powersave also reads 0. So
  `DCPPowerState` is the best below-CG signal found but is NOT yet a trustworthy
  sole trigger. Validate by capturing *at the black instant* (not ~90 s later)
  with the observed on-screen state recorded, repeatedly, and confirm
  0⇔black / 4⇔rendering. Surface `dcpext` `DCPPowerState` /
  `DCPPowerAssertionCount` in `diagnose` to make this cheap.
  **(2026-05-26, later — REFUTED as read.** The cross-file readout is unsound:
  there are two `AppleDCPExpert` nodes (built-in + external) and they cannot be
  told apart by position. Validation captures invert the naive signal —
  `-140624` (external actively rendering) read 0; `-141433` (cursor-on-black, on
  AC) read 4. Pooled by observed state: black `{0,0,4,4}` vs active `{4,4,0,0}`,
  i.e. no correlation. The *only* sound observation is the within-pair diff
  `-015528`→`-015648`, where the `DCPEXT` block's value went 0→4 — n=1. So
  `DCPPowerState` is NOT a usable detector as currently read.
  **(2026-05-26, settled — DEAD.** Re-extracted with correct attribution: each
  `AppleDCPExpert` carries `"role" = "DCP"` (built-in) or `"DCPEXT"` (external).
  Keyed on role, the **external `DCPEXT` `DCPPowerState` is 4 in every capture**
  — black, clean, and recovered alike; it never varies. The 0→4 I had seen
  (including the `-015528`→`-015648` within-pair diff) was the **built-in's**
  DCP, which reads 0 when the built-in is blacked out
  (`CGSConfigureDisplayEnabled(false)`) and 4 when active — i.e. it tracks
  blackout state, not the external scanout. So `DCPPowerState` carries no
  cursor-on-black signal. Consistent with the WS finding: the stalled scanout
  is not surfaced to ioreg at all. There is no below-CG detector here; treat
  ioreg-based black detection as unavailable, and use unconditional recovery on
  every wake-with-external. `diagnose` may still record both DCPs (labeled by
  role) for forensics, but not as a detector.)**
- *Role reversal (new; `-093747`/`-093819` saga, battery).* After `pmset
  displaysleepnow` + trackpad wake, the **built-in** was briefly cursor-on-black,
  then it moved to the external. The black is not external-specific; it lands on
  whichever display the DCP fails to scan out. Reinforces firmware/DCP scanout,
  and a fix must handle either display.
- *Recovery levers.* (a) `pmset displaysleepnow` (a DCP-level display sleep)
  eventually recovered, with messy intermediate states — consistent with the hot
  corner. (b) **Reuse blackoutd's own primitive**: blackout = `applyEnable:` →
  `CGSConfigureDisplayEnabled(…, false/true)`. A disable→enable cycle on the
  *external* tears down and rebuilds its config — a stronger lever than the
  no-op recommit, worth testing as recovery, though still CG-level so it may not
  reach the DCP. Sequence carefully (never leave zero active displays — keep or
  restore the built-in during the external cycle); expect flicker.
- *Power source.* No controlled comparison yet; cursor-on-black reproduces on
  battery (scripted and natural). AC was clean in `-213717`/`-220028`, but those
  were not the scripted repro. To attribute power-source dependence, run the
  same `pmset schedule wake` repro on AC. AGENTS.md already flags
  battery-at-sleep as a coincidental non-predictor.
  **(2026-05-26: done — `-141433` ran the scripted repro on AC and was
  cursor-on-black. The bug is NOT power-source-dependent; AC reproduces it.)**

**Update (2026-06-10) — `diagnose` now records this natively.** The CLI
writes two role-attributed bundle files: `dcp.txt` (AppleDCPExpert power by
`role`: DCP/DCPEXT `DCPPowerState`/`DCPPowerAssertionCount`, plus AppleCLCD2
scanout state — `NormalModeActive`, resolution, `DPTimingModeId`,
`Transport`) and `connection-mode.txt` (per-display `EDID UUID` + the
advertised `ColorElements` catalog: pixel encoding / bpc / dynamic range).
Attribution is by the IOKit `role`/`external` properties, not iteration
order — closing the position-based misattribution that produced the false
0/4 detector readings above. Live role-attributed runs (M2 + SP2309W)
reconfirm the dead detector: the external `DCPEXT` `DCPPowerState` reads 4
whenever it is rendering, as before. The BUILT-IN's DCP value is dynamic
and does not reliably track blackout state either — the 2026-05-26
within-pair diff read 0 while blacked out, a 2026-06-10 sample read 4 with
`NormalModeActive=yes` while equally blacked out
(`CGSConfigureDisplayEnabled(false)` is not reflected in these IOMFB
fields), and a six-bundle A/B on 2026-06-10/11 found no consistent 0-vs-4
black/clean split. `DCPPowerState` carries no cursor-on-black signal on
either controller. `NormalModeActive` and `DCPPowerAssertionCount` remain
untested as detectors; capture them at the black instant to test.

**Update (2026-07-19) — cohort 2 diff: a WindowServer log marker splits
black from clean, 10/10 vs 0/15.** Cohort 2 (matrix runs 011+, sheets
under `docs/debug/repro-matrix/`, v0.4.0 build) satisfied the capture
gate: settled group A blacks runs 14, 22, 24 (battery, on-condition;
run 11 also black but on AC) vs cleans runs 12, 13, 15, 16, 18, 20,
21, 23, 36. Run 17 settled E2 (black, no cursor — a black panel the
E1-keyed Outcome line scores "no"); run 19 disregarded (maintainer:
possibly misreported). Field-by-field diff of the post-wake bundles
under matching conditions:

- `dcp.txt` / `connection-mode.txt`: **byte-identical** across all
  three on-condition blacks and all nine cleans. This extends the dead
  `DCPPowerState` verdict to the previously untested fields:
  `NormalModeActive`, `DCPPowerAssertionCount`, resolution /
  `DPTimingModeId` / `Transport`, and the advertised ColorElements
  catalog — none carries any black/clean signal (negative).
- `config.txt`: differs only in timestamps (negative).
- `ioreg.txt`: with volatile fields masked (object ids, busy times,
  retain counts, `IOPowerManagement`, `DebugState`, statistics,
  `TransferCount`), the external `dcpext@71C00000` subtree of black
  run 14 is byte-identical to clean runs 13 and 36, and black run 22
  to clean run 18; the built-in `dcp@31C00000` subtree is identical
  across all on-condition blacks and cleans. The stalled scanout is
  not surfaced to ioreg at all — confirms the 2026-06-10 reading
  (negative).
- `windowserver.txt`: **positive.** Clipped to each run's own wake
  window (per the classify-per-wake rule above), the SkyLight line
  `[ Display:Hotplug ] Replacing existing hotplug event for state
  "out" with "in", display id: 2` appears exactly once at the wake of
  every black-panel run — run 14 (11:02:20), run 22 (12:19:31), run 24
  (12:23:07), plus corroborating run 11 (00:09:39, AC), run 37
  (14:18:40, group B post-wake), and the E2-variant run 17 (12:06:07)
  — and zero times in all nine cleans, each of whose logs covers the
  full wake window. Cohort 1 corroborates: in-window marker on all
  four blacks (runs 3, 5, 7, 8), on none of the five cleans nor
  stricken run 9 (run 10's file carries the line 7 minutes *before*
  its run — outside the window, the same per-wake trap as the 0x133e
  grep). Combined: **10/10 black-panel wakes vs 0/15 clean**; the
  n ≥ 3 bar is met on cohort 2 alone.

**Mechanism reading.** The marker means WindowServer still holds an
unprocessed hotplug "out" for display 2 when the wake "in" arrives,
and SkyLight coalesces the pair. So on black wakes the external
dropped its link during sleep (hypothesis A, Alt Mode dropout) and
WindowServer — seeing continuity — skips the full teardown/re-attach,
leaving the DCP scanout un-rearmed while every CG/WS-visible field
looks healthy (the below-WS mechanism above). Clean wakes show no
coalescing. A secondary, effect-side split points the same way: the
FuseBoard `updated window N from "occluded" to "visible"` line appears
≥ 5 times in every clean wake window and never in a black one (windows
only become visible when the external actually renders).

**Side observations (not detectors).**

- Runs 11 and 37 — the only two blacks whose sheets record an
  *immediate* E1/B0 wake (no role reversal) — are also the only two
  captures whose built-in DCP reads `DCPPowerState=4` / assertion 1,
  with the built-in advertising ColorElements; run 37's post-recover
  bundle still reads 4, and the clean music-playing runs 38–40 read 0.
  The on-condition blacks (14, 22, 24; immediate E2/B1) read 0 like
  every clean. This sub-classes the wake shape, not black vs clean.
- Disregarded run 19: later runs' log windows show the marker fired at
  12:08:58, inside run 19's wake window — consistent with its original
  "black" record, but it stays out of every tally per the maintainer.

**Next steps.** Detection is now plausible with no new private API: at
`wakeSettleTimerFired`, query the unified log for the marker over the
last ~60 s (`OSLogStore`, or `log show --last 60s --predicate 'process
== "WindowServer" AND eventMessage CONTAINS "Replacing existing
hotplug event"'`; the line logs at Default level, so it is in the
persistent store without any debug-logging setup; in cohort 2 it fires
~3.5 s *before* the daemon's settle marker, so it is already on disk
when the settle timer fires). Marker present ⇒ arm the
display-power-cycle-class recovery; absent ⇒ do nothing. Caveats: the
wording is private SkyLight internals and can change across macOS
releases — treat a missing marker as "unknown", pin the predicate per
macOS version, and keep the eyewitness matrix as the validation loop.
Sequence:

1. More group B runs until a second black lands (recovery is 1/1 in
   cohort 2 — run 37 black ⇒ `--recover displaysleep` ⇒ cleared,
   post-recover E0/B0 — corroborated by cohort 1's four manual clears,
   but below the matrix's n ≥ 2 bar); then group C (locked).
2. Prototype the detector read-only (log the query verdict at settle
   time, no recovery wiring) and validate it live against ≥ 3 further
   eyewitness-confirmed blacks and cleans.
3. Only then wire detector ⇒ recovery, behind a `recoveryStrategy`
   pref (separate PR, per the matrix's "What we do with the data").

**Update (2026-07-19, later) — extension runs 41–60: marker at 19/19
vs 0/26; a manual repro lever (C1); recovery question answered.**

- *Marker validated on 20 more runs.* Blacks 49, 51–54, 56–57 (group
  B) and 58, 60 (group C series): the hotplug-coalescing marker fires
  in-window on **9/9**; the 11 cleans (41–48, 50, 55, 59) show **0**.
  Running total **19/19 black vs 0/26 clean** across all recorded
  runs. The FuseBoard occluded→visible secondary is demoted: the
  extension breaks its clean split (black run 49 shows 1, locked
  black run 60 shows 5) — corroborator only, not a detector.
- *C1 — the cable trigger (first on-demand repro lever).* Unplugging
  the external's **USB-C end** pre-run (leaving it out until the
  built-in fully redraws, then replugging) provoked cursor-on-black
  on the next wake in 8 of 9 tries (blacks 49, 51–54, 56–57, 60;
  miss 55). Mechanistically consistent with the coalescing story: a
  fresh physical re-attach immediately before sleep leaves link
  state that drops again across the sleep boundary. Critically, the
  C1-miss run 55 shows the pre-run replug alone does **not** plant
  the marker — the marker still tracks the black, not the cable
  handling. Run 58's Notes record no C1, but the maintainer later
  recalled the cable trigger may have been applied there too — do
  not cite run 58 as a trigger-free natural repro. C1 makes
  recovery-candidate testing cheap: black on demand, ~3 min per
  data point.
- *Recovery: displaysleep is 10/10.* Every black in the extension was
  cleared end-to-end by `--recover displaysleep` (`pmset
  displaysleepnow` + `caffeinate -u`, no root), including run 60
  **while the session stayed locked**. With run 37 that is 10/10
  programmatic clears plus cohort 1's four manual ones. Group B's
  question is answered; group C (locked) is 1/1 and stays open until
  n ≥ 2. The 2026-05-21 "displaysleepnow = flicker dead end" note is
  fully superseded for the *recovery* path (flicker accepted).
- *Deterministic detection beyond the log query (survey, untested).*
  The marker is not a proxy — it is the trace of the exact SkyLight
  branch that matters (the pending-"out" coalescing decision), and
  no exported SkyLight symbol surfaces that queue state; a private
  SkyLight *notification* would sit downstream of the same coalescing
  and inherit the blind spot (the falsified `0x133e` flag is the
  public shadow of exactly that). The genuinely deterministic path is
  to observe the raw hotplug **upstream** of WindowServer:
  `IOMobileFramebuffer.framework` exports
  `IOMobileFramebufferEnableHotPlugDetectNotifications` /
  `IOMobileFramebufferGetHotPlugRunLoopSource` (per-framebuffer HPD
  events; BetterDisplay links this framework from an ordinary
  notarized app, so the user client is reachable without special
  entitlements). blackoutd already opens no IOMFB connection; a
  read-only spike would open the external framebuffer
  (`IOMobileFramebufferOpenByName`, name `external-0` per the WS
  logs) at daemon start, log timestamped HPD events, and let a C1
  series show whether an HPD-event pattern around the sleep boundary
  splits black/clean. If it does, detection needs no log query at
  all. Until then, `OSLogStore` (in-process, structured predicate,
  no subprocess) is the implementation of record for the marker
  query — prefer it over spawning `log show`.
- *Targeted recovery beyond displaysleep (survey, untested).*
  Candidates, in prototype order: (1)
  `IOMobileFramebufferRequestPowerChange` on the external framebuffer
  only — a DCP-level power cycle scoped to one display, no global
  display sleep, no lock-screen interaction; (2) blackoutd's own
  primitive, `CGSConfigureDisplayEnabled(external, false→true)` — no
  new API but CG-level, may not reach the DCP (P29 lever b, still
  untested); (3) DDC power cycle of the sink (VCP 0xD6 off→on via
  `IOAVService` I2C, the Lunar/m1ddc path, open source — no RE
  needed) — the software analog of the physical replug that C1 shows
  re-arms the link, but sink-side and dependent on the SP2309W's DDC
  support. Test each as a new `--recover` method against C1 blacks;
  adopt over displaysleep only if ≥ its reliability. BetterDisplay
  RE (its `_reinitializeOnWake` implementation) is the fallback if
  all three miss.
- *Group C invocation* (osascript lock before `repro`) is recorded in
  the matrix, with run 58's ordering lesson (lock keystroke chained
  after `repro` never took effect; its machine-read session field
  caught it).
- *Tooling (implemented same day, runtime-untested).* Candidate (2)
  above — the external disable/re-enable cycle — is now built as
  `extcycle`, dispatchable both as a recovery (`recover --method
  extcycle`, `repro --recover extcycle`) and as a pre-sleep trigger
  (`repro --trigger extcycle`, the software analog of C1: disable,
  5 s for the built-in restore/redraw, re-enable, 5 s re-attach
  settle). The sheet's conditions block gains a machine-filled
  `trigger` line so soft-trigger runs are distinguished from
  physical C1 runs, and `blackoutd --help` now documents the
  recover/repro methods. Validation order: (a) soft-trigger A/B —
  does `--trigger extcycle` reproduce the black like C1? Either
  answer is informative: yes ⇒ fully software repro, no ⇒ the
  trigger's essence is physical HPD, itself a mechanism datum;
  (b) if C1 (or the soft trigger) keeps producing blacks, race
  `--recover extcycle` against them — does a CG-level cycle clear
  what the no-op recommit could not?

**Update (2026-07-19, evening) — soft trigger works (18/20); marker
at 39/39 vs 0/31; extcycle recovery is lock-state-dependent; the bug
is host-side.** Runs 61–85 (matrix "soft-trigger series" and group C
extension tables).

- *The repro is now fully software.* `--trigger extcycle` provoked
  cursor-on-black in **18 of 20** runs (blacks 61–70, 73–80; misses
  71–72) with **no cable handling and no physical HPD event** — the
  external only entered powersave during the cycle. Healthy-state
  sanity: 9/9 manual `recover --method extcycle` cycles ran the same
  sequence (external drops → built-in lights at native resolution →
  external powersave → built-in re-mirrors the external's resolution
  → built-in re-blacks → external returns).
- *All 20 trigger runs were `W1` (scheduled wake failed, manual
  Space/trackpad wake) — a repro bug, not a power quirk*: the wake
  was scheduled before the trigger, whose ~15 s of cueing and
  settling left the wake time in the past by the time the machine
  slept. Fixed same evening: `sudo --validate` is now built into
  repro (no more manual prefix), the trigger runs before the
  schedule step and the wake time is computed after it, a new
  **"awake" cue** speaks within ~1 s of the detected wake (the
  settle countdown now anchors at the wake, not at sleepnow), and a
  new `--lock` flag replaces the manual osascript lock chain.
  Silver lining recorded: the W1 runs show the black reproduces on
  *manual* wakes too — it is not scheduled-wake-specific.
- *Marker: 20/20 new blacks, 0/5 new cleans — running total 39/39
  vs 0/31.* Critically, the two trigger-but-clean runs (71, 72)
  show the trigger's own pre-sleep hotplug pair does **not** plant
  the marker, and every marker timestamp sits at the wake instant
  (e.g. run 61: start 20:24:01, marker 20:25:20 at the manual
  wake), not at the trigger. The detector survives the soft-trigger
  regime intact.
- *extcycle as recovery: usable only unlocked.* Unlocked (runs
  69–80): cleared **10/10** blacks — the first recovery besides the
  display-sleep class, and evidence that a CG-level teardown/rebuild
  *can* re-arm the scanout (where the no-op recommit could not).
  Locked (runs 81–85): it failed on both blacks (81, 83: cleared
  then **both panels went black**) and **induced** a black external
  on clean wakes (84, 85); run 84's aftermath left the external
  absent from CGGetOnlineDisplayList entirely (`extcycle: no
  external display online`) until the next sleep/wake re-onlined
  it, and `blackoutd off`/`on` cycles did not restore it after run
  81. **displaysleep remains the recovery of record** (works locked
  and unlocked); any future automatic wiring must either gate
  extcycle on an unlocked session or just use displaysleep.
- *Shakedown after run 85 (23:01, unnumbered — Ctrl-C'd, no sheet):
  the tick-loop wake detector was defective and is replaced.* On the
  reordered build the trigger again produced the black (E2/B1 →
  E1/B1 → E1/B0, held indefinitely; hot corner recovered), but repro
  went silent: no "awake" cue, no capture. Root cause: the loop
  detected a wake only when one 1 s tick spanned > 5 s of wall
  clock, and with the wake lead consumed by fall-asleep time the
  actual sleep span can be under 5 s — the scheduled wake most
  likely fired (the panels lit unprompted) and the detector missed
  it, spinning forever (it had no ceiling). Reworked same night:
  repro now registers `NSWorkspaceWillSleepNotification` /
  `NSWorkspaceDidWakeNotification` observers before `sleepnow` and
  waits on the did-wake notification in a run loop (deterministic
  for arbitrarily short sleeps), keeps the tick-jump check only as
  a fallback, aborts if no will-sleep arrives within 60 s of
  `sleepnow` (a sleep that never happens must error, not hang; the
  wake side deliberately has no ceiling — overnight manual wakes
  are legitimate), and schedules the wake immediately before
  `sleepnow` so lock/conditions/cue time no longer shaves the
  sleep span. For the record: the 1 s ticks cannot cause or prevent
  a wake — sleeping threads hold no power assertions and userspace
  timers do not program RTC wakes.
- *Attribution (maintainer asked: OS, cable, display, or interfering
  software?).* The evidence points at the **macOS display stack
  (SkyLight/DCP wake path), host-side**: the soft trigger reproduces
  the black with the cable untouched and no physical HPD (cable and
  monitor-side link exonerated as necessary conditions); the
  detector is WindowServer's own hotplug-coalescing bookkeeping; and
  every recovery that works (hot corner, displaysleep, unlocked
  extcycle, physical replug) is a host-side pipeline rebuild. The
  SP2309W/adapter's slow re-attach remains a plausible
  *frequency* contributor (it shapes when a hotplug pair straddles
  the wake), and one third-party confound is untested:
  MonitorControlLite (software brightness shade) was running during
  all recorded runs. Cheap control series: quit MonitorControlLite
  (slider at 100%), run ~6 soft-trigger runs — if blacks persist,
  the confound is retired; Brisync was never running and is
  irrelevant.

**Update (2026-07-20) — confound retired; auto-recovery implemented.**
Runs 86–104 (matrix "shakedowns, MCL controls, groups C/D/E" table):

- *Marker all-time tally: 56/56 black vs 0/33 clean* (17 more blacks,
  2 more cleans; every capture regime — cable, soft trigger, locked,
  AC, lid).
- *MonitorControlLite retired as a confound*: 15 runs with MCL quit
  produced 13 blacks, indistinguishable from before. Attribution
  stands: a macOS SkyLight/DCP wake-path defect, host-side.
- *Recovery evidence complete*: locked displaysleep n=5 (runs 60,
  98–101); group D answered (six AC blacks — not power-dependent);
  group E's lived scenario (run 104 lid-open wake) reproduced black
  and recovered. Every programmatic displaysleep recovery across the
  whole matrix has cleared its black.
- *Auto-recovery is now wired into the daemon.* At
  `wakeSettleTimerFired`, when an external is present, the daemon
  queries the unified log (spawning `log show` over a window opening
  30 s before the recorded wake — the same unprivileged path
  `diagnose` uses) for the coalescing marker; if present it runs the
  displaysleep cycle (`pmset displaysleepnow`, 2 s, `caffeinate -u`)
  off the main queue. Gated by the new `recoveryStrategy` pref
  (String, default `displaysleep`; `none` disables; unknown values
  fall back to none), set via the new `blackoutd recovery
  <none|displaysleep>` subcommand (SIGHUP reload, P23 pattern) and
  shown in `status`/`config.txt`. Guards: once-per-wake latch,
  `_systemSleeping` re-check, marker absence = no action; the
  display-sleep cycle emits screen (not system) sleep notifications,
  so it cannot re-arm the wake path and loop. **Matrix data
  collection must now disable it first** (`blackoutd recovery none`)
  or captures record the recovered panel — see the matrix how-to.
- *Flicker-free recovery and BetterDisplay RE remain open* (the
  displaysleep cycle blinks both panels): candidates stay
  `IOMobileFramebufferRequestPowerChange` (per-framebuffer, private)
  and a BD `_reinitializeOnWake` RE pass — behind the now-standing
  detector, as a follow-up PR. The extcycle recovery is ruled out for
  automatic use (locked-session hazard, 2026-07-19 evening update).
  A first probe is in the tree: `recover --method fbpower` (CLI-only,
  dlsym-resolved, signatures unverified — a crash is a data point).
  Smoke it against a soft-trigger black; even a refusal at
  `IOMobileFramebufferOpenByName` is an answer, since the
  HPD-notification detection idea rides on the same user-client
  access.
- *Wake-cue audibility*: the "awake" `say` cue is intermittently
  inaudible right after wake (audio-device bring-up race; both power
  sources affected). Detection and captures are unaffected; the
  Notification Center banner carries the timestamp. Known quirk.
- *Live validation (runs 106–107).* With `recoveryStrategy
  displaysleep` active and no repro-side `--recover`, a soft-trigger
  black wake (run 106) cleared to E0/B0 before the "capturing post
  wake" cue, and a clean wake (run 107) passed through untouched —
  and the maintainer perceived **no flicker**: firing the cycle at
  wake-settle lands it inside the wake transition, before the panels
  have visibly stabilized. That takes most of the urgency out of the
  flicker-free follow-up (fbpower probe untried as of run 107); it
  remains worth one smoke test on principle.

**Files**: `src/main.m` (the `diagnose` `dcp.txt` / `connection-mode.txt`
readers); investigation otherwise. Relates to P2, P20, P28, ADR 0003, ADR
0009 (SP2309W YCbCr), and the inject_edid `--mode` reader (of which
`connection-mode.txt` is the first piece).
