# blackoutd — AI Handoff Prompt

Paste this entire file as the first message to the AI/LLM, then attach all
source files. This document is self-contained and authoritative.

---

## Problem Statement

A MacBook Air M2 running macOS 26 Tahoe is used in a desktop configuration
with a Dell SP2309W external display connected via USB-C→HDMI adapter. The
user wants:

1. The built-in display suppressed (blacked out) whenever the external is
   connected, and automatically restored when the external is disconnected.
2. A menu bar icon reflecting current state, with manual controls.
3. Safe, reliable behavior across sleep/wake cycles.
4. The built-in to never be left in a broken or unrecoverable state.

A companion daemon, **displayrecommitd** (separate repo), was spun off during
development to handle a USB-C Alt Mode dropout bug on wake. Key findings from
that investigation must be integrated back into blackoutd.

---

## Repository Layout

(Leading underscores below represent dot-prefixed files on disk.)

```
blackoutd/
├── src/
│   ├── main.m                      CLI entry point + daemon run loop
│   ├── AppDelegate.h
│   ├── AppDelegate.m               LaunchAgent lifecycle, sleep/wake, signals, menu bar
│   ├── DisplayController.h
│   ├── DisplayController.m         Display state machine, IOKit, private CGS API
│   └── Info.plist                  Embedded via -sectcreate __TEXT __info_plist
├── spec/
│   ├── spec_helper.rb
│   ├── integration/
│   │   ├── blackout_control_spec.rb
│   │   ├── daemon_lifecycle_spec.rb
│   │   ├── log_format_spec.rb
│   │   └── preferences_spec.rb
│   └── manual/
│       └── TESTING.md              Hardware-dependent manual test checklist
├── Makefile
├── blackoutd.plist.template        LaunchAgent plist; {{BUNDLE_ID}} {{HOME}} substituted
├── Info.plist                      Bundle metadata
├── Gemfile                         rspec ~> 3.13
├── CLAUDE.md                       Project memory for AI assistants
├── ROADMAP.md
├── displayprobe.m                  Standalone diagnostic tool (not installed)
├── _gitignore          →  .gitignore
├── _clang-format       →  .clang-format      (LLVM, 4-space, 100-col)
├── _rspec              →  .rspec
├── _claude/
│   └── settings.json   →  .claude/settings.json   (branch guard + auto-format hooks)
└── _github/
    └── workflows/
        └── ci.yml      →  .github/workflows/ci.yml
```

Build:
```sh
clang -fobjc-arc -Wall -Wextra -Os \
  -framework Cocoa -framework CoreGraphics -framework IOKit \
  -sectcreate __TEXT __info_plist src/Info.plist \
  -DBD_BUNDLE_ID='"io.github.toobuntu.blackoutd"' \
  -o build/blackoutd src/main.m src/AppDelegate.m src/DisplayController.m
strip build/blackoutd
codesign --sign - --force build/blackoutd
```

---

## Core Architecture

### Binary Roles

The binary serves dual roles depending on invocation:

**CLI mode** (any invocation except `daemon` with no subcommand):
- `blackoutd on` → SIGUSR1 to running daemon
- `blackoutd off` → SIGUSR2 to running daemon
- `blackoutd status` → reads NSUserDefaults + queries display state
- `blackoutd auto on|off` → writes pref, sends SIGHUP to reload
- `blackoutd daemon start` → `launchctl bootstrap gui/UID plist`
- `blackoutd daemon stop` → `launchctl bootout gui/UID/label`

**Daemon mode** (`blackoutd daemon`, invoked by launchd):
- Runs NSApplication run loop
- AppDelegate handles all logic

### DisplayController

Owns the display state machine. Key behaviors:

- **Private API `CGSConfigureDisplayEnabled(config, displayID, bool)`**: the
  only way to programmatically enable/disable a display in a CGDisplayConfigRef.
  No public equivalent exists.

- **Deprecated `CGDisplayIOServicePort(displayID)`**: maps a CGDirectDisplayID to
  its IOKit service port. Used to distinguish hardware displays from virtual/
  placeholder displays. Deprecated macOS 10.9 with no public replacement provided
  by Apple. Fallback: vendor IDs > 0xFFFF are virtual (FourCC pseudo-IDs:
  0x756E6B6E = "unkn", 0x76697274 = "virt").

- **`_actionInProgress` flag + 2-second dispatch window**: suppresses CGDisplay
  reconfiguration callbacks echoed as side effects of our own CGS call. A real
  display event (e.g. unplug) arriving inside the window is suppressed; the
  safety invariant check at window close catches it.

- **Safety invariant**: built-in is unconditionally restored whenever
  `hasActiveExternalDisplay` returns NO. `enableBlackout` refuses if no hardware
  external is present.

### AppDelegate

- Sleep/wake: `NSWorkspaceWillSleepNotification` / `NSWorkspaceDidWakeNotification`
- Signal handlers via GCD dispatch sources (never raw signal handlers):
  SIGUSR1=blackout, SIGUSR2=restore, SIGHUP=reload prefs, SIGTERM/SIGINT=quit
- Menu bar: `macbook`/`macbook.slash` SF Symbols; NSStatusItem with NSMenu
- WindowServer readiness: `notify_register_dispatch("com.apple.windowserver.active")`
  before calling any CG* APIs on startup
- Persisted state: NSUserDefaults suite `"blackoutd"`,
  keys `"blackoutActive"` and `"autoBlackoutOnExternalConnect"`

---

## Evolution of blackoutd

### Phase 1 — Proof of concept
The private API `CGSConfigureDisplayEnabled` was identified as the only way to
programmatically disable a display without a kernel extension. Early versions
called this directly from a simple NSApplication delegate with no state machine,
no signal handling, and no persistence. The built-in was disabled on launch and
restored on quit. No external-display detection existed.

### Phase 2 — Display detection and state machine
`CGDisplayRegisterReconfigurationCallback` was added. DisplayController was
extracted as a separate class. The distinction between hardware-backed and virtual
displays was added using `CGDisplayIOServicePort` (with FourCC fallback) after
discovering that macOS inserts placeholder virtual displays during display
transitions, causing false positive "external connected" readings.

The `_actionInProgress` suppression window was added after discovering that the
CGS enable/disable call generates its own reconfiguration callbacks, which would
re-enter the state machine and cause a loop.

### Phase 3 — CLI and signal protocol
`main.m` grew a full CLI layer: `on`, `off`, `status`, `auto`, `daemon start/stop`.
Signal-based IPC was chosen over Mach ports for simplicity (Mach port IPC is on
the roadmap). SIGUSR1/SIGUSR2 for blackout/restore, SIGHUP for preference reload.
`daemonPid()` uses `launchctl list` tab-separated output to find the running PID.

### Phase 4 — Sleep/wake hardening
The original sleep handling was naive. Several bugs were found:
- External display announces itself via CGDisplayReconfigurationCallback on wake,
  causing auto-blackout to fire. But the display system is still settling and
  the first announcement may be a virtual placeholder, not the real hardware.
- External disconnected during sleep was not detected until wake, leaving the
  built-in blacked out with no external to show.
- `_externalDisconnectedDuringSleep` ivar was added; `invalidateDisplayState`
  returns it and clears it at wake.

### Phase 5 — displayrecommitd spinoff and wake recovery bug
A USB-C Alt Mode dropout was discovered: ~30 seconds after wake with the built-in
suppressed, the external display goes black. A companion daemon (displayrecommitd)
was developed to investigate and fix this. Key findings:

- The failure is a physical USB-C Alt Mode negotiation dropout, confirmed in
  WindowServer logs (`Display N hot plug 0` at ~34s post-wake).
- `IOServiceRequestProbe` on `DCPDPDeviceProxy` returns 0xe00002c7
  (kIOReturnUnsupported) — dead end.
- A no-op `CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration` fired
  after the display pipeline re-settles (2-second quiet timer) causes WindowServer
  to absorb the reconnected display. No visible flicker.
- The battery-at-sleep condition that was initially hypothesized was found to be
  coincidental.

Separately, a bug was found where the built-in was not auto-blacking-out after
wake with an external connected. This is the current highest-priority bug.

### Phase 6 — BetterDisplay reverse engineering
`ipsw class-dump --arch arm64 BetterDisplay` and `otool -L` revealed:

- BetterDisplay uses `CoreDisplay.framework` (public, undocumented),
  `DisplayServices.framework` (private), `IOMobileFramebuffer.framework`
  (private), `SkyLight.framework` (private).
- Key properties: `_disconnectReconnectedDisplaysAfterWake`,
  `_reinitializeOnWake`, `_reconnectAfterSleep`.
- Their fix is an explicit **virtual display disconnect/reconnect cycle** on wake,
  not a CGConfig no-op. This is a stronger intervention.
- blackoutd already uses `CGVirtualDisplay` API for the mirror display. The
  correct approach is to destroy and recreate the virtual mirror after the
  pipeline settles on wake.

**Current state**: wake auto-blackout is broken (P0). displayrecommitd's
CGConfig no-op fix has not yet been integrated into blackoutd's restore path
to fix the safety invariant violation (P1). The virtual display destroy/recreate
approach (P2) has not yet been implemented.

---

## displayrecommitd — What Needs to Come Back Into blackoutd

### The USB-C Alt Mode Dropout Bug

With the built-in suppressed and USB-C→HDMI as the sole display path, the USB-C
controller drops Alt Mode negotiation ~30 seconds after wake. WindowServer logs
confirm: `Display 2 hot plug 0` fires at ~34s post-wake, then `hot plug 1` as
Alt Mode re-establishes. Without intervention, the display stays black.

**displayrecommitd's approach** (standalone fallback for non-blackoutd users):
1. Register `CGDisplayReconfigurationCallback`
2. On `DidWake`, arm 2-second quiet timer, reset on each callback
3. After 2 quiet seconds (pipeline settled, Alt Mode re-established), fire
   no-op `CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration`
4. WindowServer absorbs the reconnected display

**Reliability caveat**: Alt Mode appears to re-establish spontaneously before
the quiet timer fires in all observed cases. There is no public API to
confirm or guarantee this. It has always worked in practice.

### What blackoutd Should Do Instead (P2)

blackoutd owns the `CGVirtualDisplay` mirror display. The better fix, consistent
with BetterDisplay's `_disconnectReconnectedDisplaysAfterWake`, is:

1. On `systemDidWake:` → arm 2-second quiet timer
2. Timer fires → destroy the virtual mirror display via `CGVirtualDisplay` API
3. Recreate it and re-apply the mirror configuration
4. This forces a full display pipeline reinitiation rather than just a CGConfig
   recommit, and is more reliably recoverable

This belongs in **DisplayController**, not AppDelegate.

### P1: CGConfig No-Op Before Restore (Immediate Fix)

One confirmed repro: external unplugged while compositor was in a broken state.
blackoutd correctly called `disableBlackout` → `applyEnable:YES`, but the
built-in came up also black with only a cursor visible.

Fix: issue a no-op `CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration`
immediately before `CGSConfigureDisplayEnabled(config, builtInID, YES)` in
`applyEnable:`. This ensures the compositor is healthy before the built-in
is re-enabled. This is a one-liner addition to `setDisplay:enabled:` in
DisplayController.

---

## Light Modes — Design Specification

Light modes are a planned feature (not yet implemented) that repurpose the
built-in display as a supplemental light source while the external display
remains the active workspace display. They are an extension of the existing
"blackout" state — the built-in is still suppressed from normal desktop use,
but instead of being fully dark it shows a controlled light pattern.

### Two Modes

**Ring Light mode**: Displays a centered annulus (ring) on a black background.
The ring suggests a photography ring light or halo. Intended for video calls,
product photography, or ambient illumination. The ring's position is fixed at
screen center.

Configurable:
- Size: Small (25% diameter), Medium (40%), Large (60%) — set via menu
- Stroke width: fixed relative to ring diameter
- Color/temperature: Warm white (2700K-equivalent), Neutral white (4000K),
  Cool white (6500K), plus mood colors (soft amber, soft blue, soft rose)
- Brightness: controlled via system brightness keys (the built-in display
  brightness controls remain active even when suppressed)

Default: Medium, Warm white.

**Panel Light mode**: Fills the entire built-in display with a solid color.
Simpler and brighter than ring mode. Useful as a fill light or bounce surface.

Configurable:
- Color/temperature: same presets as ring mode
- Brightness: system brightness keys

Default: Warm white.

### Menu Bar Integration

The existing left-click behavior (which currently has no action or opens the
menu) will open a mode picker when in light mode. The right-click (or clicking
the status item button) always opens the full menu.

Menu structure with light modes:
```
● Black Out Built-in Display    [when not blacked out]
  ─────────────────────────────
  Ring Light Mode
  Panel Light Mode
  ─────────────────────────────
  Auto-blackout on External Connect  [checkmark]
  ─────────────────────────────
  Quit blackoutd
```

When in a light mode:
```
● Restore Built-in Display
  Switch to Ring Light
  Switch to Panel Light
  Switch to Black Out
  ─────────────────────────────
  [Size submenu — Ring only]
  [Color submenu]
  ─────────────────────────────
  Auto-blackout on External Connect  [checkmark]
  ─────────────────────────────
  Quit blackoutd
```

Menu bar icons:
- `macbook` — built-in active (normal)
- `macbook.slash` — blacked out
- `light.panel.fill` — panel light mode (or nearest SF Symbol)
- `circle.dashed` / `ring.dashed` — ring light mode

### Safety Invariant for Light Modes

External display disconnect **unconditionally terminates any light mode** and
restores the built-in to normal display use. This is the same invariant as
blackout mode — the built-in is never the sole active display in any suppressed
mode when no external is present.

Persistence: the last active light mode (ring/panel) and its settings are
persisted in NSUserDefaults suite `"blackoutd"`. On wake with external connected
and autoBlackoutOnExternalConnect enabled, if the last state was a light mode,
that light mode is restored.

### Implementation Notes

Light mode rendering requires drawing to the built-in display's CGDirectDisplayID.
The built-in must first be suppressed via `CGSConfigureDisplayEnabled(..., NO)`,
then a framebuffer-level approach or an overlay window must be used to render
the pattern. The most practical public API path is a borderless `NSWindow` set
to cover the built-in display's frame, configured as a level above the desktop,
with a custom `NSView` drawing the ring or fill.

The built-in's CGDirectDisplayID is already tracked in `DisplayController`
(`_builtInID`). A new `LightModeController` class should own the overlay window
and rendering.

---

## Technical Debt — Prioritized

### P0 — Wake auto-blackout broken (BLOCKING)
**Symptom**: After sleep/wake with external connected and auto-blackout ON,
the built-in does not black out.
**Root cause (suspected)**: `systemDidWake:` calls `invalidateDisplayState`
which clears `_actionInProgress` and `_externalDisconnectedDuringSleep`, then
the code path does not re-arm auto-blackout. When the external re-announces via
CGDisplayReconfigurationCallback, the display system is still settling, and the
callback may be suppressed or the state machine may see the re-announcement as
not requiring action.
**Fix**: Audit `systemDidWake:` → `invalidateDisplayState` flow. After the
wake settle period (or on the first non-suppressed CGDisplayReconfigurationCallback
post-wake), if `autoBlackoutOnExternalConnect` is YES and an external is present
and `_isBlackedOut` is NO, call `enableBlackout`.
**Files**: `src/AppDelegate.m`, `src/DisplayController.m`

### P1 — Safety invariant on restore (CONFIRMED BUG)
**Symptom**: One confirmed repro: when the external was unplugged while the
display compositor was in a broken state, `disableBlackout` restored the built-in
but the built-in also showed only a cursor on a black screen.
**Fix**: In `setDisplay:enabled:` in DisplayController, before calling
`CGSConfigureDisplayEnabled(config, builtInID, YES)`, issue a no-op
`CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration` to ensure the
compositor is healthy. This is a 2-line addition.
**Files**: `src/DisplayController.m`

### P2 — USB-C Alt Mode wake recovery (NEW FEATURE)
**Problem**: With built-in suppressed, USB-C controller drops Alt Mode ~30s
after wake. External goes black. Requires user to unplug/replug USB-C.
**Fix (from displayrecommitd)**: On `systemDidWake:`, arm 2-second quiet timer
via `CGDisplayReconfigurationCallback`. On fire, destroy and recreate the
CGVirtualDisplay mirror. This is the BetterDisplay approach
(`_disconnectReconnectedDisplaysAfterWake`). Fallback: if virtual display
API is unavailable, issue CGConfig no-op (displayrecommitd's approach).
**Files**: `src/DisplayController.m`, `src/AppDelegate.m`

### P3 — Test suite completion
Integration tests exist but exercise a `status` subcommand and `on`/`off` CLI
that expect specific output formats and daemon behavior. Some tests may be
broken or skipped (they use `skip "daemon not running"` guards). XCTest unit
tests for display classification logic and state machine transitions do not exist.
**Files**: `spec/integration/*.rb`, new `spec/unit/` directory TBD

### P4 — CI hardening
- Pin GitHub Actions to commit SHAs (`pinact run --verify --update`).
  `ruby/setup-ruby@v1` is unpinned. `actions/checkout` is pinned.
- Add `.githooks/pre-commit` with invisible Unicode character check (supply
  chain attack mitigation per Ars Technica coverage of variation selector attack).
- `plutil -lint` job present in ci.yml; verify it generates and lints the
  correct plist path.
**Files**: `.github/workflows/ci.yml`, `.githooks/pre-commit` (new)

### P5 — Version infrastructure
`CFBundleShortVersionString` not present; `CFBundleVersion` is hardcoded to `1`.
No `make release` target exists.
**Files**: `src/Info.plist`, `Makefile`

### P6 — Light modes (future)
Ring light and panel light. See full design specification above.
**Files**: New `src/LightModeController.h/.m`; `src/AppDelegate.m`,
`src/DisplayController.m` for integration

### P7 — Mach port IPC (future)
Replace `launchctl list` subprocess in `daemonPid()` and SIGUSR1/2 for
status queries with a named Mach port `io.github.toobuntu.blackoutd`.
Enables structured status queries without spawning subprocesses.
**Files**: `src/main.m`, `src/AppDelegate.m`

---

## Acceptance Criteria

### P0: Wake auto-blackout
- [ ] After any sleep/wake with external connected and auto-blackout ON,
      built-in blacks out within 3 seconds of wake notification
- [ ] Verified: short sleep (<1 min), long sleep (>8 hr, with maintenance
      dark wakes), `pmset sleepnow`, lid-close sleep
- [ ] `[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating
      blackout action` appears in log within 5s of wake

### P1: Safe restore
- [ ] Unplugging external with built-in blacked out produces a usable built-in
      showing window content (not cursor-on-black)
- [ ] Reproducible with both healthy and broken-compositor display state

### P2: USB-C wake recovery
- [ ] External display recovers after sleep/wake without user intervention
- [ ] No visible flicker during recovery
- [ ] WindowServer does not show unrecovered `Display N hot plug 0` events
- [ ] Works on battery and AC

---

## Key Hardware and Display Identifiers

- **Machine**: MacBook Air M2 (Mac14,2), macOS 26.3 Tahoe, arm64
- **Built-in**: displayID=1, vendor=0x0610 (Apple), `CGDisplayIsBuiltin`=YES
- **External**: Dell SP2309W, vendor=0x10AC, model=0xD01D, USB-C→HDMI adapter
- **Virtual placeholder**: vendor=0x756E6B6E ("unkn") or 0x76697274 ("virt")
- **External DCP IOService**: path contains `dcpext` —
  `IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/.../DCPDPDeviceProxy`
  This is the stable identifier for the M2's external display controller.

---

## Logging Reference

Structured log tags (all lines carry exactly one):
```
[startup]   [quit]    [prefs]    [change]
[external]  [builtin] [state]    [sleep]    [wake]
```

```sh
# Live stream
log stream --predicate 'process == "blackoutd"'
# Post-wake
log show --last 5m --predicate 'process == "blackoutd"'
# Enable verbose logging (adds [verbose=2]-tagged lines)
defaults write blackoutd verbosityLevel -int 2; killall -HUP blackoutd
# Reset
defaults delete blackoutd verbosityLevel; killall -HUP blackoutd
```

Log file: `~/Library/Logs/blackoutd.log`

---

## Development Conventions

- Objective-C, ARC, AppKit. No Swift.
- Minimal comments; self-documenting names. No first-person in code comments.
- Long options in shell (`--extended-regexp` not `-E`).
- Shell scripts: `set -e`, `main()` calling other functions.
- Commit subject ≤50 chars; body wraps at 72; `Closes #N` in body.
- No verbose AI commentary in PRs. Note AI assistance and manual verification.
- `.claude/settings.json`: feature branches only (blocks direct edits to main),
  auto-runs `clang-format --style=file` on `.m`/`.h` save.
- `pinact run --verify --update` before any PR touching workflow files.
- No `CGDisplaySleep`/`CGDisplayWake` for recovery — visible flicker.
- No `IOServiceRequestProbe` on `DCPDPDeviceProxy` — confirmed 0xe00002c7
  (kIOReturnUnsupported). See displayprobe2.m in displayrecommitd repo.
- No `pmset displaysleepnow` in restore path — visible flicker.
- Battery-at-sleep conditions for wake recovery — found to be coincidental.
