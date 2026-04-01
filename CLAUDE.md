<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# CLAUDE.md — Project Memory for AI Assistants

This file is the authoritative technical reference for AI assistants working on
blackoutd. It supplements AGENTS.md with implementation details, known dead ends,
and conventions that cannot be inferred from the code alone.

## Build

```sh
make            # build to build/blackoutd
make clean      # remove build artifacts
make install    # build + install binary + bootstrap LaunchAgent (requires sudo)
make reinstall  # build + install + restart agent (requires sudo)
make uninstall  # stop agent + remove binary + remove plist
```

Build requirements: Xcode Command Line Tools (`xcode-select --install`).

## Lint

```sh
# clang-format check (no write)
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file --dry-run --Werror

# clang-format fix
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file -i

# plist lint
make postinstall && plutil -lint "$HOME/Library/LaunchAgents/$(make -s print-bundle-id).plist"
```

## Test

No automated test suite yet. See AGENTS.md for the manual testing checklist.

## Key Technical Details

### Private API: CGSConfigureDisplayEnabled
The only way to programmatically enable/disable a display at the compositor level.
Declared as `extern` in DisplayController.m and resolved at runtime from
CoreGraphics/SkyLight. No public equivalent exists.

### Deprecated API: CGDisplayIOServicePort
Maps CGDirectDisplayID to IOKit service port. Deprecated macOS 10.9 with no
replacement. Used in `displayIsHardwareBacked()` to distinguish real displays
from virtual/placeholder displays. Fallback: vendor IDs > 0xFFFF are virtual
(FourCC pseudo-IDs like 0x756E6B6E = "unkn", 0x76697274 = "virt").

### _actionInProgress suppression window
After CGSConfigureDisplayEnabled, macOS fires echo reconfiguration callbacks.
A 2-second window suppresses these. Real events (e.g., unplug) arriving inside
the window are missed; the safety invariant check at window close catches them.

### NSUserDefaults suite
Suite name: `"blackoutd"` (not the bundle ID, to avoid macOS warning).
Keys: `blackoutActive` (BOOL), `autoBlackoutOnExternalConnect` (BOOL, default YES).

### Bundle ID
`io.github.toobuntu.blackoutd` — defined in `src/Info.plist`, injected at
compile time via `-DBD_BUNDLE_ID`. The LaunchAgent label equals the bundle ID.

## Known Dead Ends — Do Not Retry

- **CGDisplaySleep/CGDisplayWake** for recovery: visible flicker on the external.
- **IOServiceRequestProbe on DCPDPDeviceProxy**: returns 0xe00002c7
  (kIOReturnUnsupported) on Apple Silicon. Confirmed in displayrecommitd.
- **pmset displaysleepnow** in the restore path: visible flicker.
- **Battery-at-sleep condition** for wake recovery: found to be coincidental
  during displayrecommitd investigation. Not a reliable predictor.
- **CGVirtualDisplay**: the handoff prompt claims blackoutd "already uses
  CGVirtualDisplay API for the mirror display" — this is false. No virtual
  display creation exists in the codebase. It was planned but never implemented.

## Development Conventions

- Objective-C, ARC, AppKit. No Swift.
- Minimal comments; self-documenting names. No first-person in code comments.
- Long options in shell (`--extended-regexp` not `-E`).
- Commit subject ≤ 50 chars; body wraps at 72; `Closes #N` in body.
- No verbose AI commentary in PRs. Note AI assistance and manual verification.
- `.clang-format`: LLVM style, 4-space indent, 100-column limit.

## Open Bugs

### P0: Wake auto-blackout broken
After sleep/wake with external connected and auto-blackout ON, the built-in
does not auto-black out. Suspected root cause: `systemDidWake:` →
`invalidateDisplayState` flow does not re-arm auto-blackout when the external
re-announces. Files: `src/AppDelegate.m`, `src/DisplayController.m`.

### P1: Safety invariant on restore
When the compositor is in a broken state, `disableBlackout` restores the
built-in but it shows cursor-on-black. Fix: issue a no-op
CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration before
CGSConfigureDisplayEnabled(..., YES). File: `src/DisplayController.m`.

### P2: USB-C Alt Mode wake recovery
With built-in suppressed and USB-C→HDMI as the sole display path, the USB-C
controller drops Alt Mode negotiation ~30 seconds after wake. The external
display goes black; the user must unplug/replug the cable. Fix from
displayrecommitd: on `systemDidWake:`, arm a 2-second quiet timer that fires
after display callbacks settle. On fire, issue a no-op CGConfig transaction
(CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration) so WindowServer
absorbs the reconnected display. This is already partially implemented in the
P9 deferred wake check in `AppDelegate.m`; the remaining work is the quiet-
timer approach (reset on each callback) in `DisplayController` for more
reliable timing. Files: `src/DisplayController.m`, `src/AppDelegate.m`.
