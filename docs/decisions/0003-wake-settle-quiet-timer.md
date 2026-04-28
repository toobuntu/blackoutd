---
number: 3
title: Wake-settle quiet timer for display recovery
status: accepted
date: 2026-04-27
decision-makers:
  - toobuntu
---

# Wake-settle quiet timer for display recovery

## Context and Problem Statement

Two distinct display problems must be addressed on every system wake:

1. **P0 — Wake auto-blackout**: with the external display connected and
   auto-blackout enabled, the built-in must re-black-out after sleep/wake.
   The display system is still settling when `NSWorkspaceDidWakeNotification`
   fires; a naive immediate re-apply races against display re-enumeration
   and can be suppressed by `_actionInProgress` or skipped because the
   external is not yet visible.

2. **P2 — USB-C Alt Mode wake recovery**: with the built-in suppressed and
   USB-C→HDMI as the sole display path, the USB-C controller drops Alt
   Mode negotiation approximately 30 seconds after wake. The external
   display goes black; the user must unplug/replug the cable. A no-op
   `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration`
   transaction issued after the pipeline re-settles causes WindowServer
   to absorb the reconnected display state without visible flicker.

Both problems share a timing constraint: the work must be done **after**
the display pipeline has stopped issuing reconfiguration callbacks, not
during the churn. A fixed delay (`dispatch_after`) is wrong because
churn duration varies; observed range is 0.3 to 14 seconds.

## Decision Drivers

* Single mechanism for both P0 and P2 (they trigger on the same event:
  pipeline-quiet after wake)
* Fires after pipeline genuinely settled, not during churn
* Owned by `DisplayController` (which already receives the
  `CGDisplayReconfigurationCallback`s)
* Cancellable on system sleep, on the rare double-wake scenario, and on
  daemon shutdown
* No public API can definitively signal "pipeline settled"; a heuristic
  is unavoidable

## Considered Options

* **Quiet timer reset by every reconfiguration callback**
* **Fixed `dispatch_after` 2 seconds post-wake**
* **Poll display configuration repeatedly until stable**
* **`IOServiceRequestProbe` on the display IOService**

## Decision Outcome

Chosen option: **Quiet timer reset by every reconfiguration callback**.

On `NSWorkspaceDidWakeNotification`, `AppDelegate` calls
`-[DisplayController handleSystemWake]`, which arms a `dispatch_source_t`
timer with a 2-second initial delay. Each `CGDisplayReconfigurationCallback`
(excluding `kCGDisplayBeginConfigurationFlag` events) cancels and recreates
the timer. When the timer fires without having been pushed back for 2 full
seconds, the pipeline is considered quiet and the handler:

1. Issues a no-op CGConfig recommit (P2 fix).
2. Re-checks the safety invariant: if no external display is present and
   the built-in is currently blacked out, restore the built-in. (Closes
   a window where an external unplugged during sleep was missed by the
   `_externalDisconnectedDuringSleep` flag.)
3. Re-applies auto-blackout if the external is present and the built-in
   is not currently blacked out (P0 fix).

The 2-second window is empirical: shorter than the lower bound of
observed Alt Mode dropout timing, longer than the typical post-wake
churn duration. It is documented at the source as a heuristic that
trades a fixed user-visible delay for reliable correctness.

The timer is owned by `DisplayController`. The lifecycle and call sites:

* **Armed** in `-handleSystemWake` (called from `AppDelegate`'s
  `systemDidWake:` handler after `invalidateDisplayState` returns).
* **Reset** in `-handleReconfiguration:flags:` whenever the timer is
  already running (so each callback during pipeline churn pushes the
  fire time back another 2 seconds).
* **Cancelled** in `-invalidateDisplayState` (called from `systemDidWake:`,
  not `systemWillSleep:` — `systemWillSleep:` only sets `systemSleeping = YES`).
  Cancellation also happens implicitly when the handler block fires and
  identity-checks the captured timer pointer against `_wakeSettleTimer`.

The handler block compares its captured `dispatch_source_t` to
`_wakeSettleTimer` before doing any work. The ivar is cleared **before**
the source is cancelled, eliminating the window where a running handler
could observe a still-matching ivar after another reset path has started.

### Consequences

* Good, because both P0 and P2 are addressed by the same code path.
* Good, because the quiet-timer pattern is robust against variable
  pipeline churn duration.
* Good, because the timer is owned where the events are received,
  avoiding a layering violation that would put display logic in
  `AppDelegate`.
* Bad, because the 2-second window is a heuristic; pathological cases
  with intermittent callbacks longer than 2 seconds apart could fire
  prematurely. None observed in testing.
* Bad, because `IOServiceRequestProbe` has been ruled out (returns
  `0xe00002c7 kIOReturnUnsupported` on `DCPDPDeviceProxy`); a future
  more-targeted recovery is therefore not available without private API.

### Confirmation

Manual verification in `spec/manual/TESTING.md`:

* Short sleep (under 1 minute), `pmset sleepnow`: built-in must re-black-out
  within 3 seconds of wake.
* Long sleep (over 8 hours, with maintenance dark wakes): built-in must
  re-black-out on user wake; external must not enter the Alt Mode dropout
  state.
* Lid-close sleep: same expectations as `pmset sleepnow`.

The recommit log line `[wake] — recommit after settle: ok` must appear
on every user wake; absence indicates the quiet timer never fired
(possible bug).

## Pros and Cons of the Options

### Quiet timer reset by every reconfiguration callback (chosen)

* Good, adapts to actual pipeline churn duration.
* Good, single mechanism for both P0 and P2.
* Bad, 2-second window remains a heuristic.

### Fixed `dispatch_after` 2 seconds post-wake

* Good, simpler implementation.
* Bad, fires during churn when churn lasts longer than 2 seconds; the
  recommit then has no effect because the pipeline is not yet stable.
* Bad, if churn ends earlier (e.g. 0.3s), the user waits an unnecessary
  1.7 seconds for the auto-blackout.
* Bad, no cancellation handle: a sleep within the 2-second window fires
  the handler post-next-wake when state is wrong.

### Poll display configuration repeatedly until stable

* Bad, polling is wasteful and the comparison criterion ("stable") is
  itself a heuristic.
* Bad, no clear advantage over reacting to the callback events that
  macOS already provides.

### `IOServiceRequestProbe` on `DCPDPDeviceProxy`

* Investigated and rejected. Returns `kIOReturnUnsupported (0xe00002c7)`
  on the M2 MacBook Air's `DCPDPDeviceProxy` service. The DCP framework
  does not implement the probe method.
* Documented in `displayrecommitd` repo (companion project) under
  `displayprobe2.m`.

## More Information

* `displayrecommitd` companion project at
  https://github.com/toobuntu/displayrecommitd — same fix as a
  standalone daemon for systems where blackoutd is not present
* BetterDisplay class-dump reveals private property
  `_disconnectReconnectedDisplaysAfterWake` and method
  `_reinitializeOnWake`, suggesting Apple's preferred fix at the
  framework level. Public-API equivalent is the CGConfig recommit used
  here.
* Observed Alt Mode dropout timing is documented in pmset and
  WindowServer log captures attached to the project's investigation
  notes.
