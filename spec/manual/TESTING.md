<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Manual Testing Checklist

These tests require a MacBook with an external display connected via USB-C.

## Basic Functionality

- [ ] `blackoutd on` blacks out built-in display
- [ ] `blackoutd off` restores built-in display
- [ ] `blackoutd status` shows running daemon and display state
- [ ] `blackoutd auto on` enables auto-blackout
- [ ] `blackoutd auto off` disables auto-blackout

## Menu Bar

- [ ] Menu bar icon shows `macbook` when built-in is active
- [ ] Menu bar icon shows `macbook.slash` when blacked out
- [ ] "Black Out Built-in Display" menu item works
- [ ] "Restore Built-in Display" menu item works
- [ ] "Auto-blackout on External Connect" toggle works
- [ ] Toggle applies immediately if external already connected
- [ ] Disabling auto-blackout restores built-in if currently blacked out

## Safety Invariant

- [ ] Unplugging external restores built-in unconditionally
- [ ] Built-in is never left as sole display in blacked-out state

## Daemon Lifecycle

- [ ] `blackoutd daemon start` bootstraps the LaunchAgent
- [ ] `blackoutd daemon stop` restores built-in before exit
- [ ] `blackoutd daemon start` after stop re-bootstraps agent
- [ ] Quit from menu bar restores built-in display

## Sleep/Wake

- [ ] Sleep with external connected, wake: auto-blackout re-engages
- [ ] Sleep, unplug external during sleep, wake: built-in restored
- [ ] Short sleep (< 1 min): auto-blackout works on wake
- [ ] Long sleep (> 8 hr): auto-blackout works on wake
- [ ] `pmset sleepnow`: auto-blackout works on wake
- [ ] Lid-close sleep: auto-blackout works on wake

## USB-C Alt Mode Wake Recovery (P2)

- [ ] Sleep with USB-C→HDMI external, wake: external recovers within 5 seconds
- [ ] No visible flicker during recovery
- [ ] Works on battery power
- [ ] Works on AC power
- [ ] External does not go black ~30s after wake (the pre-fix failure mode)

## Cursor-on-black auto-recovery (P20/P29)

The CLI argument surface for these commands is covered by
`spec/integration/cli_spec.rb`; the items below need real hardware, a
running daemon, and an eyewitness, so they stay manual. Use `blackoutd
repro` (see `docs/debug/cursor-on-black-matrix.md`) to provoke the black.

- [ ] `blackoutd recovery displaysleep` reports the value and, with the
      daemon running, notifies it (`status` then shows `recovery :
      displaysleep`)
- [ ] `blackoutd recovery none` disables auto-recovery; `status` reflects it
- [ ] With `recovery displaysleep` and an external attached, a
      cursor-on-black wake self-clears within a few seconds of settle
      (daemon log shows `[wake] recovery=displaysleep marker=present`)
- [ ] With `recovery none`, the same wake stays black (marker logged,
      no recovery issued) — the control case for data collection
- [ ] A clean wake logs `marker=absent` and does not cycle the display
- [ ] `blackoutd recover --method displaysleep` clears a black manually
- [ ] `blackoutd recover --method extcycle` clears a black in an
      **unlocked** session (do NOT run while locked — induces blacks;
      see the matrix group C notes)

## repro harness (maintainer-run)

- [ ] `blackoutd repro --wake 15 --trigger extcycle` provokes the black
      and the scheduled wake fires (no manual wake needed)
- [ ] The spoken "awake" cue lands at first light; the run sheet and
      bundles are written under `docs/debug/`
- [ ] `--lock` locks the session before sleep; the run stays locked
      through capture (keep the Apple Watch out of range)

## Build/Install Cycle

- [ ] `make clean; make; make reinstall` succeeds
- [ ] `make uninstall` removes binary and agent
