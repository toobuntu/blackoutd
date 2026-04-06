<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

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
# On macOS (contributors), use: xcrun clang-format ...
# In agent sandbox (Ubuntu), use bare clang-format as shown below.
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file --dry-run --Werror

# clang-format fix
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file -i

# clang-tidy (macOS only — requires SDK headers; on macOS, prefix with xcrun or
# use $(brew --prefix llvm@NN)/bin/clang-tidy if not in PATH)
clang-tidy src/*.m -- -fobjc-arc -DBD_BUNDLE_ID='"io.github.toobuntu.blackoutd"' \
  -framework Cocoa -framework CoreGraphics -framework IOKit -I src

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
  See `displayprobe2.m` on the displayrecommitd stash branch.
- **pmset displaysleepnow** in the restore path: visible flicker.
- **Battery-at-sleep condition** for wake recovery: found to be coincidental
  during displayrecommitd investigation. Not a reliable predictor.
- **CGVirtualDisplay**: the handoff prompt claims blackoutd "already uses
  CGVirtualDisplay API for the mirror display" — this is false. No virtual
  display creation exists in the codebase. It was planned but never implemented.

## BetterDisplay Research (Reference)

`ipsw class-dump --arch arm64 BetterDisplay` + `otool -L` revealed:

- Uses `CoreDisplay.framework` (public, undocumented),
  `DisplayServices.framework` (private), `IOMobileFramebuffer.framework`
  (private), `SkyLight.framework` (private).
- Key properties: `_disconnectReconnectedDisplaysAfterWake`,
  `_reinitializeOnWake`, `_reconnectAfterSleep`.
- Their wake recovery is an explicit virtual display disconnect/reconnect
  cycle, which is a stronger intervention than the CGConfig no-op used by
  displayrecommitd. This informs the P2 fix direction.

## Development Hardware

- Machine: MacBook Air M2 (Mac14,2), macOS 26 Tahoe, arm64
- Built-in: displayID=1, vendor=0x0610 (Apple), `CGDisplayIsBuiltin`=YES
- External: Dell SP2309W, vendor=0x10AC, model=0xD01D, USB-C→HDMI adapter
- Virtual placeholder: vendor=0x756E6B6E ("unkn") or 0x76697274 ("virt")
- External DCP IOService path: contains `dcpext` —
  `IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/.../DCPDPDeviceProxy`

## Development Conventions

- Objective-C, ARC, AppKit. No Swift. (See `docs/architecture.md` for rationale.)
- Minimal comments; self-documenting names. No first-person in code comments.
- Long options in shell (`--extended-regexp` not `-E`).
- Commit subject ≤ 50 chars; body wraps at 72; `Closes #N` in body.
- No verbose AI commentary in PRs. Note AI assistance and manual verification.
- `.clang-format`: LLVM base style, 2-space indent, 80-column limit.
- `.clang-tidy`: bugprone-*, clang-analyzer-*, select readability checks.

## Open Bugs

### P0: Wake auto-blackout broken
After sleep/wake with external connected and auto-blackout ON, the built-in
does not auto-black out. Suspected root cause: `systemDidWake:` →
`invalidateDisplayState` flow does not re-arm auto-blackout when the external
re-announces. Files: `src/AppDelegate.m`, `src/DisplayController.m`.

### P1: Safety invariant on restore (MITIGATED)
When the compositor is in a broken state, `disableBlackout` restores the
built-in but it shows cursor-on-black. Fix: a no-op CGConfig recommit
(`recommitDisplayConfiguration`) before `CGSConfigureDisplayEnabled(..., YES)`.
Implemented in `setDisplay:enabled:`. Pattern matches displayrecommitd
(`recommitDisplayConfiguration` in `displayrecommitd.m`).
File: `src/DisplayController.m`.

### P2: USB-C Alt Mode wake recovery
With built-in suppressed and USB-C→HDMI as the sole display path, the USB-C
controller drops Alt Mode negotiation ~30 seconds after wake. The external
display goes black; the user must unplug/replug the cable. Fix from
displayrecommitd: on `systemDidWake:`, arm a 2-second quiet timer that fires
after display callbacks settle. On fire, issue a no-op CGConfig transaction
(CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration) so WindowServer
absorbs the reconnected display. This is already partially implemented in the
deferred wake check in `AppDelegate.m`; the remaining work is the quiet-timer
approach (reset on each callback) in `DisplayController` for more reliable
timing. See `displayrecommitd.m` in the displayrecommitd repo for the
reference implementation. Files: `src/DisplayController.m`, `src/AppDelegate.m`.

### P5: _externalDisconnectedDuringSleep never set (FIXED)
In `handleReconfiguration:flags:`, the sleep branch detected an external
disconnect but never set `_externalDisconnectedDuringSleep = YES`. The ivar
was read in `invalidateDisplayState` and returned to `systemDidWake:` but was
always NO. This meant unplugging the external during sleep would leave the
built-in blacked out at wake — a safety invariant violation. Fixed by adding
the assignment at the detection site. File: `src/DisplayController.m`.

## Related Projects

### displayrecommitd
Standalone LaunchAgent that fixes the USB-C Alt Mode wake recovery issue.
Repository: <https://github.com/toobuntu/displayrecommitd/>
- `main` branch: production daemon (`displayrecommitd.m`)
- `stash` branch: development artifacts including `displayprobe2.m` (IOKit
  DCP device proxy probing tool) and research logs

The `displayprobe.m` that was previously in this repo was a sleep/wake display
state watcher used for development. `displayprobe2.m` in the displayrecommitd
stash branch probes DCP device proxy paths — a different diagnostic concern.
Neither probe is meant for production; both were development-only tools
serving distinct purposes.
