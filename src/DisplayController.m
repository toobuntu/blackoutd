/*
 * SPDX-FileCopyrightText: Copyright 2026–Present Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// Private APIs used in this file:
//
//   CGSConfigureDisplayEnabled  — enables/disables a display in a CGDisplayConfigRef.
//                                 No public equivalent exists.
//
//   CGDisplayIOServicePort      — returns the IOKit service port for a CGDirectDisplayID.
//                                 Deprecated macOS 10.9; no public replacement provided
//                                 by Apple. Used to distinguish hardware-backed displays
//                                 from virtual/placeholder displays. See
//                                 displayIsHardwareBacked().

#import "DisplayController.h"
#import <IOKit/IOKitLib.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);

// File-static verbosity level, kept in sync with the verbosityLevel property.
// Accessible from both static C functions and instance methods.
// Level 1 (default): semantic logs only.
// Level 2 (verbose): semantic logs plus [verbose]-tagged detail lines.
static NSInteger BDVerbosityLevel = 1;

// Level-1 lines always log. Level-2 lines log only when verbosity >= 2,
// prefixed with [verbose] so they are visually distinct and greppable.
#define BDLog(level, fmt, ...) \
    do { \
        if ((level) == 1) { NSLog(fmt, ##__VA_ARGS__); } \
        else if ((level) == 2 && BDVerbosityLevel >= 2) { NSLog(@"[verbose=2] " fmt, ##__VA_ARGS__); } \
    } while (0)

// Returns YES if this CGDirectDisplayID is backed by real hardware.
//
// Primary check: CGDisplayIOServicePort returns MACH_PORT_NULL for virtual
// and placeholder displays inserted by macOS during display transitions.
// Deprecated since macOS 10.9 with no public replacement provided by Apple.
//
// Fallback: if the primary check returns null — either a virtual display or
// the API has been removed — the FourCC heuristic applies. macOS assigns
// pseudo-vendor IDs > 0xFFFF to virtual displays (e.g. "unkn" = 0x756E6B6E,
// "virt" = 0x76697274). Real PCI vendor IDs are 16-bit. This is a macOS
// convention, independent of any third-party software.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static BOOL displayIsHardwareBacked(CGDirectDisplayID displayID) {
    if (CGDisplayIOServicePort(displayID) != MACH_PORT_NULL) return YES;
    return CGDisplayVendorNumber(displayID) <= 0xFFFF;
}
#pragma clang diagnostic pop

// Returns a human-readable vendor name for common PCI vendor IDs,
// or a decoded FourCC string for macOS virtual display pseudo-IDs.
static NSString *vendorDescription(uint32_t vendor) {
    if (vendor > 0xFFFF) {
        char fourcc[5] = {
            (char)(vendor >> 24), (char)(vendor >> 16),
            (char)(vendor >> 8),  (char)(vendor),
            '\0'
        };
        return [NSString stringWithFormat:@"0x%x \"%s\" (virtual)", vendor, fourcc];
    }
    switch (vendor) {
        case 0x0000: return @"0x0000 (unknown)";
        case 0x05AC: return @"0x05ac (Apple)";
        case 0x0610: return @"0x0610 (Apple)";
        case 0x0614: return @"0x0614 (Apple)";
        case 0x0618: return @"0x0618 (Apple)";
        case 0x10AC: return @"0x10ac (Dell)";
        case 0x1028: return @"0x1028 (Dell)";
        case 0x1E6D: return @"0x1e6d (LG)";
        case 0x038A: return @"0x038a (LG Philips)";
        case 0x0492: return @"0x0492 (Samsung)";
        case 0x1152: return @"0x1152 (Samsung)";
        case 0x0410: return @"0x0410 (Sharp)";
        case 0x0430: return @"0x0430 (Fujitsu)";
        case 0x04CA: return @"0x04ca (Lite-On)";
        case 0x06B3: return @"0x06b3 (Sunrex)";
        default:     return [NSString stringWithFormat:@"0x%04x", vendor];
    }
}

// Returns a decoded string of all CGDisplayChangeSummaryFlags bits set.
static NSString *flagsDescription(CGDisplayChangeSummaryFlags flags) {
    NSMutableArray *names = [NSMutableArray array];
    if (flags & kCGDisplayAddFlag)                 [names addObject:@"add"];
    if (flags & kCGDisplayRemoveFlag)              [names addObject:@"remove"];
    if (flags & kCGDisplayEnabledFlag)             [names addObject:@"enabled"];
    if (flags & kCGDisplayDisabledFlag)            [names addObject:@"disabled"];
    if (flags & kCGDisplayMovedFlag)               [names addObject:@"moved"];
    if (flags & kCGDisplaySetMainFlag)             [names addObject:@"setMain"];
    if (flags & kCGDisplaySetModeFlag)             [names addObject:@"setMode"];
    if (flags & kCGDisplayMirrorFlag)              [names addObject:@"mirror"];
    if (flags & kCGDisplayUnMirrorFlag)            [names addObject:@"unmirror"];
    if (flags & kCGDisplayDesktopShapeChangedFlag) [names addObject:@"desktopShapeChanged"];
    return names.count > 0
        ? [NSString stringWithFormat:@"0x%x (%@)", flags, [names componentsJoinedByString:@"|"]]
        : [NSString stringWithFormat:@"0x%x", flags];
}

// Returns only the names of connectivity-relevant flags, without hex value.
static NSString *connectivityFlagNames(CGDisplayChangeSummaryFlags flags) {
    NSMutableArray *names = [NSMutableArray array];
    if (flags & kCGDisplayAddFlag)      [names addObject:@"add"];
    if (flags & kCGDisplayRemoveFlag)   [names addObject:@"remove"];
    if (flags & kCGDisplayEnabledFlag)  [names addObject:@"enabled"];
    if (flags & kCGDisplayDisabledFlag) [names addObject:@"disabled"];
    return names.count > 0 ? [names componentsJoinedByString:@"|"] : @"none";
}

// Translates CGDisplayChangeSummaryFlags to a semantic event name.
// Connectivity flags take precedence; mirror/unmirror are checked next;
// layout-only changes (e.g. desktopShapeChanged) are named explicitly.
static NSString *displayEventName(CGDisplayChangeSummaryFlags flags) {
    if (flags & (kCGDisplayAddFlag | kCGDisplayEnabledFlag))     return @"connected";
    if (flags & (kCGDisplayRemoveFlag | kCGDisplayDisabledFlag)) return @"disconnected";
    if (flags & kCGDisplayMirrorFlag)                            return @"mirrored";
    if (flags & kCGDisplayUnMirrorFlag)                          return @"unmirrored";
    if (flags & kCGDisplayDesktopShapeChangedFlag)               return @"shape";
    const CGDisplayChangeSummaryFlags connectivity =
        kCGDisplayAddFlag | kCGDisplayRemoveFlag |
        kCGDisplayEnabledFlag | kCGDisplayDisabledFlag;
    if (!(flags & connectivity))                                  return @"layout";
    return @"unknown";
}

static void displayReconfigCallback(CGDirectDisplayID displayID,
                                    CGDisplayChangeSummaryFlags flags,
                                    void *userInfo) {
    DisplayController *controller = (__bridge DisplayController *)userInfo;
    [controller handleReconfiguration:displayID flags:flags];
}

@implementation DisplayController {
    CGDirectDisplayID _builtInID;
    BOOL _isBlackedOut;
    BOOL _actionInProgress;
    BOOL _systemSleeping;
    BOOL _externalDisconnectedDuringSleep;
    NSString *_currentAction;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _builtInID = [self discoverBuiltInID];
    _autoBlackoutOnExternalConnect = YES;
    _verbosityLevel = 1;
    NSLog(@"[startup] — session started with builtInId=%u", _builtInID);
    NSLog(@"[startup] — API deprecation: CGDisplayIOServicePort (deprecated macOS 10.9), "
          @"CGSConfigureDisplayEnabled (private); if broken audit DisplayController.m");
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                             (__bridge void *)self);
    return self;
}

- (void)dealloc {
    CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                           (__bridge void *)self);
}

- (void)setVerbosityLevel:(NSInteger)verbosityLevel {
    if (verbosityLevel == _verbosityLevel) return;
    _verbosityLevel = verbosityLevel;
    BDVerbosityLevel = verbosityLevel;
    NSLog(@"[prefs] verbosityLevel=%ld", (long)verbosityLevel);
}

- (BOOL)isBlackedOut { return _isBlackedOut; }

// MARK: - Public

- (BOOL)enableBlackout {
    if (_isBlackedOut) return YES;
    if (![self hasActiveExternalDisplay]) {
        NSLog(@"[state] hasExternal=0 — blackout refused, no active external display");
        return NO;
    }
    NSLog(@"[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating blackout");
    [self applyEnable:NO];
    return _isBlackedOut;
}

- (BOOL)disableBlackout {
    if (!_isBlackedOut) return YES;
    [self applyEnable:YES];
    return !_isBlackedOut;
}

// Returns YES only for physically connected external displays.
// Relies on IOKit service presence (with FourCC fallback) to exclude
// virtual/placeholder displays inserted by macOS during display transitions.
- (BOOL)hasActiveExternalDisplay {
    CGDirectDisplayID displays[8];
    uint32_t count = 0;
    CGGetActiveDisplayList(8, displays, &count);
    BOOL found = NO;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = displays[i];
        if (CGDisplayIsBuiltin(d)) continue;
        uint32_t vendor = CGDisplayVendorNumber(d);
        if (displayIsHardwareBacked(d)) {
            BDLog(1, @"[external] id=%u vendor=%@ — hardware display detected",
                  d, vendorDescription(vendor));
            found = YES;
        } else {
            BDLog(1, @"[external] id=%u vendor=%@ — virtual display disregarded",
                  d, vendorDescription(vendor));
        }
    }
    return found;
}

- (BOOL)builtInIsOnline {
    CGDirectDisplayID displays[8];
    uint32_t count = 0;
    CGGetOnlineDisplayList(8, displays, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) return YES;
    }
    return NO;
}

- (void)adoptBlackedOutState {
    _isBlackedOut = YES;
}

- (BOOL)invalidateDisplayState {
    BOOL disconnected = _externalDisconnectedDuringSleep;
    _actionInProgress = NO;
    _externalDisconnectedDuringSleep = NO;
    return disconnected;
}

// MARK: - Private

- (void)applyEnable:(BOOL)enable {
    _currentAction = enable ? @"restore" : @"blackout";
    NSLog(@"[builtin] id=%u action=%@ result=pending isBlackedOut=%d",
          _builtInID, _currentAction, _isBlackedOut);
    _actionInProgress = YES;
    CGError err = [self setDisplay:_builtInID enabled:enable];
    if (err != kCGErrorSuccess) {
        // kCGErrorIllegalArgument (1001) means the display is already in the
        // requested state — another process changed it before we could. Treat
        // as success and sync internal state accordingly.
        if (err == kCGErrorIllegalArgument) {
            NSLog(@"[builtin] id=%u action=%@ result=synced — already in desired state",
                  _builtInID, _currentAction);
        } else {
            NSLog(@"[builtin] id=%u action=%@ result=failed err=%d",
                  _builtInID, _currentAction, err);
            _actionInProgress = NO;
            return;
        }
    }
    _isBlackedOut = !enable;
    NSLog(@"[builtin] id=%u action=%@ result=complete isBlackedOut=%d",
          _builtInID, _currentAction, _isBlackedOut);
    [_delegate displayController:self blackoutStateChanged:_isBlackedOut];

    // macOS fires CGDisplayReconfigurationCallbacks as side effects of the
    // config change. These arrive asynchronously, sometimes hundreds of
    // milliseconds after the API call returns. _actionInProgress suppresses
    // them so they are not mistaken for external display connect/disconnect
    // events. The 2-second window is conservative; in practice echoes arrive
    // within ~300ms, but we allow extra margin for slow or loaded systems.
    //
    // A real display event (e.g. unplug) arriving inside the window will be
    // suppressed along with the echoes. To recover, the safety invariant is
    // re-evaluated when the window closes.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            self->_actionInProgress = NO;
            NSLog(@"[builtin] id=%u action=%@ result=settled isBlackedOut=%d",
                  self->_builtInID, self->_currentAction, self->_isBlackedOut);
            if (self->_isBlackedOut && ![self hasActiveExternalDisplay]) {
                NSLog(@"[state] hasExternal=0 isBlackedOut=1 — no external display, disabling blackout (missed during action window)");
                [self applyEnable:YES];
            }
        });
}

- (CGDirectDisplayID)discoverBuiltInID {
    CGDirectDisplayID displays[8];
    uint32_t count = 0;
    CGGetOnlineDisplayList(8, displays, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    }
    return 1;
}

- (CGError)setDisplay:(CGDirectDisplayID)display enabled:(BOOL)enabled {
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) return err;
    err = CGSConfigureDisplayEnabled(config, display, enabled);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return err;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}

- (void)handleReconfiguration:(CGDirectDisplayID)displayID
                         flags:(CGDisplayChangeSummaryFlags)flags {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if (_systemSleeping) {
        BOOL isDisconnect = flags & (kCGDisplayRemoveFlag | kCGDisplayDisabledFlag);
        BOOL isExternal   = displayID != _builtInID;
        if (isDisconnect && isExternal && _isBlackedOut) {
            BDLog(1, @"[change] id=%u event=%@ — external disconnect noted during sleep",
                  displayID, displayEventName(flags));
        } else {
            BDLog(1, @"[change] id=%u event=%@ — ignored, sleeping",
                  displayID, displayEventName(flags));
        }
        return;
    }

    const CGDisplayChangeSummaryFlags connectivity =
        kCGDisplayAddFlag | kCGDisplayRemoveFlag |
        kCGDisplayEnabledFlag | kCGDisplayDisabledFlag;

    NSString *event = displayEventName(flags);

    if (!(flags & connectivity)) {
        BDLog(1, @"[change] id=%u event=%@ — ignored, no connectivity change", displayID, event);
        BDLog(2, @"id=%u event=%@ flags=%@ connectivity=%@ — ignored, no connectivity change",
              displayID, event, flagsDescription(flags), connectivityFlagNames(flags));
        return;
    }

    if (_actionInProgress) {
        BDLog(1, @"[change] id=%u event=%@ — ignored, action in progress",
              displayID, event);
        BDLog(2, @"id=%u event=%@ flags=%@ connectivity=%@ — ignored, action in progress (%@)",
              displayID, event, flagsDescription(flags), connectivityFlagNames(flags), _currentAction);
        return;
    }

    NSString *displayClass = (displayID == _builtInID) ? @"builtin"
                           : displayIsHardwareBacked(displayID) ? @"hardware"
                           : @"virtual";
    BDLog(1, @"[change] id=%u event=%@ class=%@", displayID, event, displayClass);
    BDLog(2, @"[change] id=%u event=%@ class=%@ flags=%@ connectivity=%@",
          displayID, event, displayClass, flagsDescription(flags), connectivityFlagNames(flags));

    BOOL hasExternal = [self hasActiveExternalDisplay];

    // Safety invariant: restore built-in whenever no real external is present.
    if (!hasExternal && _isBlackedOut) {
        NSLog(@"[state] hasExternal=0 isBlackedOut=1 — no external display, disabling blackout");
        [self applyEnable:YES];
    } else if (hasExternal && _autoBlackoutOnExternalConnect && !_isBlackedOut) {
        NSLog(@"[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating blackout action");
        [self applyEnable:NO];
    } else {
        NSLog(@"[state] hasExternal=%d autoBlackout=%d isBlackedOut=%d — no action",
              hasExternal, _autoBlackoutOnExternalConnect, _isBlackedOut);
    }
}

@end
