<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Cursor-on-black reproduction

Deterministic repro for the cursor-on-black DCP/scanout failure (P29 in
`docs/technical-debt.md`). Run from the repo root with `blackoutd` built.

## Current two-phase command

```sh
sudo --validate
sudo pmset schedule wake "$(date -j -v+15S "+%m/%d/%y %H:%M:%S")" \
  && pmset sleepnow && sleep 130 && ./build/blackoutd diagnose
sudo --validate
sudo pmset schedule wake "$(date -j -v+15S "+%m/%d/%y %H:%M:%S")" \
  && pmset displaysleepnow && sleep 20 && ./build/blackoutd diagnose
```

Phase 1 (system sleep -> scheduled wake) reproduces cursor-on-black on the
external with the built-in blacked out. Phase 2 (`displaysleepnow` -> wake)
tests a DCP-level display-power cycle as recovery.

`pmset schedule wake` needs `sudo`; `pmset sleepnow` / `displaysleepnow` and
`diagnose` do not. `sudo --validate` primes the timestamp so the scheduled-wake
line does not block on a password prompt mid-sequence.

## Knob rationale and tuning

- **Phase-1 `sleep 130`**: originally sized to let the four late CG recommits
  fire (settle+5/15/30/60 s) before collecting. The late recommit is tested
  negative (P29), so that wait is no longer needed. Shorten to ~15 s so
  `diagnose` fires *while still cursor-on-black*, before the external drops to
  its own DPMS powersave (which confounds any DCP power-state reading). Capture
  the black instant, not its powersave successor.
- **Phase-2 `sleep 20`**: time for the display to wake and rescan after
  `displaysleepnow`. If recovery is still settling at collection, lengthen
  slightly (~25-30 s). If measuring the wake transition, shorten.
- **Wake offset `+15S`**: enough for `sleepnow` to fully sleep before the
  scheduled wake fires; do not shrink below ~10 s.

## Recording observed on-screen state

`DCPPowerState` (and most below-CG state) is only interpretable against what was
actually on screen at capture. Until `diagnose` accepts a note argument, record
the observed state per bundle out-of-band (e.g. `cursor-on-black`,
`external-powersave-off`, `rendering`). See the planned `diagnose --note` work
in `docs/SESSION-HANDOFF-2026-05-25.md`.

## Future

Consider a `blackoutd selftest` / `repro` subcommand with configurable knobs
(wake offset, phase sleeps) so the procedure is not retyped or lost.
