<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Cursor-on-black empirical test matrix

Structured data collection for the external-display "cursor-on-black" failure
(`docs/technical-debt.md` P20 / P29). The goal is to pair each machine-captured
bundle with the maintainer's eyewitness panel observation — the one signal the
daemon cannot see — so black vs. rendering captures can be diffed field by
field, and the display-sleep recovery can be confirmed or falsified.

**Ground every conclusion in these recorded runs, not in recollection or a
prior summary.** A claim that lands in `technical-debt.md` must cite run rows
here.

Prerequisite: the **external display must be attached** (this is an
external-display bug). Build the binary first: `make` → `./build/blackoutd`.
The captures drive the CLI only, so the resident daemon need not be
restarted; still, one `make dev` before a session (restarts the agent)
aligns the daemon's build stamp with the CLI so `config.txt` does not warn
about a CLI/daemon mismatch. A per-run `make dev` is **not** needed —
rebuild only when sources change. Every repro-generated sheet and its
terminal header carry the git describe **and the build time**, so a
rebuild between runs is visible even when both stamps say `-dirty`
(backfilled sheets for runs 1–8 predate this and lack a recorded build
time; their bundles' `version.txt` is authoritative).

## How to run one trial

From a terminal with the panels visible (before sleep):

```sh
sudo --validate   # primes sudo so the schedule-wake step never prompts
                  # (repro falls back to one pre-sleep prompt if it must)

# Baseline (detection): wake, capture, no recovery. Group A of the
# coverage table below.
./build/blackoutd repro --wake 15 --group A

# With recovery: wake, capture, display-sleep cycle, capture again.
./build/blackoutd repro --wake 15 --recover displaysleep --group B
```

To emulate the C1 cable trigger in software (no cable handling), add
`--trigger extcycle`: after scheduling the wake and before sleeping,
`repro` disables the external display via CG, waits 5 s for the
built-in to restore and redraw (the daemon's safety invariant does the
restore), re-enables it, and waits 5 s for the re-attach — then sleeps
as usual. The sheet's `trigger` field records it, so soft-trigger runs
are machine-distinguished from physical `C1` runs (which stay a Notes
code).

`repro` schedules the wake (the only step that needs `sudo`), sleeps, and on
wake **speaks each step** (`say`) so you can follow it with the screen black.
Each step also posts a Notification Center banner stamped `HH:mm:ss` —
invisible during the black, but retained, so after recovery the notification
log shows when each stage ran and pairs with the bundles' timestamps.
Watch the **panels**, not the terminal. When you hear:

- **"capturing post wake"** — look at both panels, fill the *post-wake* rows.
- **"recovering"** then **"capturing post recover"** — look again, fill the
  *post-recover* rows.

Each capture writes `/tmp/blackoutd-diag-<stamp>/` with a `label.txt`
(`post-wake` / `post-recover`). Flags: `--group G` (coverage row A–E,
any case — normalized to lowercase, recorded in the sheet and as a
`grp-<g>` filename tag), `--settle S` (seconds before each capture,
default 20), `--no-copy` (keep bundles in /tmp only), `--no-prompt`
(skip the eyewitness prompts), `--silent` (no speech — mind that the
spoken cues are most of the point of a blind run), `--dry-run` (preview
without sleeping).

`repro` also emits a prefilled, numbered **run sheet** at
`docs/debug/repro-matrix/runNNN-grp-<g>-<stamp>.md` (NNN = 1 + the
highest existing sheet number, global across groups; stamp = repro
start; falls back to `/tmp`, unnumbered, when not run from the repo
root; without `--group` the filename omits the grp tag and the sheet
leaves the group as a manual field). Machine-filled: run number,
group, start time, build identity, both bundle paths, the daemon's
`[wake] — display pipeline settled` marker (timestamp-checked against the
repro start, so a stale marker from an earlier wake is never reported),
and each condition repro can read — lid, session lock, and power source,
captured **twice** (pre-sleep and again at capture time) so both ends of
the run are on record.

The three fields no machine can read — the eyewitness panel states,
whether the lid moved *during* sleep, and notes — are **prompted for
interactively** after the all-clear cue, in plain language (no E/B
shorthand to memorize); answers are written into the sheet, and the
Outcome line is derived from the settled-external answer. Enter skips
any one question. The **first** question times out after 60 s: if you
are staring at a black panel and cannot see the terminal, the prompts
abandon themselves and the sheet stays blank for manual fill — the
bundles and sheet are already on disk by then. (Recovery safety is
announced *before* the prompts, by the all-clear cue — on every run
shape.) A further spoken cue, **"prompts timed out, sheet left
blank"**, marks the answer window closing, so away from the terminal
you know there is no need to hurry back. `--no-prompt` (or a
non-interactive stdin) skips the pass entirely.

Unless `--no-copy` is given, the finished bundles are also copied into
`docs/debug/` (`/bin/cp -pR`) — /tmp does not survive a reboot, and
sleep/wake testing is where reboots happen — and the sheet's bundle paths
point at the repo copies. The final spoken cue — **"collection complete,
safe to recover"** on a baseline run (**"repro complete"** with
`--recover`) — fires only after the sheet and copies have landed: until
you hear it, a manual hot-corner recovery would contaminate the run.

> **Intermittent.** Not every run goes black. Repeat the baseline; record
> **every** run — clean runs are the controls the diff needs.
>
> **To test while LOCKED**, prevent auto-unlock for that run (remove the Apple
> Watch / step out of range / disable TouchID), so the session stays locked
> through the capture and recovery.

## Observation legend (check one per panel, per moment)

Record each panel at **two moments** — the states often differ (a run may
open B2/E2 and settle to B0/E1 within seconds):

- **@ wake (immediate)** — the first look as the panels light. Documents
  the transition (e.g. a role reversal, or blackout re-asserting).
- **@ post-wake capture (settled)** — at the "capturing post wake" cue.
  **This is the state the bundle records**, so it is the one that
  classifies the run for detection diffing; the Outcome line keys on it.

**External panel**
- `E0` — desktop/content rendering normally
- `E1` — cursor-on-black (black field, only the mouse cursor)
- `E2` — black, no cursor
- `E3` — no signal / "no input" / off

**Built-in panel** (intended state while blacked out = dark)
- `B0` — dark/off (correct blackout)
- `B1` — lit, cursor-on-black (role reversal — wrongly active)
- `B2` — lit, showing desktop/content (blackout not holding)

**Notes short codes** (used in the sheets' Notes field from run 46 on):

- `R0` — no recovery needed (the run settled clean; the group B/C
  displaysleep cycle ran anyway but had nothing to clear)
- `M1` — Music.app playing during the run
- `C1` — pre-run cable trigger: the external's **USB-C end** of its
  USB-C → HDMI cable was unplugged from the MacBook and replugged
  *before* the run, leaving it unplugged until the built-in fully
  redrew. Mostly (not completely) reliably provokes cursor-on-black
  on the following wake — the first on-demand repro lever (found run
  49; missed on run 55).

> **Built-in immediate-state caveat (2026-07-19).** The built-in
> panel is small and glare-prone, and a cursor is easy to miss — it
> is possible that all role reversals are *full* inversions
> (immediate `E2/B1`) and that some earlier records under-report the
> built-in as `B0`/`B2` because the cursor went unseen. From run 54
> the maintainer pre-positions the cursor near the top of the screen
> and observed the full `E2/B1` inversion directly on runs 54, 56,
> and 57. Treat pre-54 *immediate built-in* states as approximate;
> settled states and Outcome lines are unaffected.

## Per-run record

`repro` generates this block prefilled (the `<machine>` fields) in the run
sheet; fill in the rest there. The group sections below index the sheets.
For a trial run without `repro`, copy the block by hand.

```text
Run #: <machine: NNN>    started: <machine: yyyy-MM-dd HH:mm:ss>
Build: <machine: git describe>    built: <machine: build stamp> (UTC)

Conditions (pre-sleep -> at capture):
  group .................. <machine: A..E from --group (any case), else manual>
  lid .................... <machine: open|closed -> open|closed>
      moved during sleep? ... [ ] no   [ ] yes: ______
  session ................ <machine: locked|unlocked -> locked|unlocked>
  power .................. <machine: battery|AC -> battery|AC>
  wake ................... <machine: scheduled (--wake N) | manual (--wake 0)>
  trigger ................ <machine: none | extcycle (--trigger)>
  recovery applied ....... <machine: none | displaysleep | extcycle>
  settle ................. <machine: N s>
  daemon settled ......... <machine: settle-marker log line, this run only>

Bundles:
  post-wake    = <machine: docs/debug/blackoutd-diag-... | /tmp/...>
  post-recover = <machine: docs/debug/blackoutd-diag-... | /tmp/... | n/a>

@ wake (immediate — first look as the panels light):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2

@ post-wake capture (settled — at the "capturing post wake"
                     cue; the state the bundle records):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2

@ post-recover capture (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [ ] yes   [ ] no
      (yes = settled external E1; note E2/E3 variants in Notes)
Notes: ____________________________________________________________________
```

**Notes field** — anything the checkboxes cannot express:

- transition timing and order (`B1/E2 on wake, ~2 s -> B0/E1`);
- manual interventions and when (hot-corner recovery, unlock, keypress);
- anomalies (flicker, pink cast, menu-bar icon state, missing `say` cue);
- procedure deviations (moved the lid, touched input before the capture
  cue, sudo prompted mid-run);
- anything odd in the bundle or the Notification Center timestamps.

## Suggested coverage (challenge the priors)

Run group A until you have **≥3 black and ≥3 clean** captures; then B–E.
Stop a group once its question is answered or it reproduces consistently
(n ≥ 2).

| group | wake          | session  | power   | recovery     | question it tests                         |
|-------|---------------|----------|---------|--------------|-------------------------------------------|
| A     | scheduled     | unlocked | battery | none         | detection: what field splits black/clean? |
| B     | scheduled     | unlocked | battery | displaysleep | does the display-sleep cycle clear it?    |
| C     | scheduled     | **locked** | battery | displaysleep | does recovery work while locked?          |
| D     | scheduled     | unlocked | **AC**  | displaysleep | challenge "not power-dependent" (P29)      |
| E     | **manual lid-open** | unlocked | battery | displaysleep | the lived scenario vs. the scheduled repro |

### Group A

Runs 1–8 were recorded inline here before the run-sheet workflow existed
and were converted to backfilled sheets under `repro-matrix/` — same
data, new layout, with both moments recorded. Immediate/settled
attribution per the maintainer: runs 1, 2, 4, 6 had checked the settled
state (transition in Notes; run 1's `B2/E2 -> B0/E0` supplied after the
fact); runs 3, 5, 7, 8 had checked the immediate state.

| run | sheet                                            | immediate E/B | settled E/B | black? |
|-----|--------------------------------------------------|---------------|-------------|--------|
| 1   | [run001](repro-matrix/run001-grp-a-20260716-013347.md) | E2/B2         | E0/B0       | no     |
| 2   | [run002](repro-matrix/run002-grp-a-20260716-014527.md) | E2/B2         | E0/B0       | no     |
| 3   | [run003](repro-matrix/run003-grp-a-20260716-015013.md) | E2/B1         | E1/B0       | yes    |
| 4   | [run004](repro-matrix/run004-grp-a-20260716-020245.md) | E2/B2         | E0/B0       | no     |
| 5   | [run005](repro-matrix/run005-grp-a-20260716-020540.md) | E2/B1         | E1/B0       | yes    |
| 6   | [run006](repro-matrix/run006-grp-a-20260716-020824.md) | E2/B2         | E0/B0       | no     |
| 7   | [run007](repro-matrix/run007-grp-a-20260716-021316.md) | E2/B1         | E1/B0       | yes    |
| 8   | [run008](repro-matrix/run008-grp-a-20260716-021755.md) | E2/B1         | E1/B0       | yes    |
| 9   | [run009](repro-matrix/run009-grp-a-20260716-122626.md) | *stricken*    | *stricken*  | —      |
| 10  | [run010](repro-matrix/run010-grp-a-20260716-134416.md) | E2/B2         | E0/B0       | no     |

Runs 9–10 were `--silent` runs on the run-sheet build (observations
filled in manually). **Run 9 is stricken**: the maintainer is unsure
its observations were recorded correctly, and its claimed instantly
clean wake (immediate E0/B0) appears in no other run — its bundle
remains for machine-side reference only.

**Cohort 1 — superseded for analysis.** Runs 1–10 predate the finished
tooling: 1–8 were recorded in the pre-split format and their
immediate/settled attribution was reconstructed after the fact (twice,
for run 1); 9–10 ran `--silent`, so the eyewitness states were recalled
without cue anchors rather than prompted at the moment.
The settled classifications are otherwise well corroborated — every
black run required its manual displaysleep recovery, no clean run did —
so these sheets and bundles stay on record as corroboration: 4 black
(runs 3, 5, 7, 8), 5 clean (runs 1, 2, 4, 6, 10), 1 stricken (run 9).
But detection diffing must gate on a fresh cohort collected with the
current build (spoken cues, at-the-moment prompts, boundary-timed
condition reads, single-sample settle marker). **Cohort 2 starts at run
011 and owes its own ≥3 black / ≥3 clean settled captures before
analysis begins.**

### Group A — cohort 2 (runs 011+, v0.4.0 build)

Collected 2026-07-19 on the merged v0.4.0 build with the full
workflow. The cohort satisfies the capture gate: 3 on-condition black
(runs 14, 22, 24) and 9 clean settled captures.

| run | sheet                                                  | immediate E/B | settled E/B | black? |
|-----|--------------------------------------------------------|---------------|-------------|--------|
| 11  | [run011](repro-matrix/run011-grp-a-20260719-000924.md) | E1/B0         | E1/B0       | yes¹   |
| 12  | [run012](repro-matrix/run012-grp-a-20260719-082315.md) | E2/B2         | E0/B0       | no     |
| 13  | [run013](repro-matrix/run013-grp-a-20260719-110044.md) | E2/B2         | E0/B0       | no     |
| 14  | [run014](repro-matrix/run014-grp-a-20260719-110205.md) | E2/B1         | E1/B0       | yes    |
| 15  | [run015](repro-matrix/run015-grp-a-20260719-110325.md) | E2/B2         | E0/B0       | no     |
| 16  | [run016](repro-matrix/run016-grp-a-20260719-110439.md) | E2/B2         | E0/B0       | no     |
| 17  | [run017](repro-matrix/run017-grp-a-20260719-120552.md) | E2/B1         | E2/B0       | no²    |
| 18  | [run018](repro-matrix/run018-grp-a-20260719-120742.md) | E2/B2         | E0/B0       | no     |
| 19  | [run019](repro-matrix/run019-grp-a-20260719-120843.md) | *disregarded* | *disregarded* | —    |
| 20  | [run020](repro-matrix/run020-grp-a-20260719-120955.md) | E2/B2         | E0/B0       | no     |
| 21  | [run021](repro-matrix/run021-grp-a-20260719-121755.md) | E2/B2         | E0/B0       | no     |
| 22  | [run022](repro-matrix/run022-grp-a-20260719-121916.md) | E2/B1         | E1/B0       | yes    |
| 23  | [run023](repro-matrix/run023-grp-a-20260719-122131.md) | E2/B2         | E0/B0       | no     |
| 24  | [run024](repro-matrix/run024-grp-a-20260719-122252.md) | E2/B1         | E1/B0       | yes    |
| 36  | [run036](repro-matrix/run036-grp-a-20260719-141127.md) | E2/B2         | E0/B0       | no     |

¹ Run 11 ran on AC (group A specifies battery): a black capture kept
as corroboration, off-condition for the matched diff.
² Run 17 settled **E2** (black, no cursor) — a black panel that the
E1-keyed Outcome line scores "no". Out of both pools for the matched
diff; corroboration for the detector (its bundle sides with the
blacks).
Run 19 is disregarded (maintainer: possibly misreported); its window
is excluded from every tally.

### Group B (runs 025+)

| run | sheet                                                  | settled E/B | black? | recovery cleared? |
|-----|--------------------------------------------------------|-------------|--------|-------------------|
| 25  | [run025](repro-matrix/run025-grp-b-20260719-122426.md) | E0/B0       | no     | n/a (was clean)   |
| 26  | [run026](repro-matrix/run026-grp-b-20260719-122726.md) | E0/B0       | no     | n/a (was clean)   |
| 27  | [run027](repro-matrix/run027-grp-b-20260719-122934.md) | E0/B0       | no     | n/a (was clean)   |
| 28  | [run028](repro-matrix/run028-grp-b-20260719-131053.md) | E0/B0       | no     | n/a (was clean)   |
| 29  | [run029](repro-matrix/run029-grp-b-20260719-131252.md) | E0/B0       | no     | n/a (was clean)   |
| 30  | [run030](repro-matrix/run030-grp-b-20260719-131452.md) | E0/B0       | no     | n/a (was clean)   |
| 31  | [run031](repro-matrix/run031-grp-b-20260719-131825.md) | E0/B0       | no     | n/a (was clean)   |
| 32  | [run032](repro-matrix/run032-grp-b-20260719-132525.md) | E0/B0       | no     | n/a (was clean)   |
| 33  | [run033](repro-matrix/run033-grp-b-20260719-132720.md) | E0/B0       | no     | n/a (was clean)   |
| 34  | [run034](repro-matrix/run034-grp-b-20260719-132947.md) | E0/B0       | no     | n/a (was clean)   |
| 35  | [run035](repro-matrix/run035-grp-b-20260719-140116.md) | E0/B0       | no     | n/a (was clean)   |
| 37  | [run037](repro-matrix/run037-grp-b-20260719-141825.md) | E1/B0       | yes    | **yes**           |
| 38  | [run038](repro-matrix/run038-grp-b-20260719-142134.md) | E0/B0       | no     | n/a (was clean)   |
| 39  | [run039](repro-matrix/run039-grp-b-20260719-142353.md) | E0/B0       | no     | n/a (was clean)   |
| 40  | [run040](repro-matrix/run040-grp-b-20260719-142621.md) | E0/B0       | no     | n/a (was clean)   |
| 41  | [run041](repro-matrix/run041-grp-b-20260719-145713.md) | E0/B0       | no     | n/a (R0)          |
| 42  | [run042](repro-matrix/run042-grp-b-20260719-150121.md) | E0/B0       | no     | n/a (R0)          |
| 43  | [run043](repro-matrix/run043-grp-b-20260719-150356.md) | E0/B0       | no     | n/a (R0)          |
| 44  | [run044](repro-matrix/run044-grp-b-20260719-150606.md) | E0/B0       | no     | n/a (R0)          |
| 45  | [run045](repro-matrix/run045-grp-b-20260719-150805.md) | E0/B0       | no     | n/a (R0)          |
| 46  | [run046](repro-matrix/run046-grp-b-20260719-151024.md) | E0/B0       | no     | n/a (R0)          |
| 47  | [run047](repro-matrix/run047-grp-b-20260719-151223.md) | E0/B0       | no     | n/a (R0)          |
| 48  | [run048](repro-matrix/run048-grp-b-20260719-151427.md) | E0/B0       | no     | n/a (R0)          |
| 49  | [run049](repro-matrix/run049-grp-b-20260719-151715.md) | E1/B0       | yes    | **yes**           |
| 50  | [run050](repro-matrix/run050-grp-b-20260719-152024.md) | E0/B0       | no     | n/a (R0)          |
| 51  | [run051](repro-matrix/run051-grp-b-20260719-152300.md) | E1/B0       | yes    | **yes**           |
| 52  | [run052](repro-matrix/run052-grp-b-20260719-152718.md) | E1/B0       | yes    | **yes**           |
| 53  | [run053](repro-matrix/run053-grp-b-20260719-153031.md) | E1/B0       | yes    | **yes**           |
| 54  | [run054](repro-matrix/run054-grp-b-20260719-153227.md) | E1/B0       | yes    | **yes**           |
| 55  | [run055](repro-matrix/run055-grp-b-20260719-153508.md) | E0/B0       | no     | n/a (R0)          |
| 56  | [run056](repro-matrix/run056-grp-b-20260719-153711.md) | E1/B0       | yes    | **yes**           |
| 57  | [run057](repro-matrix/run057-grp-b-20260719-153916.md) | E1/B0       | yes    | **yes**           |

Codes on the extension runs (see legend): `M1` on runs 37–57; `C1` on
runs 49 and 51–57 (49 is where the cable trigger was discovered — its
sheet describes the unplug/replug in prose; run 55 is the C1 miss —
cable trigger applied, wake settled clean). Run 47 ran on AC; run 48's
lid was closed during sleep (no visible or audible wake until the
clamshell reopened).

Group B verdict: 8 blacks (runs 37, 49, 51–54, 56–57), and the
`displaysleep` recovery cleared **every one** end-to-end (post-recover
E0/B0) — well past the n ≥ 2 consistency bar; cohort 1's four manual
clears corroborate. The group's question is answered: yes, the
display-sleep cycle clears it.

### Group C (runs 058+) — recovery while locked

Working invocation (run 59 first; lock the session **before**
starting `repro` — run 58 chained the `osascript` *after* `repro`, so
the lock never took effect and the run executed unlocked):

```sh
sudo --validate && \
  osascript -l JavaScript -e 'Application("System Events").keystroke("q", {using:["control down","command down"]})' && \
  ./build/blackoutd repro --wake 15 --recover displaysleep --group C
```

(`ctrl-cmd-q` locks the screen; needs Accessibility permission for the
terminal app. Keep the Apple Watch off/out of range per the LOCKED
note above.)

| run | sheet                                                  | session | settled E/B | black? | recovery cleared? |
|-----|--------------------------------------------------------|---------|-------------|--------|-------------------|
| 58  | [run058](repro-matrix/run058-grp-c-20260719-154916.md) | unlocked¹ | E1/B0     | yes    | **yes**           |
| 59  | [run059](repro-matrix/run059-grp-c-20260719-155209.md) | locked  | E0/B0       | no     | n/a (R0)          |
| 60  | [run060](repro-matrix/run060-grp-c-20260719-155510.md) | locked  | E1/B0       | yes    | **yes**           |

¹ Run 58's lock keystroke ran after `repro` (see above); the sheet's
machine-read session field correctly records unlocked → unlocked, so
it is effectively a group B data point. Codes: `M1` on 58–60; `C1` on
60 — and **possibly on 58**: its Notes do not record C1, but the
maintainer later recalled the cable trigger may have been applied
there too, so do not cite run 58 as a trigger-free natural repro. Run
60 is the first **locked** black: the displaysleep recovery cleared
it while the session stayed locked (n=1; group C stays open until
n ≥ 2).

**Detection result (2026-07-19)**: the field-by-field diff over this
cohort found a WindowServer log marker that splits black from clean —
10/10 black wakes vs 0/15 clean across both cohorts, extended to
**19/19 vs 0/26** by the run 41–60 extension (including the C1-miss
run 55 and the locked runs). See `docs/technical-debt.md` P29
(2026-07-19 updates) for the diff record, mechanism reading, and
caveats.

## What we do with the data

- **Detection** — diff `dcp.txt` / `connection-mode.txt` (and the raw
  `ioreg.txt`) between `E1` (black) and `E0` (clean) captures *with matching
  conditions*. Any field that splits cleanly is a candidate detector. (So far
  every candidate — reconfig flag, DCP power state — has failed; treat new ones
  the same way until n ≥ 3 holds.)
- **Recovery** — if `displaysleep` reliably moves `E1` → `E0` across runs
  (including group C, locked), wire it into `wakeSettleTimerFired` behind a
  `recoveryStrategy` pref (a separate PR). If it fails, record the negative and
  reconsider (e.g. BetterDisplay's virtual-display reconnect — see
  `docs/reverse-engineering.md`).
- **Conditions** — A/B/D/E either confirm or retire the lid/lock/power priors.
