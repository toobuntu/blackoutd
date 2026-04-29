---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 2
title: sysctl-based daemon presence and PID detection
status: accepted
date: 2026-04-27
decision-makers:
  - toobuntu
---

# sysctl-based daemon presence and PID detection

## Context and Problem Statement

The CLI must determine whether the LaunchAgent daemon is running and, when
it is, deliver Unix signals (SIGUSR1, SIGUSR2, SIGHUP) to it. The previous
implementation parsed `launchctl list` output, which Apple explicitly
documents as unstable (`man launchctl`: "This output is NOT API").

Two distinct concerns must be answered:

1. **Liveness**: is the daemon currently running and accepting work?
2. **PID discovery**: which process should receive a signal?

These have different correctness requirements. Liveness must be
authoritative — a false positive sends a signal into the void, a false
negative confuses the user. PID discovery only needs to be correct for the
specific liveness-confirmed daemon; any process that is *not* the
launchd-managed daemon must not receive a signal intended for it.

## Decision Drivers

* No subprocess fork for routine status checks
* No reliance on undocumented or "NOT API" output formats
* No side-effects on the daemon's lifecycle from a presence probe
  (specifically: a status check must not cause launchd to activate the
  daemon)
* Cannot mis-signal a non-daemon process that happens to share the binary
  name (e.g. a concurrently running CLI invocation, a developer running
  the binary directly, or another user's daemon visible in unusual
  `gui/$UID` configurations)
* macOS-native APIs only; no third-party dependencies

## Considered Options

* **`sysctl(KERN_PROC)` with four-axis identity verification** for both
  liveness and PID discovery (chosen)
* **`bootstrap_look_up()` for liveness, sysctl for PID** (initial design;
  superseded)
* **`bootstrap_look_up()` for liveness, Mach IPC for command delivery (no
  signals)**
* **PID file written by daemon at startup**
* **Continue parsing `launchctl list`**

## Decision Outcome

Chosen option: **`sysctl(KERN_PROC)` enumeration with four-axis identity
verification**.

The CLI enumerates processes via `sysctl(KERN_PROC)` and selects a process
matching all of:

1. `p_comm == "blackoutd"` (the binary name; truncated by the kernel to
   `MAXCOMLEN` = 16 characters, which `blackoutd` (9) fits within)
2. Effective UID matches the calling user (`kp_eproc.e_ucred.cr_uid ==
   getuid()`) — defends against unusual `gui/$UID` configurations where
   another user's daemon might be visible
3. Parent PID is `1` (launchd) — distinguishes the LaunchAgent from any
   concurrently running CLI invocations or developer-run instances
4. Executable path matches `ProgramArguments[0]` from the LaunchAgent
   plist (read via `proc_pidpath()`) — defends against an unrelated
   binary named "blackoutd" running in the same session

The function returns the PID if a matching process exists, 0 otherwise.
Liveness is `daemonPid() > 0`. The four checks together are authoritative:
no non-daemon process can satisfy all four.

The CLI does not use `bootstrap_look_up()` for liveness. Apple's man page
documents that `bootstrap_look_up()` "may cause the launchd daemon to start
the service if it has been configured to be activated on-demand and is
not currently running." Even though `KeepAlive=true` makes activation
harmless in practice (launchd would have restarted the daemon anyway), the
side-effect is a property a presence probe should not have. The sysctl
scan is passive observation — it cannot start anything.

The daemon-side `bootstrap_check_in()` call in `AppDelegate` is retained:
it holds the Mach service receive right declared by `MachServices` in the
plist. This is the foundation for v1.0 Mach IPC (which will replace
signal-based commands with structured request/response). It is not used
by the CLI for liveness.

### Consequences

* Good, because the presence probe has no lifecycle side-effects on the
  daemon; a `blackoutd status` call cannot cause activation.
* Good, because liveness and PID discovery share a single mechanism with
  a single set of correctness conditions, simpler than the prior
  Mach-plus-sysctl design.
* Good, because the four-axis identity check eliminates every
  realistic false-positive: concurrent CLI, developer-run instance,
  unrelated binary named "blackoutd", another user's daemon.
* Good, because all APIs used are macOS-stable: `sysctl(KERN_PROC)`,
  `kp_eproc.e_ppid`, `kp_eproc.e_ucred.cr_uid`, and `proc_pidpath()`
  have stable semantics documented in the system headers.
* Bad, because `p_comm` is truncated to 16 characters; if the binary is
  ever renamed beyond that limit, the PID lookup must be revised. A
  comment in `daemonPid()` documents this constraint.
* Bad, because `sysctl(KERN_PROC)` requires retry on `ENOMEM` when the
  process table grows between the sizing call and the data call. The
  retry loop must release any prior buffer on every failure path.
* Neutral, because v1.0 will replace this with full Mach IPC, eliminating
  PID discovery entirely. The daemon-side `bootstrap_check_in()` is
  retained as the foundation for that work.

### Confirmation

A unit test (or manual smoke test in `spec/manual/TESTING.md`) confirms
that `daemonPid()` returns 0 when the daemon is stopped via `daemon stop`,
and returns the daemon's PID when it is bootstrapped. A second test runs a
second `blackoutd status` invocation concurrently with the daemon and
confirms the CLI's own PID is never returned to itself. A third (manual)
test verifies that `blackoutd status` does not activate a not-currently-
running daemon — important in a hypothetical future where on-demand
activation is enabled.

## Pros and Cons of the Options

### `sysctl(KERN_PROC)` with four-axis identity (chosen)

* Good, single mechanism for both liveness and PID discovery.
* Good, no side-effects on daemon lifecycle.
* Good, all four identity axes are stable kernel-level facts.
* Bad, every CLI invocation pays the cost of a process-table scan (~few
  ms on a typical macOS process table). Negligible for an interactive
  CLI.

### `bootstrap_look_up()` for liveness; sysctl for PID (initial design)

* Good, mixes authoritative liveness with bounded-cost PID discovery.
* Good, `MachServices` is the launchd-blessed mechanism for daemon
  presence on macOS.
* Bad, `bootstrap_look_up()` may activate an on-demand service. With
  `KeepAlive=true` this is benign in practice but is a documented
  side-effect a presence probe should not have.
* Bad, two mechanisms instead of one; the Mach lookup added an IPC
  round-trip on every CLI invocation for fast-rejection that the sysctl
  scan handles correctly on its own.
* Bad, the four-axis sysctl check (added in v0.2 for identity safety)
  made the Mach lookup redundant for correctness; it remained only as a
  fast path that introduced a side-effect.

### `bootstrap_look_up()` for liveness; Mach IPC for command delivery

* Good, single mechanism end-to-end; no PID discovery needed.
* Good, structured request/response replaces fire-and-forget signals.
* Bad, larger v0.2 surface area; risk of shipping with bugs in the
  message-handling path.
* Deferred to v1.0 once the simpler signal-based command channel is
  proven stable. The daemon-side `bootstrap_check_in()` is retained to
  hold the receive right for this future work.

### PID file at known location

* Good, simple read-and-parse on the CLI side.
* Bad, stale-PID-file races on crash, on power loss, on `kill -9`.
* Bad, requires daemon-side cleanup-on-exit code that may not run.
* Bad, file-system-based IPC is generally inferior to kernel-mediated
  IPC on macOS where Mach is available — though here we use neither and
  prefer sysctl for its passivity.

### Continue parsing `launchctl list`

* Good, no code change needed.
* Bad, output is documented as not stable; future macOS versions may
  change format.
* Bad, requires a subprocess for every status check.
* Bad, the old implementation matched on the agent label as a substring,
  which could match unrelated agents.

## More Information

* `man launchctl` — documents the "NOT API" status of list output
* `man bootstrap_look_up` — documents the on-demand activation
  side-effect
* `<sys/sysctl.h>`, `<sys/proc.h>` — `kp_proc.p_comm`,
  `kp_eproc.e_ppid`, `kp_eproc.e_ucred.cr_uid`
* `<libproc.h>` — `proc_pidpath()`
* `<servers/bootstrap.h>` — `bootstrap_check_in()` (retained on the
  daemon side for v1.0 Mach IPC foundation)
