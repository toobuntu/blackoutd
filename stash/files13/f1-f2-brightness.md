---
name: "[Feature] F1/F2 brightness control and ambient light sync for external display"
about: Track implementation of keyboard brightness keys and ALS sync
labels: enhancement
---

## Summary

When the built-in display is blacked out, F1/F2 (brightness down/up) currently
have no effect on the external display. Additionally, the MacBook's ambient light
sensor (ALS) adjusts the built-in's brightness automatically but this signal is
not forwarded to the external display.

## Desired behaviour

1. **F1/F2 control**: While the built-in is blacked out, F1/F2 should adjust the
   external display's brightness as if it were the primary display.
2. **ALS sync**: Optionally, the external display's brightness should track the
   built-in's ambient-light-corrected brightness automatically.

## Implementation notes

### Brightness control via IOKit
```objc
#import <IOKit/graphics/IOGraphicsLib.h>

// Get current brightness
float brightness;
IODisplayGetFloatParameter(service, 0, CFSTR(kIODisplayBrightnessKey), &brightness);

// Set brightness
IODisplaySetFloatParameter(service, 0, CFSTR(kIODisplayBrightnessKey), newValue);
```
`service` is an `io_service_t` obtained via `IOServiceGetMatchingServices` with
`IODisplayMatching` for the target display.

### Alternative: DisplayServices private framework
`DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` in
`/System/Library/PrivateFrameworks/DisplayServices.framework` — simpler API but
private. Needs symbol verification on target macOS versions.

### ALS sync
Register for `CGDisplayRegisterReconfigurationCallback` brightness change events
or observe `NSWorkspace` notifications. Map the built-in brightness value to the
external display's range via `IODisplayGetFloatParameter` for min/max.

### F1/F2 key interception
Use `CGEventTapCreate` with `kCGHIDEventTap` to intercept media key events
(`NX_KEYTYPE_BRIGHTNESS_DOWN` / `NX_KEYTYPE_BRIGHTNESS_UP`) when built-in is
blacked out, and remap them to `IODisplaySetFloatParameter` calls on the external.
Requires Accessibility permission.

## Caveats

- DDC brightness control only works for external displays that support it. USB-C
  displays using DisplayPort Alt Mode typically do. Older HDMI-only displays may
  not respond.
- Accessibility permission required for event tap (F1/F2 interception).
- ALS sync adds continuous background I/O — should be opt-in.

## References

- [IOKit Graphics headers](https://github.com/apple-oss-distributions/IOKitUser)
- [monitorcontrol](https://github.com/MonitorControl/MonitorControl) — open-source
  reference implementation for DDC brightness on macOS
