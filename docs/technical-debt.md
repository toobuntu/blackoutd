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
P1 — note the 2026-05-19 defect recorded there: the retry half of that
fix never actually fires (wrong-constant guard). P20 is still
open: the cursor-on-black state can occur without a sleep cycle, so it
sits outside the err=1014 fix's reach.

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
3. On `kCGErrorCannotComplete` from `setDisplay:enabled:`, `applyEnable:`
   arms the wake-settle timer to drive a retry through the existing
   pipeline. Bounded by `_failedActionRetries` (file-static const
   `kBDMaxFailedActionRetries=3`); reset on success and on
   `invalidateDisplayState` (called from `systemDidWake:`).

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
- [ ] err=1014 from `setDisplay:enabled:` triggers retry via wake-settle
      with bounded retry count — **NOT working: guard compares against
      `kCGErrorCannotComplete` (1004), not the real `1014`; retry never
      arms. See the 2026-05-19 defect note above and P25.**
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
sleep-gating parts of the P1 hardening address that family, but the
err=1014 *retry* path does not actually fire (wrong-constant guard; see
P1 and P25). However, the
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

## P29 — Cursor-on-black: flap wake → missing display-mode set (hypothesis)

**Observation (2026-05-25, builds g19–g25, verbosityLevel=2)**: cursor-on-black
on the external correlates with how the external re-attaches on wake.

- Black wakes: the external's reconfig callback is `flags=0x133e`
  (`add|remove|enabled|disabled|…`) — a coalesced down-then-up "flap"
  (`-122138`, `-135711`, `-150108`, `-155349`, `-192959`, `-212847`).
- Clean / recovered wakes: `flags=0x111e` (`add|enabled`, no remove bit), no
  post-wake external hardware event, or the external reconnecting during sleep
  without a post-wake flap (`-170616`, `-213717`, and every recovery).

Tally as of 2026-05-25: black (maintainer-observed) `-122138`, `-135711`,
`-150108`, `-155349`, `-192959`, `-212847`, `-222732`, `-223301`, `-225050`;
clean `-170616`, `-213717`, `-220028`, `-222940`, `-224742`, `-230242`. No
counterexample so far (no wake verified as clean `0x111e`/no-flap that was also
black).

**Classify per-wake, not by grep.** Each bundle's `daemon-log.txt` is a
cumulative `tail -500` spanning multiple pids and prior incidents, so a `grep
0x133e` on a bundle surfaces *residual* flaps from earlier incidents — e.g. the
`-223301` 22:31:30 flap reappears in the later `-224742` and `-230242` logs.
Classification must read the capture's *own* wake. Verified that way this
session: `0x111e` clean at own wake on `-220028`, `-222940`, `-224742`,
`-230242`; `0x133e` flap on `-223301` (22:31:30). Note the flap is sometimes
logged at the post-wake reconnect and sometimes at an in-sleep reconnect (no
verbose flag while sleeping), a further reason grep is not a classifier.

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
encoding. Do not conflate the two investigations.)

**Hypothesis**: the flap re-enumerates the external without a valid
display-mode set, leaving it configured-but-not-scanning-out → black with the
hardware cursor. Recovery works because a display-power cycle (hot corner /
idle-off / on-battery system sleep) forces a fresh enumeration that re-runs
the mode-set. This matches the maintainer's standing observation that the
external "always comes back at a wrong mode."

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

**Recovery candidates** (fire on a flap wake, which blackoutd already detects
via `0x133e`). Heed the known dead ends in `AGENTS.md` first:
`IOServiceRequestProbe` on `DCPDPDeviceProxy` returns `kIOReturnUnsupported`
(`0xe00002c7`) on Apple Silicon (confirmed in displayrecommitd);
`CGDisplaySleep`/`CGDisplayWake` and `pmset displaysleepnow` flicker. The
realistic, untried candidates are:

1. A *late* CG recommit (automatic, settle+5/15/30/60 s) — **tested g26,
   negative** (`-223301`: all fired `ok`, external stayed black ~66 s until a
   hot-corner power cycle recovered it; `-225050` confirms, n=2). Recommit is
   insufficient early and late; ready to disable.
2. Explicit mode-set via `CGConfigureDisplayWithDisplayMode` to the preferred
   mode (from `CGDisplayCopyAllDisplayModes`) — public API, no sudo, minimal
   flicker; directly installs the mode the flap skipped (the P29 missing-mode
   hypothesis). The leading untried candidate.
3. Display-power cycle (the known-good hot-corner equivalent; forces a clean
   `0x111e` re-enumeration). Flickers, but the maintainer accepts flicker if it
   proves the definitive fix. Use if the mode-set is insufficient.

**Open / to confirm**:

- Does `0x133e` reliably predict black? Classify 2–3 more captures by
  (external wake flags, black or not). `diagnose` records both.
- Manual late recommit: recovers (timing) or not (mechanism)? Test via a
  one-shot `blackoutd recommit` (`SIGINFO`, planned). displayrecommitd's
  recommit being a no-op makes "insufficient by mechanism" the leading guess.
- What mode does the black wake hold vs the preferred mode? Confirm with the
  new wake-anchored window (captures the onset) and an inject_edid `--mode`
  reader surfaced in `diagnose`.

**Files**: investigation only so far. Relates to P2, P20, P28, ADR 0003, ADR
0009 (SP2309W YCbCr), and a future inject_edid `--mode` reader.
