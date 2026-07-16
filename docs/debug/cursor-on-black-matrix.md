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
rebuild only when sources change. Every run's sheet and terminal header
carry the git describe **and the build time**, so a rebuild between runs
is visible even when both stamps say `-dirty`.

## How to run one trial

From a terminal with the panels visible (before sleep):

```sh
sudo --validate   # primes sudo so the schedule-wake step never prompts
                  # (repro falls back to one pre-sleep prompt if it must)

# Baseline (detection): wake, capture, no recovery.
./build/blackoutd repro --wake 15

# With recovery: wake, capture, display-sleep cycle, capture again.
./build/blackoutd repro --wake 15 --recover displaysleep
```

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
(`post-wake` / `post-recover`). Flags: `--settle S` (seconds before each
capture, default 20), `--no-copy` (keep bundles in /tmp only), `--silent`
(no speech), `--dry-run` (preview without sleeping).

`repro` also emits a prefilled, numbered **run sheet** at
`docs/debug/repro-matrix/runNNN-<stamp>.md` (NNN = 1 + the highest
existing sheet number; stamp = repro start; falls back to `/tmp`,
unnumbered, when not run from the repo root). Machine-filled: run number,
start time, build identity, both bundle paths, the daemon's
`[wake] — display pipeline settled` marker (timestamp-checked against the
repro start, so a stale marker from an earlier wake is never reported),
and each condition repro can read — lid, session lock, and power source,
captured **twice** (pre-sleep and again at capture time) so both ends of
the run are on record. Only three things stay manual: whether the lid
moved *during* sleep (unobservable from either end), the eyewitness
checkboxes, and notes.

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

## Per-run record

`repro` generates this block prefilled (the `<machine>` fields) in the run
sheet; fill in the rest there. The group sections below index the sheets.
For a trial run without `repro`, copy the block by hand.

```text
Run #: <machine: NNN>    started: <machine: yyyy-MM-dd HH:mm:ss>
Build: <machine: git describe>    built: <machine: build stamp> (UTC)

Conditions (pre-sleep -> at capture):
  lid .................... <machine: open|closed -> open|closed>
      moved during sleep? ... [ ] no   [ ] yes: ______
  session ................ <machine: locked|unlocked -> locked|unlocked>
  power .................. <machine: battery|AC -> battery|AC>
  wake ................... <machine: scheduled (--wake N) | manual (--wake 0)>
  recovery applied ....... <machine: none | displaysleep>
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

> **Format note — runs 1–8** predate the immediate/settled split and the
> run sheet. Checkbox attribution per the maintainer: runs 2, 4, 6
> checked the **settled** state (transition in Notes); runs 3, 5, 7, 8
> checked the **immediate** state (settled state in Notes); run 1
> recorded only the settled state. The Outcome line keys on the settled
> state throughout. Their `build:` field lacks a build time, so it
> cannot distinguish the rebuild between runs 7 and 8 (both `-dirty`);
> `version.txt` in the bundles is authoritative there.

```text
Run #: 1    date/time: 2026-07-16 01:33:47    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-013420
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [x] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [x] B0   [ ] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [ ] yes   [x] no
Notes: ____________________________________________________________________
```

```text
Run #: 2    date/time: 2026-07-16 01:45:27    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-014554
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [x] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [x] B0   [ ] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [ ] yes   [x] no
Notes: built-in active on wake and quickly blacked out (B2/E2 -> B0/E0)
```

```text
Run #: 3    date/time: 2026-07-16 01:50:13    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-015046
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [ ] E0   [ ] E1   [x] E2   [ ] E3
  built-in ... [ ] B0   [x] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [x] yes   [ ] no
Notes: B1/E2 on wake and quickly -> B0/E1, manual displaysleep recovery after capture
```

```text
Run #: 4    date/time: 2026-07-16 02:02:45    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-020315
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [x] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [x] B0   [ ] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [ ] yes   [x] no
Notes: built-in active on wake and quickly blacked out (B2/E2 -> B0/E0)
```

```text
Run #: 5    date/time: 2026-07-16 02:05:40    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-020610
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [ ] E0   [ ] E1   [x] E2   [ ] E3
  built-in ... [ ] B0   [x] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [x] yes   [ ] no
Notes: B1/E2 on wake and quickly -> B0/E1, manual displaysleep recovery after capture
```

```text
Run #: 6    date/time: 2026-07-16 02:08:24    build: blackoutd 0.3.0 (v0.3.0-28-g8640711)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-020854
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [x] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [x] B0   [ ] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [ ] yes   [x] no
Notes: built-in active on wake and quickly blacked out (B2/E2 -> B0/E0)
```

```text
Run #: 7    date/time: 2026-07-16 02:13:16    build: blackoutd 0.3.0 (v0.3.0-28-g8640711-dirty)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-021346
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [ ] E0   [ ] E1   [x] E2   [ ] E3
  built-in ... [ ] B0   [x] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [x] yes   [ ] no
Notes: B1/E2 on wake and quickly -> B0/E1, manual displaysleep recovery after capture
```

```text
Run #: 8    date/time: 2026-07-16 02:17:55    build: blackoutd 0.3.0 (v0.3.0-28-g8640711-dirty)
       (build = `./build/blackoutd --version` first line)

Conditions:
  lid during sleep ....... [ ] closed   [x] open
  wake ................... [x] scheduled (repro --wake)   [ ] manual lid-open
  session at wake ........ [ ] locked   [x] unlocked (Watch/TouchID)
  power .................. [x] battery  [ ] AC
  recovery applied ....... [x] none     [ ] displaysleep

Bundles:
  post-wake    = /tmp/blackoutd-diag-20260716-021825
  post-recover = n/a   (n/a if no recovery)

@ post-wake:
  external ... [ ] E0   [ ] E1   [x] E2   [ ] E3
  built-in ... [ ] B0   [x] B1   [ ] B2

@ post-recover (only if --recover):
  external ... [ ] E0   [ ] E1   [ ] E2   [ ] E3
  built-in ... [ ] B0   [ ] B1   [ ] B2
  recovery cleared the external? ... [ ] yes   [ ] no   [ ] partial

Outcome:
  cursor-on-black occurred this run? ... [x] yes   [ ] no
Notes: B1/E2 on wake and quickly -> B0/E1, manual displaysleep recovery after capture
```

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
