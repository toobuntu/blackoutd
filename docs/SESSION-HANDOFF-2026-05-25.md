<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
SPDX-License-Identifier: GPL-3.0-or-later
-->

# blackoutd session handoff — 2026-05-25

Continuation prompt for a fresh session. Purpose of this work: tighten
correctness of the display stack by following empirical data, and challenge
documentation/conclusions that may rest on unverified assumptions.

> **Reading this in Claude Code (or any agent that can run the repo)?** The
> "How to work with this maintainer" bullets below describe *this chat
> session's* constraints — the can't-compile limitation and the Filesystem-MCP
> `dryRun` edit flow do **not** apply to you. Your workflow is governed by
> `AGENTS.md`: you can run `make` / `clang-format` / `clang-tidy` / `git`
> directly and use `worktrees/`. Everything else here — system under test,
> findings, the `0x133e` signature, build plan, capture inventory — applies
> unchanged. No separate Claude Code handoff exists or is needed.

## How to work with this maintainer

- **Be a partner, not a yes-man.** Push back with evidence; flag guesses
  explicitly; never confabulate. Data over recollection, including over the
  repo's own docs.
- **In this chat session, Claude cannot run anything on the Mac** (does not
  apply to Claude Code — see the callout above). It reads/edits files via the
  Filesystem MCP (`edit_file` with `dryRun:true` first, then apply; the matcher
  needs exact text — re-read after the maintainer runs `clang-format`). The
  maintainer runs all builds/tests and captures bundles.
- **Pre-commit ritual (maintainer runs):** `xcrun clang-format -i --Werror
  src/*.m`, then `clang-tidy`, then `make dev` (rebuilds `build/blackoutd` and
  reboots the LaunchAgent; `/usr/local/bin/blackoutd` goes stale — use
  `./build/blackoutd`). Memory/preferences are NOT enabled, so Claude cannot
  persist anything between sessions except by writing files like this one.
- **Code style:** Obj-C here; ksh93/bash/Ruby elsewhere. BSD/macOS utilities
  only (no GNU extensions). **Long options where supported** (`grep
  --fixed-strings`, `grep --extended-regexp`, not `-F`/`-E`). en_US spelling.
  Minimal comments (self-documenting), no first person in comments. GPL-3.0-or-
  later + REUSE (`reuse annotate`, never hand-write SPDX). Atomic commits, ≤50-
  char subject, `Closes #NNNN` in body. Propose commit decomposition when
  changes are ready.

## System under test

- MacBook Air M2 (Mac14,2), macOS 26.5.0 Tahoe. Single **Dell SP2309W**
  (vendor 0x10AC, product 0xD01D, native 2048×1152 @ 60 Hz) via USB-C→HDMI.
- Normal mode: lid **closed during sleep, opened on wake**; built-in blacked
  out so the external is the sole display. Idle display-sleep: 2 min on
  battery, 10 min on AC; password required only 5 min after display-off.
- Three repos under `~/devel/claude/desktop/`: **blackoutd** (Obj-C menubar
  LaunchAgent that blacks out the built-in when an external connects; owns the
  CGDisplayReconfiguration callback, a 2 s wake-settle quiet timer, and a CG
  recommit), **inject_edid** (CLI fixing the SP2309W YCbCr color cast), and
  **displayrecommitd** (standalone origin of the recommit pattern).

## The bug: "cursor-on-black"

On wake, the external comes up black with only the hardware cursor; recovered
by a hot-corner display sleep (or idle display-off, or on battery a system
sleep) + input. Intermittent.

## What is committed (build v0.2.0-25-g3e12647-dirty as of handoff)

- **`diagnose` subcommand** (replaced `--config`). Writes a bundle to
  `/tmp/blackoutd-diag-<stamp>/`: `config.txt` (daemon state, **lid** via
  `AppleClamshellState`, **power** via `pmset -g batt`, displays, build
  provenance + CLI/daemon mismatch warning, system_profiler), `version.txt`,
  `daemon-log.txt` (tail 500), `system-log.txt`, `windowserver.txt`
  (WindowServer + displaypolicyd, `--debug --info`), `sleep-wake.txt` (pmset),
  `ioreg.txt` (IODisplayConnect + dcpext). **Self-bounding window**: parses the
  daemon log's `[sleep]`/`[wake]` markers, anchors `--start` on the *incident*
  wake (most recent wake after a >60 s sleep) − 90 s and `--end` at the most
  recent wake + 90 s. Override: `--minutes N` or `--start "T" --end "T"`.
- **(A) wake-path fix** (`AppDelegate.m`, commit `Run wake-settle flow on
  disconnect path`): `systemDidWake:` no longer early-returns on the
  disconnected-during-sleep path, so `handleSystemWake` (settle timer →
  post-settle recommit + P0 re-blackout) runs on every wake. This fixes the
  **convergence bug** (built-in left un-blacked-out with external present —
  "both active"). It does NOT fix cursor-on-black.
- **Docs:** `docs/technical-debt.md` **P28** (early-return/convergence +
  corrections: err=1014 retry now fires; Alt Mode dropout unobserved) and
  **P29** (cursor-on-black flap→missing-mode hypothesis).

## Key empirical findings (2026-05-25) — these supersede older doc claims

1. **No Alt Mode "+30 s dropout" observed.** ADR 0003 / P2 / the
   displayrecommitd README describe a USB-C Alt Mode dropout ~30 s after wake.
   None of the 2026-05-25 captures show it. Treat as *hypothesized*, not
   established.
2. **The CG recommit is a no-op and does not recover cursor-on-black.**
   blackoutd's and displayrecommitd's recommits are identical
   (`CGBeginDisplayConfiguration`/`CGCompleteDisplayConfiguration(…,
   kCGConfigureForSession)`, nothing changed between). In `-192959` it fired at
   +3 s and black persisted ~129 s. "Recommit recovers it" is unproven and
   mechanically cannot install a mode.
3. **Convergence bug ≠ cursor-on-black.** They are independent. (A) fixes the
   former. `-155349` had cursor-on-black on the *normal* path; `-170616` was
   clean on the *buggy* early-return path.
4. **Candidate signature + root cause (P29).** Black wakes show the external
   re-attaching with `flags=0x133e` (`add|remove|enabled|disabled` — a coalesced
   down-then-up "flap"); clean/recovered wakes show `0x111e` (`add|enabled`, no
   remove) or no external event. In `-192959` WS, the black wake ran **no
   `[ Display:Mode ]` enumeration** for ~47 s (just `…failed to move window…
   (invalid)` / `_CGXPackagesSetWindowConstraints: Invalid window`), while the
   recovery ran a full mode block ("set to previous mode 27", `2048×1152
   fmt:YCbCr444_10bit`). Hypothesis: the flap re-enumerates the external
   *without a valid mode-set* → configured-but-not-scanning-out → black. Matches
   the maintainer's "always comes back at a wrong mode." **(2026-05-26: FALSIFIED twice. (a) The `0x133e` flap correlation — `-001343`
   was black at `0x111e`. (b) The missing-mode mechanism itself — `-001343`'s WS
   shows the black wake fully set up (`set to previous mode 27`, framebuffer
   found, `current == preferred`), indistinguishable from clean/recovery wakes.
   The black is below CoreGraphics (DCP/scanout); no CG-layer fix can see or fix
   it. See P29.)**

## Preferred fix direction (unbuilt)

**Superseded 2026-05-26 (see P29).** The mode-set idea is dropped: `-001343`'s WS
shows the black wake already at the preferred mode (mode 27), so a CG mode-set is
a no-op. The black is below CoreGraphics, so the only evidenced recovery is a
DCP-level display-power cycle (hot-corner equivalent; `IODisplayWrangler`
`IORequestIdle` — private; or `pmset displaysleepnow` — sudo; both flicker). A
plain `CGDisplaySleep`/`Wake` may not reach deep enough (the natural wake already
toggles `power state 0→1` without recovering). Detection is the open problem —
blackoutd has no CG-visible black signal, so it would flicker every wake or need
a below-CG (`dcpext`) scanout property.

## Next steps (in order)

1. **(Done — signature falsified.)** `-001343` is black at `0x111e`, so the
   reconfig flag is not a classifier. Use the deterministic repro instead:
   `sudo pmset schedule wake "$(date -j -v+15S "+%m/%d/%y %H:%M:%S")"; pmset
   sleepnow; sleep 90; ./build/blackoutd diagnose`.
2. **Validate the `dcpext DCPPowerState` detector** (below-CG black signal,
   found 2026-05-26). Same-wake ioreg diffs show external `dcpext`
   `DCPPowerState` 0 (black) → 4 (recovered) in BOTH controlled pairs
   (`-001343`/`-001426`, `-015528`/`-015648`), plus `DCPPowerAssertionCount`
   0→1. But `-085729` (active) read 0 and `-093747` (black, mid-saga) read 4 —
   capture-instant / DPMS-powersave confounds. Capture *at the black instant*
   with on-screen state recorded, repeatedly, to confirm 0⇔black / 4⇔rendering.
   Surface `dcpext` `DCPPowerState` / `DCPPowerAssertionCount` in `diagnose`.
3. **Recovery (maintainer's call): power-cycle only-when-black if the detector
   validates; otherwise unconditional on every wake-with-external.** Levers,
   strongest-bet first: reuse blackoutd's own `applyEnable:`
   (`CGSConfigureDisplayEnabled`) as a disable→enable *cycle* on the external
   (sequence so the built-in is never the only display left off); `pmset
   displaysleepnow` (sudo, flicker — did eventually recover in the `-093747`
   saga); `IODisplayWrangler IORequestIdle` (private). All flicker; a plain
   `CGDisplaySleep`/`Wake` likely won't reach the DCP. The fix must handle
   EITHER display — role reversal observed (`-093747`: built-in went black too).
4. **Disable the g26 late recommit** (remove `scheduleLateRecommits` / empty
   `kOffsets`) — tested negative. A `blackoutd recommit` CLI is low value (the
   recommit is a no-op early and late).
5. **inject_edid `--mode` reader** (connection mode / pixel encoding; external
   is YCbCr444_10bit) — now also the natural home for reading `dcpext`
   `DCPPowerState` for detection. Surface in `diagnose` first.

## Implementation spec (for Claude Code)

Three deliverables. Build in this order; A unblocks validation of any detector.

**A. `diagnose`: report the external DCP state + an observed-state note.**
- Add `dcp.txt` (or a section) recording, for the *external* display: the DCP
  node's `DCPPowerState`, `DCPPowerAssertionCount`, and which `AppleDCPExpert`
  it is. Do NOT read by position — there are two `AppleDCPExpert` nodes
  (built-in + external). Identify the external by the display (EDID UUID begins
  `10AC1DD0…`; vendor 0x10AC, product 0xD01D for the SP2309W) and walk to its
  DCP, or match the `dcpext` service and confirm it is the external. Record
  both DCPs labeled, so the value is unambiguous.
- Add `diagnose --note "…"` that writes the operator's observed on-screen state
  into the bundle (e.g. `note.txt`). This pairs the register with ground truth
  so the detector can finally be validated.
- The CG-layer view (mode 27 == preferred, framebuffer found) is identical for
  black and rendering (P29), so do not bother adding more CG mode dumps.

**B. Recovery behind a pref (strategy enum), invoked at `wakeSettleTimerFired`.**
- Pref key e.g. `recoveryStrategy` ∈ {`off` (default, current behavior),
  `cg-cycle`, `display-cycle`}. No reliable black detector exists yet (the
  `DCPPowerState` signal is unvalidated — see P29 correction), so for now the
  chosen strategy fires *unconditionally* on every wake-with-external, after
  the settle. Wrap it so a later detector can gate it.
- `cg-cycle`: reuse the existing `applyEnable:` primitive
  (`CGSConfigureDisplayEnabled`) as disable→(brief)→enable on the target
  display. CHEAP, low-disruption, but CG-level — may not reach the DCP (the
  natural wake already toggled `power state 0→1` without recovering, so expect
  this may be insufficient).
- `display-cycle`: a DCP-level display-power cycle (the lever the hot corner /
  `pmset displaysleepnow` exercises, which DID recover). More likely to work
  because the failure is below CG; more disruptive (blanks displays). This is
  the technically-correct bet — wire it so it can be A/B'd against `cg-cycle`.
- Role reversal (P29): the dark display may be the BUILT-IN, not the external.
  Target whichever display is dark, or cycle both; never leave zero displays
  enabled mid-cycle (restore/keep the built-in during an external cycle).
- Safety invariant unchanged: built-in restored when the last external
  disconnects.

**C. Disable the g26 late recommit** — remove the `scheduleLateRecommits` call
(or empty `kOffsets`). Tested negative; it only adds noise.

Reading needed: `src/DisplayController.m` (`applyEnable:`,
`recommitDisplayConfiguration`, `wakeSettleTimerFired`, the `diagnose` path),
`src/AppDelegate.m` (signal wiring), and the `diagnose` collector. The repro is
in `docs/debug/REPRO.md`.

## Capture inventory (`docs/debug/`)

- `-122138`, `-135711`: lid-closed, disconnected-during-sleep path, black,
  ended both-active (convergence bug, pre-(A)).
- `-150108`: black + err=1014 storm during dark-wake/re-sleep thrash; built-in
  restored mirror-primary=external.
- `-155349`: lid-open sleep, normal path, recommit fired, **still black**,
  hot-corner recovered. Proves recommit insufficient.
- `-170616`: lid-closed, old daemon, **clean** (no black) — intermittency.
- `-192959`: build g24, black wake `0x133e` + no Display:Mode for ~47 s;
  recovery wake `0x111e` + full mode block. Added WS log
  `ws-20260525-201956.log` spans the black wake. Best root-cause evidence.

## Reading list for a fresh session

`docs/technical-debt.md` (esp. P0, P1, P2, P20, P25, P28, P29);
`docs/decisions/0003-wake-settle-quiet-timer.md`, `0009-sp2309w-color-quirk.md`;
`src/main.m`, `src/AppDelegate.m`, `src/DisplayController.m`;
`../displayrecommitd/{displayrecommitd.m,README.md,CLAUDE.md}`.

## Update — 2026-05-25 (later)

**Signature FALSIFIED (superseded 2026-05-26).** Earlier this looked like
black ⇔ `0x133e` flap / clean ⇔ no flap (black: 122138, 135711, 150108, 155349,
192959, 212847; clean: 170616, 213717). `-001343` then came up black at `0x111e`
— a counterexample. The flap is not the discriminator; the missing-mode
mechanism is flag-independent. See the tally at the end. `-213717` also confirms (A): restore → settle →
recommit → re-blackout → `isBlackedOut=1`, no black (AC).

**Recommit overclaim corrected**: do NOT assert the CG recommit is insufficient
in all cases. It only failed to recover in two *early*-fired captures
(`-155349`, `-192959`). It was brought into blackoutd because it was believed
to recover some occurrences (`docs/architecture.md`, ADR 0003, the
displayrecommitd repo, `displayrecommitd/scripts/displayprobe2.m`). A *late*
recommit is untested. Keep open in both directions.

**IOServiceRequestProbe is a known dead end** (`AGENTS.md`): on
`DCPDPDeviceProxy` it returns `kIOReturnUnsupported` (`0xe00002c7`) on Apple
Silicon — do NOT propose it as recovery. `displayprobe2.m` remains useful only
for its `dcpext` discovery recipe (`IOServiceMatching("DCPDPDeviceProxy")` +
IOService path containing `dcpext`; built-in is `dcp` without suffix) that a
`--mode` reader can reuse to locate the external controller. `AGENTS.md` also
lists `CGDisplaySleep`/`CGDisplayWake` and `pmset displaysleepnow` as flicker
dead ends, and battery-at-sleep as a coincidental (non-causative) predictor.
Realistic untried recovery candidates are just two: a *late* recommit and an
explicit `CGConfigureDisplayWithDisplayMode` mode-set.

**SP2309W EDID defect (ADR 0009 / inject_edid; see
`inject_edid/docs/sp2309w-display-notes.md`).** The panel is a 2008 8-bit RGB TN,
native 2048×1152. Its EDID is *defective*: block 0 says RGB, but the CTA-861
extension wrongly advertises YCbCr 4:4:4/4:2:2 + consumer-TV formats, so a PC
host negotiates YCbCr — which this monitor has no mode to decode and renders as
shifted RGB (pink cast; the YPbPr OSD gives green instead). A 2010 unit shipped a
corrected RGB-only EDID; there is no firmware update for this one, so correction
stays host-side. Correct connection mode: `encoding:rgb+range:full+bpc:8`;
10-bit wastes bandwidth and the monitor rejects it. The cast is *triggered by
DDC* renegotiation (Lunar, MonitorControl, BetterDisplay); MonitorControlLite
avoids DDC and does not trigger it — which is why blackoutd + MonitorControlLite
shows no cast. **This whole matter is orthogonal to cursor-on-black**: the
`fmt:YCbCr444_10bit` in the `-192959` recovery-wake WS log is just the
bad-EDID-driven negotiated encoding, not the cause of the black (the *absence*
of a mode-set). Keep the two investigations separate; do not call YCbCr
"usable/fine" on this panel.

## Build plan (maintainer approved all three)

1. **Automatic late recommit — DONE + TESTED NEGATIVE** (`DisplayController.m`
   `scheduleLateRecommits`). g26 capture `-223301`: the settle recommit plus all
   four late recommits (settle+5/15/30/60 s) logged `ok`, external stayed black
   ~66 s until a hot-corner power cycle recovered it. Recommit is insufficient
   early AND late. Action: one more confirming black capture, then DISABLE
   (remove the `scheduleLateRecommits` call / empty `kOffsets`) and move to the
   mode-set. See P29 "Update (g26)".
2. **Mode-set fix — DROPPED (predicted no-op).** `-001343`'s WS shows the black
   wake already at `current == preferred` mode 27, so
   `CGConfigureDisplayWithDisplayMode` changes nothing. Black is below
   CoreGraphics; the only evidenced recovery is a DCP-level display-power cycle
   (hot-corner equivalent), flicker accepted — but a plain
   `CGDisplaySleep`/`Wake` may not reach deep enough (the natural wake already
   cycles `power state 0→1`). Detection is unsolved: blackoutd has no CG-visible
   black signal, so it would either flicker every wake or need a below-CG
   (`dcpext`) scanout property. See P29.
3. **`blackoutd recommit` CLI** — now LOW value (recommit shown insufficient
   early and late); build only if a manual one-shot is still wanted.
4. **diagnose `--mode` reader** — still useful: pixel-encoding/mode via the
   `dcpext` IOService (displayprobe2 discovery recipe; find the key in
   `ioreg.txt`). Surface in `diagnose`; first piece of inject_edid convergence.

Reading needed before building: `src/DisplayController.m` (the recommit method
`recommitDisplayConfiguration`, the wake-settle timer, `applyEnable`) and the
`src/AppDelegate.m` signal-handling section.

**Where to continue**: items 2–3 are build/test/commit work — best done in
Claude Code, which can run `clang-format`/`clang-tidy`/`make dev`/`git`
directly and iterate (removing the round-trip friction of the chat +
Filesystem-MCP setup, where Claude cannot compile). Point it at `AGENTS.md`,
`docs/technical-debt.md` (P28/P29), and this file first. Keep a chat session
for analysis-heavy turns (classifying captures, challenging docs) if preferred.

**Signature tally (running)**: black (maintainer-observed) `-122138`,
`-135711`, `-150108`, `-155349`, `-192959`, `-212847`, `-222732`, `-223301`,
`-225050`, `-001343`, `-015528`; clean `-170616`, `-213717`, `-220028`, `-222940`,
`-224742`, `-230242`, `-001426`, `-015648`. Self-recovered / active: `-085729`
(long lid-closed sleep, Apple-Watch unlock, external became active). Saga
(battery, role reversal): `-093747` (programmatic, black/powersave) / `-093819`
(manual, recovered). **Counterexample: `-001343` was black at
`0x111e`** (2026-05-26) — the flap signature is falsified; the reconfig flag
does not separate black from clean. Late recommit confirmed insufficient by
`-223301` (flap at 22:31:30, all recommits fired, black persisted ~66 s,
hot-corner recovered) and corroborated by `-225050`. **Classify per-wake, not
by grep**: each bundle's `daemon-log.txt` is a cumulative `tail -500` across
pids/incidents, so grepping it for `0x133e` finds residual flaps from earlier
incidents (the `-223301` flap rides along in `-224742` / `-230242`). Verified
`0x111e` at own wake: `-220028`, `-222940`, `-224742`, `-230242`, and
`-001343` (black anyway). `-213717`/`-220028`/`-222940` also re-confirm (A).
