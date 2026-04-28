---
number: 2
title: Mach port for daemon presence; sysctl for PID
status: accepted
date: 2026-04-27
decision-makers:
  - toobuntu
---

# Mach port for daemon presence; sysctl for PID

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
* Cannot mis-signal a non-daemon process that happens to share the binary
  name (e.g. a concurrently running CLI invocation, a developer running
  the binary directly)
* macOS-native APIs only; no third-party dependencies

## Considered Options

* **Mach port (`bootstrap_look_up`) for liveness; sysctl for PID**
* **Mach port for liveness; Mach IPC for command delivery (no signals)**
* **PID file written by daemon at startup**
* **Continue parsing `launchctl list`**

## Decision Outcome

Chosen option: **Mach port for liveness, sysctl + path verification for
PID discovery**.

The daemon registers a Mach service via the `MachServices` key in its
LaunchAgent plist and calls `bootstrap_check_in()` at startup to hold the
receive right. The CLI calls `bootstrap_look_up()` to test liveness:
`KERN_SUCCESS` means the daemon is running, any other return means it is
not.

For PID discovery, the CLI enumerates processes via `sysctl(KERN_PROC)`
and selects a process matching all of:

1. `p_comm == "blackoutd"` (the binary name; truncated by the kernel to
   `MAXCOMLEN` = 16 characters, which `blackoutd` (9) fits within)
2. Parent PID is `1` (launchd) — distinguishes the LaunchAgent from
   any concurrently running CLI invocations or developer-run instances
3. Not the calling process itself (the CLI shares `p_comm` with the
   daemon, since they are the same binary)

Mach IPC for command delivery (replacing signals entirely) is **deferred to
v1.0**; signals remain the v0.2 command channel. The sysctl PID lookup is
therefore still needed.

### Consequences

* Good, because liveness is authoritative and zero-cost — no subprocess,
  no parsing, no race window between check and use.
* Good, because the launchd-parent check eliminates the
  concurrent-CLI false-positive that plain `p_comm` matching would
  produce.
* Good, because all APIs used are macOS-stable: `bootstrap_look_up`,
  `sysctl(KERN_PROC)`, and the `kp_eproc.e_ppid` field have stable
  semantics documented in the system headers.
* Bad, because `p_comm` is truncated to 16 characters; if the binary is
  ever renamed beyond that limit, the PID lookup must be revised. A
  comment in `daemonPid()` documents this constraint.
* Bad, because `sysctl(KERN_PROC)` requires retry on `ENOMEM` when the
  process table grows between the sizing call and the data call. The
  retry loop must release any prior buffer on every failure path.
* Neutral, because v1.0 will replace this with full Mach IPC, eliminating
  PID discovery entirely.

### Confirmation

A unit test (or manual smoke test in `spec/manual/TESTING.md`) confirms
that `daemonPid()` returns 0 when the daemon is stopped via `daemon stop`,
and returns the daemon's PID when it is bootstrapped. A second test runs a
second `blackoutd status` invocation concurrently with the daemon and
confirms the CLI's own PID is never returned to itself.

## Pros and Cons of the Options

### Mach port for liveness; sysctl + path verification for PID (chosen)

* Good, mixes authoritative liveness with bounded-cost PID discovery.
* Good, `MachServices` is the launchd-blessed mechanism for daemon
  presence on macOS.
* Bad, two mechanisms instead of one; mitigated by clear comments and
  a path forward to single-mechanism Mach IPC.

### Mach port for liveness; Mach IPC for command delivery

* Good, single mechanism end-to-end; no PID discovery needed.
* Good, structured request/response replaces fire-and-forget signals.
* Bad, larger v0.2 surface area; risk of shipping with bugs in the
  message-handling path.
* Deferred to v1.0 once the simpler signal-based command channel is
  proven stable.

### PID file at known location

* Good, simple read-and-parse on the CLI side.
* Bad, stale-PID-file races on crash, on power loss, on `kill -9`.
* Bad, requires daemon-side cleanup-on-exit code that may not run.
* Bad, file-system-based IPC is generally inferior to kernel-mediated IPC
  on macOS where Mach is available.

### Continue parsing `launchctl list`

* Good, no code change needed.
* Bad, output is documented as not stable; future macOS versions may
  change format.
* Bad, requires a subprocess for every status check.
* Bad, the old implementation matched on the agent label as a substring,
  which could match unrelated agents.

## More Information

* `man launchctl` — documents the "NOT API" status of list output
* `<servers/bootstrap.h>` — `bootstrap_check_in`, `bootstrap_look_up`
* `<sys/sysctl.h>`, `<sys/proc.h>` — `kp_proc.p_comm`, `kp_eproc.e_ppid`
