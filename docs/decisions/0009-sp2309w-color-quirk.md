---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 9
title: SP2309W color-cast correction as an opt-in quirk module
status: proposed
date: 2026-07-20
decision-makers:
  - toobuntu
---

# SP2309W color-cast correction as an opt-in quirk module

> Recorded retroactively. The decision was sketched 2026-05-21/26 in
> technical-debt P26, the 2026-05-25 session handoff, and the
> `inject_edid` project's ADRs 0001–0002, all of which already cite
> "ADR 0009"; this document writes down what those sources agreed on.
> Status stays `proposed` until the module lands (or the standalone
> alternative is chosen instead) — P26's first acceptance criterion.

## Context and Problem Statement

The maintainer's Dell SP2309W (2008, 8-bit RGB TN, native 2048×1152)
ships a *defective* EDID: block 0 declares RGB, but the CTA-861
extension (byte 131, bits 5–4) wrongly advertises YCbCr 4:4:4/4:2:2.
macOS trusts the extension and negotiates YCbCr — which the panel has
no decode path for — producing the pink cast (green when the OSD is
set to YPbPr). A 2010 production run shipped a corrected RGB-only
EDID; no firmware update exists for this unit, so correction is
host-side forever.

The `inject_edid` project settled the mechanism and the host:

- **ADR 0001 (inject_edid)** — runtime virtual-EDID injection via the
  private `IOAVServiceSetVirtualEDIDMode`, patching only CEA byte 131
  (clear bits 5–4, fix the extension checksum). The filesystem
  override mechanism is non-functional on Apple Silicon; DDC-driven
  re-set is reactive and proprietary; a hardware EDID emulator fails
  the no-spend constraint.
- **ADR 0002 (inject_edid)** — the correction is a non-resident
  one-shot (the mapping survives process exit and display sleep,
  reverts on full system sleep) fired from **blackoutd** on external
  connect and after the wake-settle, because blackoutd is the single
  actor on the reconfiguration callback and renegotiation is driven
  by the same CG recommit blackoutd already owns; a second daemon
  reintroduces the two-actor race behind the 2026-05-19 12:10
  incident.

That leaves the blackoutd-side question this ADR answers: **how does a
general-purpose daemon carry a correction that applies to exactly one
monitor model, without burdening every other user with dead code and
extra private-API surface?**

Orthogonality note (P29 insists): this is the *color-encoding* defect.
It is unrelated to cursor-on-black, which is the absence of scanout —
the two must not be entangled in code or triggers.

## Decision Drivers

* Other users must carry no Dell-specific dead code and no additional
  private-API surface in their binaries.
* One display actor: the correction must ride blackoutd's existing
  callback and wake-settle timing (inject_edid ADR 0002).
* The single-monitor scope argues against any generality beyond one
  guarded hook (YAGNI).
* The unconditional safety invariant must be untouched.

## Considered Options

* **Opt-in, isolated quirk module compiled under `make QUIRKS=sp2309w`**
  (chosen, proposed).
* Compile the quirk in unconditionally, gate at runtime only.
* A generic quirk framework (registry, per-display hooks).
* Standalone resident daemon.
* Do nothing (keep BetterDisplay + watchdog).

## Decision Outcome

Chosen: host the correction as an **opt-in, isolated quirk module**,
because it keeps every non-Dell build free of the quirk's code and
private-API fragility while giving the quirk build blackoutd's
single-actor timing:

* Its own translation unit, `src/quirks/DisplayColorController.{h,m}`
  — a sibling to `DisplayController`, not code woven into it.
* Compiled **only** under `make QUIRKS=sp2309w`
  (`-DBLACKOUTD_QUIRK_SP2309W`). A default `make` produces a binary
  with zero quirk symbols and no reference to
  `IOAVServiceSetVirtualEDIDMode`.
* Runtime-keyed to vendor `0x10AC` / product `0xD01D` even when
  compiled in — a quirk build attached to any other monitor does
  nothing.
* Attached through **one narrow hook** in the core (external-connect
  and post-wake-settle, before the blackout commit — never during
  pipeline churn), not a generic quirk framework: no other quirks are
  planned, and a framework for n=1 is YAGNI.
* The module re-derives the external `DCPAVServiceProxy` on each
  event and holds no resident `IOAVServiceRef`; the induced
  reconfiguration is marked self-originated (an
  `_actionInProgress`-style suppression) **without weakening the
  unconditional safety-invariant check**.

### Consequences

* Good, because other users' builds carry no Dell-specific code, no
  extra private-API dependency, and no behavioral difference — the
  quirk cannot regress the core for anyone who does not opt in.
* Good, because the quirk user gets a preventive fix (YCbCr never
  negotiated) applied at exactly the right moments by the actor that
  already owns the timing, retiring the BetterDisplay +
  `restore_rgb.sh` watchdog.
* Bad, because `IOAVServiceSetVirtualEDIDMode` is private and fragile
  across macOS updates — but that surface exists only in quirk builds.
* Bad, because a compile-time flag means no single released binary
  serves both audiences, and the `QUIRKS=sp2309w` configuration needs
  its own build check (or knowingly stays maintainer-built-only).
* Neutral, because accepting this ADR is P26's first acceptance
  criterion; if the standalone-daemon alternative is chosen instead,
  this ADR moves to `rejected` and inject_edid ADR 0002 gets a
  superseding note.

### Confirmation

Pending — the module has not landed. The underlying mechanism is
confirmed in the standalone tool (inject_edid ADR 0002: cast cleared,
`YCbCr 4:4:4 Limited` → `RGB Full`, CEA byte 131 `0xF1` → `0xC1`);
what remains is the hosted form: no competing actor, no safety-
invariant interaction, re-application on each wake via the
wake-settle hook.

## Pros and Cons of the Options

### Compile the quirk in unconditionally, gate at runtime only

* Rejected: every user carries dead Dell code and the private-API
  reference; the runtime key alone does not remove the fragility
  surface from their binaries.

### A generic quirk framework (registry, per-display hooks)

* Rejected as YAGNI: exactly one quirk exists or is planned. One
  `#ifdef`-guarded hook is cheaper to read and delete.

### Standalone resident daemon

* Rejected in inject_edid ADR 0002: reintroduces the two-actor race
  on the reconfiguration callback (nested CG transactions, err=1014).

### Do nothing (keep BetterDisplay + watchdog)

* Rejected: proprietary, reactive (the cast appears, then clears),
  and a competing display actor. MonitorControlLite is retained for
  brightness precisely because it avoids DDC and does not trigger
  renegotiation.

## More Information

* Technical-debt **P26** — the tracking entry whose acceptance
  criteria mirror this ADR.
* `inject_edid` ADRs 0001 (why runtime injection) and 0002 (why
  blackoutd hosts the one-shot), `inject_edid/docs/sp2309w-display-notes.md`
  (EDID decode, firmware investigation), and
  `inject_edid/docs/investigations/connection-mode.md` (the
  YCbCr→RGB flip measurement; CEA byte 131 `0xF1` → `0xC1`).
* `docs/SESSION-HANDOFF-2026-05-25.md` — the panel-defect summary and
  the do-not-entangle instruction (track D).
