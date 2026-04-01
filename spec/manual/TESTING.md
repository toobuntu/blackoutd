<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

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

## Build/Install Cycle

- [ ] `make clean; make; make reinstall` succeeds
- [ ] `make uninstall` removes binary and agent
