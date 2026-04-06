<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Light Modes — Design Specification

Light modes repurpose the built-in display as a supplemental light source while
the external display remains the active workspace display. They are an extension
of the existing "blackout" state — the built-in is still suppressed from normal
desktop use, but instead of being fully dark it shows a controlled light pattern.

## Two Modes

### Ring Light Mode
Displays a centered annulus (ring) on a black background. The ring suggests a
photography ring light or halo. Intended for video calls, product photography,
or ambient illumination. The ring's position is fixed at screen center.

Configurable:
- **Size**: Small (25% diameter), Medium (40%), Large (60%) — set via menu
- **Stroke width**: fixed relative to ring diameter
- **Color/temperature**: Warm white (2700K-equivalent), Neutral white (4000K),
  Cool white (6500K), plus mood colors (soft amber, soft blue, soft rose)
- **Brightness**: controlled via system brightness keys (the built-in display
  brightness controls remain active even when suppressed)

Default: Medium, Warm white.

### Panel Light Mode
Fills the entire built-in display with a solid color. Simpler and brighter than
ring mode. Useful as a fill light or bounce surface.

Configurable:
- **Color/temperature**: same presets as ring mode
- **Brightness**: system brightness keys

Default: Warm white.

## Menu Bar Integration

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
- `light.panel.fill` — panel light mode
- `circle.dashed` — ring light mode

## Safety Invariant

External display disconnect **unconditionally terminates any light mode** and
restores the built-in to normal display use. This is the same invariant as
blackout mode — the built-in is never the sole active display in any suppressed
mode when no external is present.

## Persistence

The last active light mode (ring/panel) and its settings are persisted in
NSUserDefaults suite `"blackoutd"`. On wake with external connected and
`autoBlackoutOnExternalConnect` enabled, if the last state was a light mode,
that light mode is restored.

## Implementation Notes

Light mode rendering requires drawing to the built-in display's
CGDirectDisplayID. The built-in must first be suppressed via
`CGSConfigureDisplayEnabled(..., NO)`, then an overlay window renders the
pattern. The most practical public API path is a borderless `NSWindow` set to
cover the built-in display's frame, configured as a level above the desktop,
with a custom `NSView` drawing the ring or fill.

The built-in's CGDirectDisplayID is already tracked in `DisplayController`
(`_builtInID`). A new `LightModeController` class should own the overlay window
and rendering.

### New Files
- `src/LightModeController.h`
- `src/LightModeController.m`

### Modified Files
- `src/AppDelegate.m` — menu bar integration, state persistence
- `src/DisplayController.m` — mode-aware blackout state
