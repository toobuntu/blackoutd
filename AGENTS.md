<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# AGENTS.md — Project guide for AI assistants and human contributors

Authoritative reference for any agent (Claude Code, Codex, Copilot, GPT, etc.)
or new human contributor working on blackoutd. `CLAUDE.md` is a thin pointer
to this file (Homebrew pattern); read this first.

@docs/agent-principles.md

## Project summary

blackoutd is an Objective-C macOS LaunchAgent daemon with a menu bar GUI.
It blacks out the built-in display when an external display is connected.
Written in Objective-C for direct access to private CoreGraphics C symbols
and deprecated IOKit APIs without Swift bridging overhead (see
`docs/architecture.md`).

## Build and lint

```sh
make            # build to build/blackoutd
make clean      # remove build artifacts
make install    # first-time install (build + bootstrap LaunchAgent)
make reinstall  # upgrade (bootout + reinstall + bootstrap)
make uninstall  # stop agent + remove all installed files
make dev        # build + restart agent from build dir; no sudo, dev cycle
make release    # verify clean tree, build, create annotated git tag

# clang-format check (no write)
# On macOS, prefix with `xcrun`; in a Linux agent sandbox, use bare clang-format.
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file --dry-run --Werror

# clang-format fix
find src -name '*.m' -o -name '*.h' | xargs clang-format --style=file -i

# clang-tidy (macOS only — requires SDK headers; on macOS, prefix with xcrun
# or use $(brew --prefix llvm@NN)/bin/clang-tidy if not in PATH)
clang-tidy src/*.m -- -fobjc-arc \
  -DBD_BUNDLE_ID='"io.github.toobuntu.blackoutd"' \
  -DBD_RESOURCES_BUNDLE='"/usr/local/share/blackoutd.bundle"' \
  -framework Cocoa -framework CoreGraphics -framework IOKit -I src

# plist lint (read-only validation of an already-generated plist)
plutil -lint "$HOME/Library/LaunchAgents/$(make -s print-bundle-id).plist"

# REUSE compliance (license headers)
reuse lint
scripts/annotate.sh   # add SPDX headers to any new uncovered files

# RSpec behavioral tests for hook + CI Unicode scanner (Homebrew
# portable Ruby; see CONTRIBUTING.md for the one-time gem install).
make test
```

If the LaunchAgent plist has not yet been generated (e.g., on a fresh
clone), run `make postinstall` first to materialize it from the template
at `$HOME/Library/LaunchAgents/$(make -s print-bundle-id).plist`. That
target writes to the user's LaunchAgents directory and is therefore not
part of the read-only lint pipeline; run it once before linting and
treat it as install-time setup, not validation.

Build requirements: Xcode Command Line Tools (`xcode-select --install`).

**Do NOT run `make install` or `make reinstall` under `sudo`.** The Makefile
uses `sudo` internally only for the `/usr/local/` writes; running the whole
target under sudo causes `id -u` to return 0 and `launchctl bootstrap gui/0
…` to target root's GUI domain, which has no logged-in user session. Build
artifacts also end up root-owned, breaking subsequent non-sudo builds. The
correct invocation is plain `make install` (or `make reinstall`); macOS
will prompt for the sudo password during the privileged steps.

## Architecture

- `src/main.m` — CLI dispatch and daemon entry point (`blackoutd daemon` subcommand)
- `src/AppDelegate.m/.h` — NSApplication delegate; menu bar item, signal handlers,
  WindowServer readiness, state restoration, sleep/wake observers
- `src/DisplayController.m/.h` — All CoreGraphics display operations;
  reconfiguration callback; blackout state machine; wake-settle timer
- `blackoutd.plist.template` — LaunchAgent plist template ({{BUNDLE_ID}},
  {{HOME}}, {{INSTALL_BIN}} substituted at install time by `make postinstall`)
- `src/Info.plist` — Embedded bundle metadata (required for WindowServer connection)
- `src/Resources/*.lproj` — Localized strings; loaded via `BDResourceBundle`
  in AppDelegate.m

## Key constraints

- Target: macOS 13+, Apple Silicon
- Compiler: clang via Xcode Command Line Tools (no Xcode project file)
- No third-party runtime dependencies
- Uses private symbol `CGSConfigureDisplayEnabled` (extern declaration only —
  resolved at runtime from CoreGraphics/SkyLight)
- Ad-hoc codesigned only (no Developer ID)
- Bundle ID: `io.github.toobuntu.blackoutd`
- LaunchAgent label: same as bundle ID

## Safety invariant

The built-in display MUST be restored when the last external display
disconnects. The check in `handleReconfiguration:flags:` is unconditional
— it must never be gated on `_actionInProgress` or any other guard. The
post-wake settle handler `wakeSettleTimerFired` re-checks the same
invariant after the recommit, closing a 2-second window where state could
diverge if an external was unplugged during sleep.

## Signal handling

| Signal  | Behavior                           |
|---------|------------------------------------|
| SIGUSR1 | Enable blackout                    |
| SIGUSR2 | Disable blackout (restore built-in)|
| SIGHUP  | Reload preferences from NSUserDefaults |
| SIGTERM | Clean shutdown (restores built-in) |
| SIGKILL | Cannot be caught — see README Known Issues |

Signal-based commands are scheduled to be replaced by Mach IPC in v1.0;
see ADR 0002 and the P4 entry in `docs/technical-debt.md`.

## NSUserDefaults suite

Suite name: `blackoutd` (distinct from the bundle ID, to avoid the macOS
warning about using bundle ID as suite name).

Keys:
- `autoBlackoutOnExternalConnect` (BOOL, default YES)
- `blackoutActive` (BOOL) — persisted blackout intent
- `verbosityLevel` (Integer, default 1; 2 enables `[verbose=2]`-tagged log lines)
- `recoveryStrategy` (String, default `displaysleep`; `none` disables the
  post-wake cursor-on-black auto-recovery — set via
  `blackoutd recovery <none|displaysleep>`; see P20/P29 and
  `docs/debug/cursor-on-black-matrix.md`)

## Key technical details

### Private API: `CGSConfigureDisplayEnabled`

The only way to programmatically enable/disable a display at the compositor
level. Declared as `extern` in `DisplayController.m` and resolved at
runtime from CoreGraphics/SkyLight. No public equivalent exists.

### Deprecated API: `CGDisplayIOServicePort`

Maps `CGDirectDisplayID` to IOKit service port. Deprecated macOS 10.9
with no replacement. Used in `displayIsHardwareBacked()` to distinguish
real displays from virtual/placeholder displays. Fallback: vendor IDs >
0xFFFF are virtual (FourCC pseudo-IDs like `0x756E6B6E` = "unkn",
`0x76697274` = "virt").

### `_actionInProgress` suppression window

After `CGSConfigureDisplayEnabled`, macOS fires echo reconfiguration
callbacks. A 2-second window suppresses these. Real disconnect events
arriving inside the window are NOT suppressed — `handleReconfiguration:`
evaluates the safety invariant before consulting `_actionInProgress`.
A settle-time check at +2s in `applyEnable:` catches state divergence.

### Wake-settle quiet timer (P0/P2 fix)

On `NSWorkspaceDidWakeNotification`, `DisplayController` arms a
`dispatch_source_t` timer with a 2-second initial delay. Each
`CGDisplayReconfigurationCallback` resets the timer. When the timer
fires after 2 full seconds of pipeline quiet, the handler issues a
no-op CGConfig recommit (P2: USB-C Alt Mode recovery), re-checks the
no-external safety invariant, and re-applies auto-blackout if needed
(P0: wake auto-blackout). See ADR 0003.

### Daemon presence and PID detection

The CLI uses `sysctl(KERN_PROC)` enumeration with four identity checks
(`p_comm`, effective UID, parent is launchd, executable path matches
`ProgramArguments[0]`). `bootstrap_look_up()` is NOT used from the CLI
— it has documented activation side-effects on the daemon's lifecycle.
The daemon-side `bootstrap_check_in()` is retained as the foundation for
v1.0 Mach IPC. See ADR 0002.

### Bundle ID and resource bundle

`io.github.toobuntu.blackoutd` — defined in `src/Info.plist`, injected
at compile time via `-DBD_BUNDLE_ID`. The LaunchAgent label equals the
bundle ID. Localized resources live in a separate `blackoutd.bundle`
installed alongside the binary; `BD_RESOURCES_BUNDLE` is the install path.

### Reverse-engineering and inspection tools

Investigating private/deprecated APIs and runtime state regularly uses:

- `ipsw class-dump`, `ipsw dyld info`, `ipsw macho info` — extract Objective-C
  interfaces and Mach-O metadata from system frameworks (BetterDisplay
  research used `ipsw class-dump --arch arm64 BetterDisplay`).
- `otool -L`, `otool -l`, `nm -gU`, `dyld_info` — inspect binary linkage,
  exported symbols, and library references.
- `log show`, `log stream` — query the unified logging system. Filter by
  `--predicate 'process == "blackoutd"'` or `subsystem == "com.apple.iokit"`.
- `pmset -g log`, `pmset -g sched`, `pmset -g batt`, `pmset -g pslog` — read
  power-management state and history. **Never** use mutating forms
  (`pmset -a`, `pmset -b`, `pmset -c`, `pmset -u`, `pmset sleepnow`,
  `pmset displaysleepnow`, `pmset schedule`, `pmset repeat`).
- `system_profiler SPDisplaysDataType -detailLevel mini` — display
  configuration as macOS sees it. Verify display state; don't assert from
  system_profiler — system_profiler can show no displays while an external
  is the sole active display and the built-in is blacked out; confirm via
  blackoutd status / CG / ioreg.
- `ioreg -lw0 -r -c IODisplayConnect` and other `-c` filters — IORegistry
  introspection for the display, USB-C, and DCP device proxy paths.
- `defaults read blackoutd` — inspect the daemon's NSUserDefaults state.
  Mutating forms (`defaults write`, `defaults delete`) should not be used
  by an agent; the maintainer makes those changes directly.
- `vmmap`, `sample`, `spindump` — process memory and call-stack inspection
  when diagnosing daemon hangs.

These tools are expected reading; they are part of the development loop.
The Claude Code allowlist includes them in `permissions.allow` so the
agent does not need to ask before running them.

## Known dead ends — do not retry

- **`CGDisplaySleep` / `CGDisplayWake`** for recovery: visible flicker
  on the external.
- **`IOServiceRequestProbe` on `DCPDPDeviceProxy`**: returns
  `0xe00002c7` (`kIOReturnUnsupported`) on Apple Silicon. Confirmed in
  `displayrecommitd`. See `displayprobe2.m` on the displayrecommitd
  `stash` branch.
- **`pmset displaysleepnow`** in the restore path: visible flicker.
- **Battery-at-sleep condition** for wake recovery: found to be
  coincidental during displayrecommitd investigation. Not a reliable
  predictor.
- **`CGVirtualDisplay`**: an earlier handoff prompt claimed blackoutd
  "already uses CGVirtualDisplay API for the mirror display" — false.
  No virtual display creation exists in the codebase. Planned but
  never implemented.

## BetterDisplay research (reference)

`ipsw class-dump --arch arm64 BetterDisplay` + `otool -L` revealed:

- Uses `CoreDisplay.framework` (public, undocumented),
  `DisplayServices.framework` (private), `IOMobileFramebuffer.framework`
  (private), `SkyLight.framework` (private).
- Key properties: `_disconnectReconnectedDisplaysAfterWake`,
  `_reinitializeOnWake`, `_reconnectAfterSleep`.
- Their wake recovery is an explicit virtual display
  disconnect/reconnect cycle, a stronger intervention than the CGConfig
  no-op used by displayrecommitd. This informs the P2 fix direction.

## Development hardware

- Machine: MacBook Air M2 (Mac14,2), macOS 26 Tahoe, arm64
- Built-in: `displayID=1`, vendor=`0x0610` (Apple), `CGDisplayIsBuiltin`=YES
- External: Dell SP2309W, vendor=`0x10AC`, model=`0xD01D`, USB-C→HDMI adapter
- Virtual placeholder: vendor=`0x756E6B6E` ("unkn") or `0x76697274` ("virt")
- External DCP IOService path: contains `dcpext` —
  `IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/.../DCPDPDeviceProxy`

## Conventions

- Objective-C, ARC, AppKit. No Swift. (See `docs/architecture.md`.)
- Minimal comments; self-documenting names. No first-person in code comments.
- Long options in shell (`--extended-regexp` not `-E`).
- Commit subject ≤ 50 chars; body wraps at 72; `Closes #N` in body.
- No verbose AI commentary in PRs. Note AI assistance and manual verification.
- `.clang-format`: LLVM base style, 2-space indent, 80-column limit.
- `.clang-tidy`: `bugprone-*`, `clang-analyzer-*`, select readability checks.
- en_US spelling everywhere (e.g. "labeling" not "labelling", "color" not "colour").
- Merge commits, never squash or rebase, on PR merge (see ADR 0004).
- Every file carries SPDX license metadata (REUSE 3.0). New files: run
  `scripts/annotate.sh`. The CI `lint-reuse` job blocks merges on missing
  metadata. See CONTRIBUTING.md for the conventions, including the
  YAML-frontmatter quirk for ADRs vs. Claude skills.

## Testing checklist (manual)

The "long sleep" entry below is intentionally qualitative. macOS does not
expose a single threshold above which post-wake behavior is meaningfully
different. Use this rule of thumb instead: a sleep is "long" if
`pmset -g log | grep -E 'Sleep|DarkWake'` shows at least one **DarkWake**
entry between Sleep and the user-initiated Wake. DarkWakes are the
maintenance wakes that exercise power-management transitions most likely
to expose Alt Mode dropout and wake-settle timing bugs. In practice this
is "overnight" or "while at lunch with the lid closed for an hour or two"
on the M2 MacBook Air; specific durations vary by power profile.

- [ ] `blackoutd on` blacks out built-in
- [ ] `blackoutd off` restores built-in
- [ ] Unplugging external restores built-in unconditionally
- [ ] `blackoutd daemon stop` restores built-in before exit
- [ ] `blackoutd daemon start` after stop re-bootstraps agent
- [ ] `blackoutd status` reflects actual display state (not persisted state)
- [ ] Menu bar icon updates on state change
- [ ] Auto-blackout toggle applies immediately if external already connected
- [ ] Disabling auto-blackout restores built-in if currently blacked out
- [ ] `make clean && make && make reinstall` cycle succeeds (sudo prompt
      during privileged writes; do NOT prefix with `sudo`)
- [ ] Wake from short sleep (`pmset sleepnow` or lid-close ≤ 1 minute)
      re-blacks out within 3 seconds
- [ ] Wake from long sleep (overnight, or any sleep with at least one
      DarkWake in `pmset -g log`) re-blacks out; external survives Alt
      Mode dropout window
- [ ] Lid-close sleep behaves like `pmset sleepnow`

## Open work and roadmap

Two complementary trackers; consult both for context:

- **`docs/technical-debt.md`** — engineering items organized by priority
  (P0–P9) with problem statements, root causes, and acceptance criteria.
  This is the source of truth for "what's the next engineering thing to
  work on". Items here may or may not be assigned to a specific milestone.
- **`ROADMAP.md`** — milestone plan organized by version (v0.1, v0.2,
  ..., v1.0, Future). Cross-references the P-numbers from
  `docs/technical-debt.md`. The source of truth for "what release does
  this go into".

Closed and partially-done items remain visible in `docs/technical-debt.md`
to preserve rationale and acceptance-criteria history. README.md "Known
issues" is separate — it documents user-visible limitations rather than
engineering debt.

The next priority after v0.2 is **P4 — Mach IPC command channel** (v1.0
target). Read the P4 entry in `docs/technical-debt.md` before starting
that work.

## Related projects

### `displayrecommitd`

Standalone LaunchAgent that fixes the USB-C Alt Mode wake recovery issue.
Repository: <https://github.com/toobuntu/displayrecommitd/>

- `main` branch: production daemon (`displayrecommitd.m`)
- `stash` branch: development artifacts including `displayprobe2.m`
  (IOKit DCP device proxy probing tool) and research logs

The `displayprobe.m` formerly in this repo was a sleep/wake display state
watcher used for development. `displayprobe2.m` in the displayrecommitd
stash branch probes DCP device proxy paths — a different diagnostic
concern. Neither is meant for production.

## Documents to read on first load

For non-trivial work, an agent should also read:

1. `docs/technical-debt.md` — current priorities and known issues
2. `ROADMAP.md` — milestone plan (cross-references the P-numbers above)
3. `docs/decisions/` — accepted ADRs (4 today: Trojan Source, daemon
   presence, wake-settle timer, merge strategy)
4. `CONTRIBUTING.md` — encoding policy, REUSE/SPDX conventions, commit
   and PR conventions

For PR work specifically, also:

- `docs/handoff/chat-claude.md` (if present) — narrative recap of the current PR's
  history
- `docs/handoff/code-claude.md` (if present) — state snapshot and open
  questions specific to the current Claude Code session
- `docs/reviews/` (if present) — captured PR reviews from external tools
