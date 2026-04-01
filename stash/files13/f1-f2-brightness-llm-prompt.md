## LLM prompt for implementing this feature

```
I'm working on blackoutd, a macOS Objective-C LaunchAgent daemon that blacks out
the MacBook built-in display when an external display is connected. The project
uses private CoreGraphics/SkyLight APIs (no Xcode project, compiled with clang
directly). Context: https://github.com/toobuntu/blackoutd

I want to implement two related features:

1. F1/F2 brightness control: when the built-in display is blacked out, intercept
   F1 (NX_KEYTYPE_BRIGHTNESS_DOWN) and F2 (NX_KEYTYPE_BRIGHTNESS_UP) HID events
   via CGEventTapCreate and redirect them to adjust the external display's
   brightness via IOKit (IODisplaySetFloatParameter with kIODisplayBrightnessKey)
   or DisplayServices private framework. The event tap should only be active when
   blackoutd is in blacked-out state.

2. Ambient light sync: optionally observe the built-in display's brightness
   changes (driven by the MacBook's ALS) and mirror the relative brightness level
   to the external display.

The project is structured as:
- DisplayController.m — owns all display state and CGDisplay callbacks
- AppDelegate.m — NSApplication delegate, menu bar, signal handlers

Please implement these features in the existing class structure. Note:
- Accessibility permission is required for CGEventTapCreate — handle the
  permission request gracefully and disable the feature if denied.
- DDC control may not work on all external displays — fail silently.
- The ALS sync should be opt-in (off by default), stored in NSUserDefaults
  suite "local.blackoutd.prefs" key "alsBrightnessSync".
- Target macOS 13+, Apple Silicon, clang with -fobjc-arc.
- No third-party dependencies.
- Follow the existing code style: minimal comments, self-documenting names,
  private methods prefixed with no underscore, all CGS calls go through a
  single helper method.

Show the full implementation of the new/modified methods only, not the entire
existing file.
```
