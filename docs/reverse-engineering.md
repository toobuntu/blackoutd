<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Reverse-engineering and inspection reference

Reference material for investigating private/deprecated macOS display
APIs and runtime state. The read-only tool forms below are in the
Claude Code `permissions.allow` list. Read on demand.

## Inspection and reverse-engineering tools

- `ipsw class-dump`, `ipsw dyld info`, `ipsw macho info` — extract
  Objective-C interfaces and Mach-O metadata from system frameworks.
- `otool -L`, `otool -l`, `nm -gU`, `dyld_info` — inspect binary
  linkage, exported symbols, and library references.
- `log show`, `log stream` — query the unified logging system. Filter
  by `--predicate 'process == "blackoutd"'` or `subsystem ==
  "com.apple.iokit"`.
- `pmset -g log`, `pmset -g sched`, `pmset -g batt`, `pmset -g pslog`
  — read power-management state and history. **Never** use mutating
  forms (`pmset -a`, `pmset -b`, `pmset -c`, `pmset -u`, `pmset
  sleepnow`, `pmset displaysleepnow`, `pmset schedule`, `pmset
  repeat`).
- `system_profiler SPDisplaysDataType -detailLevel mini` — display
  configuration as macOS sees it.
- `ioreg -lw0 -r -c IODisplayConnect` (and other `-c` filters) —
  IORegistry introspection for the display, USB-C, and DCP device
  proxy paths.
- `defaults read blackoutd` — inspect the daemon's NSUserDefaults
  state. Mutating forms (`defaults write`, `defaults delete`) are not
  agent-allowed; the maintainer makes those changes directly. Use
  `blackoutd verbosity <N>` for the verbosity key.
- `vmmap`, `sample`, `spindump` — process memory and call-stack
  inspection when diagnosing daemon hangs.

## BetterDisplay research

`ipsw class-dump --arch arm64 BetterDisplay` + `otool -L` revealed:

- Uses `CoreDisplay.framework` (public, undocumented),
  `DisplayServices.framework` (private),
  `IOMobileFramebuffer.framework` (private), `SkyLight.framework`
  (private).
- Key properties: `_disconnectReconnectedDisplaysAfterWake`,
  `_reinitializeOnWake`, `_reconnectAfterSleep`.
- Their wake recovery is an explicit virtual display
  disconnect/reconnect cycle, a stronger intervention than the
  CGConfig no-op used by displayrecommitd. This informs the P2 fix
  direction (see `docs/technical-debt.md`).
