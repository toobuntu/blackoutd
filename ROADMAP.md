<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Roadmap

## v0.1 — Current
- [x] Core blackout via private CGSConfigureDisplayEnabled API
- [x] Auto-blackout on external display connect
- [x] Auto-restore on external display disconnect (safety invariant)
- [x] Menu bar icon with manual blackout toggle
- [x] Signal-based CLI (on/off/status/auto)
- [x] Sleep/wake handling with disconnect-during-sleep detection
- [x] LaunchAgent lifecycle (daemon start/stop)
- [x] Structured logging with verbosity levels

## v0.2 — Stability
- [x] Fix wake auto-blackout (P0 bug)
- [x] CGConfig no-op before restore (P1 safety invariant fix)
- [x] USB-C Alt Mode wake recovery — CGConfig no-op after display pipeline settles (P2)
- [x] Mach port presence detection (replaces launchctl list parsing)
- [x] `make clean; make; make dev` dev cycle without sudo for reload
- [x] Verified SIGKILL recovery path documented in onboarding

## v0.3 — Display Control
- [ ] F1/F2 brightness control for external display when built-in is blacked out
- [ ] Optional ALS-based brightness sync (built-in ambient sensor → external)
- [ ] Keyboard backlight toggle option

## v0.4 — UX
- [ ] Click menu bar icon to toggle blackout; right-click for options menu
- [ ] Second-launch highlights menu bar icon and opens menu
- [ ] Ring light mode: centered annulus on built-in as supplemental light
- [ ] Panel light mode: solid color fill on built-in as fill light

## v1.0 — Distribution
- [ ] Bundle ID: `io.github.toobuntu.blackoutd`
- [ ] Homebrew formula
- [ ] `.pkg` installer for non-technical users
- [ ] Signed with Developer ID (if Apple Developer Program enrolled)
- [ ] Mach port IPC replacing signal-based CLI

## Future / Under Consideration
- SMAppService migration if packaged as Blackout.app (see README tech notes)
- Intel Mac support (untested; display ID assumptions may differ)
- Non-technical user launcher (Blackout stub app in /Applications)
- Homoglyph attack defense (CVE-2021-42694) via Unicode confusables tables
