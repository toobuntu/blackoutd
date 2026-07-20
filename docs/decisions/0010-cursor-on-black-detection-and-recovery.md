---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 10
title: Detector-gated displaysleep recovery for cursor-on-black
status: accepted
date: 2026-07-20
decision-makers:
  - toobuntu
---

# Detector-gated displaysleep recovery for cursor-on-black

## Context and Problem Statement

The cursor-on-black failure (technical-debt P20/P29) leaves the external
display black with only the mouse cursor after a sleep/wake cycle, while
every CoreGraphics- and WindowServer-visible field reports a healthy,
fully configured display: the mode is set (`current == preferred`), the
framebuffer is found, `dcp.txt` / `connection-mode.txt` / `ioreg` state
is byte-identical to a clean wake. The failure is a DCP/scanout stall
below WindowServer. Automatic recovery therefore needs two things
blackoutd did not have: a **detection signal** (so recovery does not
flicker every healthy wake) and a **recovery action** stronger than the
ADR-0003 no-op recommit (empirically insufficient, early and late).

The empirical matrix (`docs/debug/cursor-on-black-matrix.md`, runs
1–104) settled both:

- **Detection.** One WindowServer log line separates black wakes from
  clean ones: `[ Display:Hotplug ] Replacing existing hotplug event for
  state "out" with "in", display id: 2` — SkyLight coalescing a
  still-pending hotplug "out" with the wake's "in". Tally: present in
  the wake window of **56/56** eyewitness-confirmed black wakes, absent
  from **33/33** clean ones, across cable-triggered, software-triggered
  (`repro --trigger extcycle`), natural, locked, AC, and lid-open
  regimes. Control runs show the pre-sleep trigger itself never plants
  the marker; every marker timestamp sits at the wake instant.
- **Recovery.** A display-sleep cycle (`pmset displaysleepnow`, then
  `caffeinate -u` to relight) cleared **every** programmatic recovery
  attempt in the matrix, locked (n=5) and unlocked alike, plus all
  manual hot-corner clears. It needs no privileges.

## Decision Drivers

* Recovery must not flicker healthy wakes — the majority — so it needs
  a detection gate, not a schedule.
* Both halves must rest on the recorded run matrix, not on mechanism
  theory (every theory-first candidate in P29 was falsified).
* Must work at the lock screen (the lived scenario includes locked
  wakes).
* No new resident actors or privileges; fail quiet on any uncertainty.

## Considered Options

* **Marker-gated displaysleep cycle at wake-settle** (chosen).
* Reconfiguration-flag keying (`0x133e` flap vs `0x111e`).
* Below-CG state polling (`DCPPowerState`, `NormalModeActive`, ioreg).
* Unconditional recovery on every wake-with-external.
* `extcycle` (CG disable/re-enable of the external) as the recovery.
* IOMobileFramebuffer HPD notifications as the detector.
* OSLogStore instead of spawning `log show`.

## Decision Outcome

Chosen: **marker-gated displaysleep cycle at wake-settle**, because it
is the only detector that survived n ≥ 3 validation (56/56 vs 0/33)
paired with the only recovery that cleared every recorded black,
locked and unlocked.

At `wakeSettleTimerFired` (the ADR-0003 quiet point), when an external
display is present, the daemon:

1. queries the unified log for the coalescing marker over a window
   opening 30 s before the recorded wake, by spawning
   `/usr/bin/log show --predicate …` (the same unprivileged path
   `diagnose` uses) off the main queue;
2. if — and only if — the marker is present, runs the display-sleep
   cycle;
3. logs the verdict either way (`[wake] recovery=… marker=…`).

The behavior is gated by a `recoveryStrategy` NSUserDefaults key
(String; default `displaysleep`, `none` disables, unknown values fall
back to `none`), settable live via `blackoutd recovery
<none|displaysleep>` (SIGHUP reload, same pattern as `verbosity`).

Guard rails: a once-per-wake latch (the settle timer re-fires on
err=1014 retries), a `_systemSleeping` re-check after the query, and
the fact that a display-sleep cycle emits screen — not system — sleep
notifications, so it cannot re-arm the wake path and loop.

### Consequences

* Good, because recovery is targeted: healthy wakes (marker absent) see
  no flicker at all, and black wakes recover in seconds without user
  action, including at the lock screen.
* Good, because both halves are validated at n = 56 + 33 rather than
  inferred from a mechanism theory.
* Bad, because the detector is the *wording of a private SkyLight log
  line*, pinned to macOS 26 behavior. A macOS update can silently break
  detection. Mitigation: absence is always treated as clean-or-unknown
  (fail quiet, never fail loud), the daemon logs the verdict every wake
  so a broken detector is visible in the log, and the repro matrix
  remains the revalidation loop after OS updates.
* Bad, because the recovery blinks both panels (display sleep is
  global). Accepted for now; a flicker-free, external-only action is
  the follow-up (candidates: `IOMobileFramebufferRequestPowerChange`,
  BetterDisplay's `_reinitializeOnWake` approach — see P29).
* Bad, because matrix data collection now requires `blackoutd recovery
  none` first, or captures record the recovered panel (documented in
  the matrix how-to).

### Confirmation

Live-validated on the target hardware (matrix runs 106–107): with
`recoveryStrategy displaysleep` active and no repro-side recovery, a
soft-trigger black wake cleared to E0/B0 before the post-wake capture
cue, and a clean wake passed through untouched — with no perceived
flicker, the cycle landing inside the wake transition.

## Pros and Cons of the Options

### Reconfiguration-flag keying (`0x133e` flap vs `0x111e`)

* Falsified 2026-05-26: a confirmed black wake reconnected at `0x111e`.
  Not a classifier.

### Below-CG state polling (`DCPPowerState`, `NormalModeActive`, ioreg)

* Dead. Role-attributed reads are identical on black and clean wakes;
  the cohort-2 diff found the normalized `dcpext` subtrees
  byte-identical between black and clean captures. The stall is not
  surfaced to ioreg.

### Unconditional recovery on every wake-with-external

* Rejected: flickers every healthy wake — the majority. The detector
  exists precisely to avoid this.

### `extcycle` (CG disable/re-enable of the external) as the recovery

* Rejected for automatic use. It clears blacks reliably **unlocked**
  (10/10) but while **locked** it fails and *induces* blacks — twice
  turning a clean wake black, once leaving the external absent from
  `CGGetOnlineDisplayList` until the next sleep/wake. Retained as a
  CLI-only experimental method.

### IOMobileFramebuffer HPD notifications as the detector

* Deferred, not rejected: private but linkable
  (`IOMobileFramebufferEnableHotPlugDetectNotifications`), and would
  observe hotplug upstream of SkyLight's coalescing with no log-wording
  dependency. Needs a validation series of its own before it can
  replace the marker query.

### OSLogStore instead of spawning `log show`

* Deferred. In-process and structured, but its system-scope access
  rights for a user LaunchAgent are unverified, while `log show` is
  proven unprivileged on this machine by every diagnose bundle. Revisit
  if the spawn ever becomes a problem (one ~1 s spawn per wake today).

## More Information

* `docs/debug/cursor-on-black-matrix.md` — the run-sheet matrix this
  decision rests on (runs 1–104, tallies and per-run eyewitness data).
* technical-debt P20 (recovery gap, hypotheses) and P29 (mechanism,
  falsifications, the 2026-07-19/20 update trail).
* ADR 0003 — the wake-settle quiet timer this recovery hangs off.
