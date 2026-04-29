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
history for context). New entries are append-only; do not renumber.

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
- [ ] Verified: short sleep (<1 min), long sleep (DarkWake observed),
      `pmset sleepnow`, lid-close sleep
- [ ] Log shows `[state] ... — initiating blackout action` within 5s of wake

**Files**: `src/AppDelegate.m` (systemDidWake:), `src/DisplayController.m`
(handleSystemWake, resetWakeSettleTimer, wakeSettleTimerFired,
invalidateDisplayState)

**Note (P10)**: The dispatch_source churn from `resetWakeSettleTimer` on
every callback is a known efficiency wart — see P10.

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
1. Update `CFBundleShortVersionString` in `src/Info.plist` (e.g., `0.3.0`).
   The bump type (major/minor/patch) is decided by you, not by the
   Makefile — `make release` simply consumes whatever value lives there.
2. Update `CFBundleVersion` (increment by 1).
3. Commit the version change: `git commit -m "chore: bump version to 0.3.0"`.
4. Run `make release` to build and create the tag.
5. Push the tag: `git push origin v<VERSION>`.

**Rollback**: `make release` has no automatic teardown. The flow is
preflight (refuses dirty tree or pre-existing tag) → build (failure
prevents tag creation) → `git tag -a` (atomic). If you discover after
tagging that the release was wrong (signing didn't take, version bump was
wrong), clean up manually:

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
- [ ] Hardening per P17 (semver validation, release-undo target, dry-run)

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
- ~~No REUSE 3.0 license-header check in CI.~~ **DONE in scaffolding PR**:
  `lint-reuse` job runs `fsfe/reuse-action` on every PR.
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
`@"blackoutActive"` appears in 2. Both are spelled correctly today; both
will not be tomorrow.

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
