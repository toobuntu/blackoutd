<!--
SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architecture

## Why Objective-C

blackoutd is written in Objective-C rather than Swift for practical reasons
tied to the APIs it depends on:

1. **Private C symbol (`CGSConfigureDisplayEnabled`)** — The core display
   enable/disable function is a private C symbol resolved at runtime from
   CoreGraphics/SkyLight. In Objective-C, this is a single `extern`
   declaration. In Swift, it would require a bridging header with an
   `@_silgen_name` annotation or `dlsym` at runtime — extra indirection with
   no benefit.

2. **Deprecated C API (`CGDisplayIOServicePort`)** — Used to distinguish
   real hardware displays from virtual/placeholder displays. Deprecated since
   macOS 10.9 with no replacement. The deprecation warning is suppressed with
   `#pragma clang diagnostic ignored`. Swift has no equivalent inline pragma;
   it would require a separate C/Obj-C wrapper file.

3. **C function pointer callback (`CGDisplayReconfigurationCallback`)** —
   The display reconfiguration callback is a C function pointer with a `void
   *userInfo` context. In Objective-C, `(__bridge void *)self` is idiomatic
   and zero-cost. In Swift, closures can bridge to C function pointers, but
   the `void *` context pattern requires `Unmanaged<T>` boilerplate.

4. **IOKit C API** — `CGDisplayIOServicePort` returns a `mach_port_t` used
   with IOKit functions. These are all C interfaces; Objective-C is their
   natural host language.

5. **Build simplicity** — The entire project builds with a single `clang
   -fobjc-arc` invocation via Make. No Xcode project, no Swift Package
   Manager, no module maps. Build time is under one second.

6. **No benefit from Swift** — The codebase is ~800 lines across three files.
   There is no complex data modeling, no protocol-oriented architecture, no
   SwiftUI. The only AppKit usage is a three-item `NSMenu` on an
   `NSStatusItem`. Swift's strengths (type safety, generics, value types,
   structured concurrency) do not apply at this scale or for these APIs.

## System Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  blackoutd binary                                                │
│                                                                  │
│  main.m ─── CLI dispatch                                         │
│     │       (on/off/status/auto/--config/daemon start|stop)      │
│     │                                                            │
│     └─── daemon mode ─── NSApplication run loop                  │
│              │                                                   │
│  AppDelegate.m ─── NSApplication delegate                        │
│     │  Menu bar (NSStatusItem + NSMenu)                          │
│     │  Signal handlers (SIGUSR1/2, SIGHUP, SIGTERM)              │
│     │  Sleep/wake observers (NSWorkspace notifications)          │
│     │  WindowServer readiness (notify_register_dispatch)         │
│     │  State restoration (NSUserDefaults)                        │
│     │                                                            │
│  DisplayController.m ─── Display state machine                   │
│     │  CGDisplayReconfigurationCallback ─── event dispatch       │
│     │  CGSConfigureDisplayEnabled ─── enable/disable built-in    │
│     │  CGDisplayIOServicePort ─── hardware vs. virtual detection │
│     │  CGBegin/CompleteDisplayConfiguration ─── recommit pattern │
│     │  _actionInProgress ─── 2-second echo suppression window    │
│     │  _systemSleeping ─── sleep/wake event gating               │
│     │  _externalDisconnectedDuringSleep ─── safety restore       │
│     │                                                            │
│     └─── Safety invariant: restore built-in when no external     │
│              present. UNCONDITIONAL. Never gated.                │
└──────────────────────────────────────────────────────────────────┘
```

### File Responsibilities

| File | Responsibility |
|------|----------------|
| `src/main.m` | CLI argument dispatch, daemon entry point, `printStatus`, `printConfig`, `launchctl` wrappers |
| `src/AppDelegate.m/.h` | NSApplication delegate: menu bar, signals, sleep/wake, state restoration |
| `src/DisplayController.m/.h` | All CoreGraphics display operations, reconfiguration callback, blackout state machine |
| `src/Info.plist` | Embedded bundle metadata (required for WindowServer connection) |
| `blackoutd.plist.template` | LaunchAgent plist template with `{{BUNDLE_ID}}` and `{{HOME}}` placeholders |
| `Makefile` | Build, install, reinstall, uninstall targets |

### Key Design Decisions

**Single binary** — The CLI and daemon share a binary. `blackoutd daemon`
launches the NSApplication run loop; all other subcommands are lightweight
operations (signal delivery, launchctl calls, display queries) that exit
immediately. This avoids maintaining separate binaries or IPC protocols.

**Signal-based IPC** — The CLI communicates with the running daemon via Unix
signals (SIGUSR1, SIGUSR2, SIGHUP). This is simple and requires no
framework support, but is one-way (no return value). The planned
replacement is a named Mach port with bootstrap_look_up().

**Private API** — CGSConfigureDisplayEnabled is the only known way to
disable a display at the compositor level on macOS. There is no public
API equivalent. This creates a fragility risk on major macOS updates, but
the symbol has been stable across macOS 13–26.

**Echo suppression** — After calling CGSConfigureDisplayEnabled, macOS
fires reconfiguration callbacks as side effects. A 2-second window
(`_actionInProgress`) suppresses these so they are not mistaken for real
connect/disconnect events. A safety check at window close catches any real
events that arrived during the window.

### Companion Project

[displayrecommitd](https://github.com/toobuntu/displayrecommitd/) is a
standalone LaunchAgent that fixes a USB-C Alt Mode wake recovery issue.
Its CGConfig recommit pattern is integrated into blackoutd's
`recommitDisplayConfiguration` method.
