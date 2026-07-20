/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// Private APIs used in this file:
//
//   CGSConfigureDisplayEnabled  — enables/disables a display in a
//   CGDisplayConfigRef.
//                                 No public equivalent exists.
//
//   CGDisplayIOServicePort      — returns the IOKit service port for a
//   CGDirectDisplayID.
//                                 Deprecated macOS 10.9; no public replacement
//                                 provided by Apple. Used to distinguish
//                                 hardware-backed displays from
//                                 virtual/placeholder displays. See
//                                 displayIsHardwareBacked().

#import "DisplayController.h"
#import <IOKit/IOKitLib.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID,
                                          bool);

// File-static verbosity level, kept in sync with the verbosityLevel property.
// Accessible from both static C functions and instance methods.
// Level 1 (default): semantic logs only.
// Level 2 (verbose): semantic logs plus [verbose]-tagged detail lines.
static NSInteger BDVerbosityLevel = 1;

// Bound on the err=1014 retry loop. Each successful applyEnable: and each
// systemDidWake (via invalidateDisplayState) resets the counter, so the
// effective ceiling is "3 consecutive failures per wake cycle". The bound
// exists to prevent pathological spinning if the underlying CG framework
// stops accepting configuration calls entirely.
static const NSInteger kBDMaxFailedActionRetries = 3;

// Level-1 lines always log. Level-2 lines log only when verbosity >= 2,
// prefixed with [verbose] so they are visually distinct and greppable.
#define BDLog(level, fmt, ...)                                                 \
  do {                                                                         \
    if ((level) == 1) {                                                        \
      NSLog(fmt, ##__VA_ARGS__);                                               \
    } else if ((level) == 2 && BDVerbosityLevel >= 2) {                        \
      NSLog(@"[verbose=2] " fmt, ##__VA_ARGS__);                               \
    }                                                                          \
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
  if (CGDisplayIOServicePort(displayID) != MACH_PORT_NULL)
    return YES;
  return CGDisplayVendorNumber(displayID) <= 0xFFFF;
}
#pragma clang diagnostic pop

// Returns a human-readable vendor name for common PCI vendor IDs,
// or a decoded FourCC string for macOS virtual display pseudo-IDs.
static NSString *vendorDescription(uint32_t vendor) {
  if (vendor > 0xFFFF) {
    char fourcc[5] = {(char)(vendor >> 24), (char)(vendor >> 16),
                      (char)(vendor >> 8), (char)(vendor), '\0'};
    return [NSString stringWithFormat:@"0x%x \"%s\" (virtual)", vendor, fourcc];
  }
  switch (vendor) {
  case 0x0000:
    return @"0x0000 (unknown)";
  case 0x05AC:
    return @"0x05ac (Apple)";
  case 0x0610:
    return @"0x0610 (Apple)";
  case 0x0614:
    return @"0x0614 (Apple)";
  case 0x0618:
    return @"0x0618 (Apple)";
  case 0x10AC:
    return @"0x10ac (Dell)";
  case 0x1028:
    return @"0x1028 (Dell)";
  case 0x1E6D:
    return @"0x1e6d (LG)";
  case 0x038A:
    return @"0x038a (LG Philips)";
  case 0x0492:
    return @"0x0492 (Samsung)";
  case 0x1152:
    return @"0x1152 (Samsung)";
  case 0x0410:
    return @"0x0410 (Sharp)";
  case 0x0430:
    return @"0x0430 (Fujitsu)";
  case 0x04CA:
    return @"0x04ca (Lite-On)";
  case 0x06B3:
    return @"0x06b3 (Sunrex)";
  default:
    return [NSString stringWithFormat:@"0x%04x", vendor];
  }
}

// Returns a decoded string of all CGDisplayChangeSummaryFlags bits set.
static NSString *flagsDescription(CGDisplayChangeSummaryFlags flags) {
  NSMutableArray *names = [NSMutableArray array];
  if (flags & kCGDisplayAddFlag)
    [names addObject:@"add"];
  if (flags & kCGDisplayRemoveFlag)
    [names addObject:@"remove"];
  if (flags & kCGDisplayEnabledFlag)
    [names addObject:@"enabled"];
  if (flags & kCGDisplayDisabledFlag)
    [names addObject:@"disabled"];
  if (flags & kCGDisplayMovedFlag)
    [names addObject:@"moved"];
  if (flags & kCGDisplaySetMainFlag)
    [names addObject:@"setMain"];
  if (flags & kCGDisplaySetModeFlag)
    [names addObject:@"setMode"];
  if (flags & kCGDisplayMirrorFlag)
    [names addObject:@"mirror"];
  if (flags & kCGDisplayUnMirrorFlag)
    [names addObject:@"unmirror"];
  if (flags & kCGDisplayDesktopShapeChangedFlag)
    [names addObject:@"desktopShapeChanged"];
  return names.count > 0
             ? [NSString stringWithFormat:@"0x%x (%@)", flags,
                                          [names componentsJoinedByString:@"|"]]
             : [NSString stringWithFormat:@"0x%x", flags];
}

// Returns only the names of connectivity-relevant flags, without hex value.
static NSString *connectivityFlagNames(CGDisplayChangeSummaryFlags flags) {
  NSMutableArray *names = [NSMutableArray array];
  if (flags & kCGDisplayAddFlag)
    [names addObject:@"add"];
  if (flags & kCGDisplayRemoveFlag)
    [names addObject:@"remove"];
  if (flags & kCGDisplayEnabledFlag)
    [names addObject:@"enabled"];
  if (flags & kCGDisplayDisabledFlag)
    [names addObject:@"disabled"];
  return names.count > 0 ? [names componentsJoinedByString:@"|"] : @"none";
}

// Translates CGDisplayChangeSummaryFlags to a semantic event name.
// Connectivity flags take precedence; mirror/unmirror are checked next;
// layout-only changes (e.g. desktopShapeChanged) are named explicitly.
static NSString *displayEventName(CGDisplayChangeSummaryFlags flags) {
  if (flags & (kCGDisplayAddFlag | kCGDisplayEnabledFlag))
    return @"connected";
  if (flags & (kCGDisplayRemoveFlag | kCGDisplayDisabledFlag))
    return @"disconnected";
  if (flags & kCGDisplayMirrorFlag)
    return @"mirrored";
  if (flags & kCGDisplayUnMirrorFlag)
    return @"unmirrored";
  if (flags & kCGDisplayDesktopShapeChangedFlag)
    return @"shape";
  const CGDisplayChangeSummaryFlags connectivity =
      kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
      kCGDisplayDisabledFlag;
  if (!(flags & connectivity))
    return @"layout";
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
  // Post-wake settle timer. Arms on wake; resets on each display callback;
  // fires when the pipeline has been quiet for 2 seconds (P0/P2 fix).
  dispatch_source_t _wakeSettleTimer;
  // Number of consecutive err=1014 (internal CG error) failures from
  // applyEnable: since the last success or wake event. The retry loop is
  // driven through resetWakeSettleTimer; the counter bounds it. Reset on
  // success (applyEnable: completion) and on systemDidWake (via
  // invalidateDisplayState). See incidents 14:42 and 17:28 on 2026-04-29
  // in docs/debug/.
  NSInteger _failedActionRetries;
  // Cursor-on-black wake recovery (P20/P29): timestamp of the last system
  // wake (bounds the marker query window) and a once-per-wake latch so
  // settle-timer re-fires (err=1014 retries re-arm it) cannot run the
  // recovery twice for one wake.
  NSDate *_lastWakeAt;
  BOOL _wakeRecoveryAttempted;
}

- (instancetype)init {
  if (!(self = [super init]))
    return nil;
  _builtInID = [self discoverBuiltInID];
  _autoBlackoutOnExternalConnect = YES;
  // Initialize verbosity through the property setter so the file-static
  // BDVerbosityLevel mirror stays in sync from the start. AppDelegate may
  // overwrite this from NSUserDefaults shortly after init.
  self.verbosityLevel = 1;
  NSLog(@"[startup] — session started with builtInId=%u", _builtInID);
  NSLog(@"[startup] — API deprecation: CGDisplayIOServicePort (deprecated "
        @"macOS 10.9), "
        @"CGSConfigureDisplayEnabled (private); if broken audit "
        @"DisplayController.m");
  CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                           (__bridge void *)self);
  return self;
}

- (void)dealloc {
  CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                         (__bridge void *)self);
}

- (void)setVerbosityLevel:(NSInteger)verbosityLevel {
  // The init path passes the same value as the default (1); skipping the
  // duplicate-set log in that case keeps startup logs clean. The setter is
  // still authoritative for the BDVerbosityLevel mirror.
  BOOL changed = (verbosityLevel != _verbosityLevel);
  _verbosityLevel = verbosityLevel;
  BDVerbosityLevel = verbosityLevel;
  if (changed)
    NSLog(@"[prefs] verbosityLevel=%ld", (long)verbosityLevel);
}

- (void)setRecoveryStrategy:(NSString *)recoveryStrategy {
  // Unknown values disable the recovery rather than guessing: a typo in the
  // pref must not silently pick an action.
  NSString *normalized = recoveryStrategy;
  if (![normalized isEqualToString:@"none"] &&
      ![normalized isEqualToString:@"displaysleep"]) {
    NSLog(@"[prefs] recoveryStrategy=%@ unknown (known: none, displaysleep); "
          @"using none",
          normalized);
    normalized = @"none";
  }
  BOOL changed = ![normalized isEqualToString:_recoveryStrategy];
  _recoveryStrategy = [normalized copy];
  if (changed)
    NSLog(@"[prefs] recoveryStrategy=%@", normalized);
}

- (BOOL)isBlackedOut {
  return _isBlackedOut;
}

// MARK: - Public

- (BOOL)enableBlackout {
  if (_isBlackedOut)
    return YES;
  if (![self hasActiveExternalDisplay]) {
    NSLog(@"[state] hasExternal=0 — blackout refused, no active external "
          @"display");
    return NO;
  }
  NSLog(@"[state] hasExternal=1 autoBlackout=%d isBlackedOut=0 — initiating "
        @"blackout",
        _autoBlackoutOnExternalConnect);
  [self applyEnable:NO];
  return _isBlackedOut;
}

- (BOOL)disableBlackout {
  if (!_isBlackedOut)
    return YES;
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
    if (CGDisplayIsBuiltin(d))
      continue;
    uint32_t vendor = CGDisplayVendorNumber(d);
    if (displayIsHardwareBacked(d)) {
      BDLog(1, @"[external] id=%u vendor=%@ — hardware display detected", d,
            vendorDescription(vendor));
      found = YES;
    } else {
      BDLog(1, @"[external] id=%u vendor=%@ — virtual display disregarded", d,
            vendorDescription(vendor));
    }
  }
  return found;
}

- (BOOL)builtInIsOnline {
  CGDirectDisplayID displays[8];
  uint32_t count = 0;
  CGGetOnlineDisplayList(8, displays, &count);
  for (uint32_t i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(displays[i]))
      return YES;
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
  // Reset the err=1014 retry budget. Each new wake cycle gets a fresh
  // window of up to kBDMaxFailedActionRetries attempts to converge on
  // the safety invariant.
  _failedActionRetries = 0;
  // Clear the ivar before cancelling so the queued handler block (which
  // compares the captured timer pointer against the ivar) sees the mismatch
  // and bails out. Cancelling first leaves a brief window where the handler
  // could still match.
  if (_wakeSettleTimer) {
    dispatch_source_t toCancel = _wakeSettleTimer;
    _wakeSettleTimer = nil;
    dispatch_source_cancel(toCancel);
  }
  return disconnected;
}

// MARK: - Wake Settle Timer (P0 / P2)

- (void)handleSystemWake {
  _lastWakeAt = NSDate.date;
  _wakeRecoveryAttempted = NO;
  [self resetWakeSettleTimer];
}

// (Re-)arms the settle timer. Called on wake and on each reconfiguration
// callback while the timer is running, so it fires only after the display
// pipeline has been quiet for 2 seconds.
//
// Cancellation discipline:
//   - The ivar is cleared BEFORE the source is cancelled. The handler block
//     compares its captured timer pointer to the ivar; clearing the ivar
//     first guarantees the handler bails out if it runs concurrently.
//   - Only this method and invalidateDisplayState clear/replace the ivar.
//     The handler never clears the ivar through any path other than the
//     identity check.
- (void)resetWakeSettleTimer {
  if (_wakeSettleTimer) {
    dispatch_source_t toCancel = _wakeSettleTimer;
    _wakeSettleTimer = nil;
    dispatch_source_cancel(toCancel);
  }
  dispatch_source_t timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    // Cancel this specific source. The ivar may already be cleared (e.g.
    // by invalidateDisplayState) or may have been replaced by a newer
    // reset. The identity check below is the authoritative guard.
    dispatch_source_cancel(timer);
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_wakeSettleTimer != timer)
      return;
    strongSelf->_wakeSettleTimer = nil;
    [strongSelf wakeSettleTimerFired];
  });
  dispatch_source_set_timer(
      timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      DISPATCH_TIME_FOREVER, (int64_t)(100 * NSEC_PER_MSEC));
  dispatch_resume(timer);
  _wakeSettleTimer = timer;
}

// Fires when the display pipeline has gone quiet after wake.
// P2: issues a no-op CGConfig recommit to absorb the reconnected display state.
// Safety invariant: if the external is gone but the built-in is still
// blacked out (an unplug missed by the in-sleep callback), restore the
// built-in immediately. Without this, the user would have to wait for
// applyEnable:'s 2-second settle-time check to catch the same condition.
// P0: re-applies auto-blackout if external is present and not blacked out.
// _wakeSettleTimer is already cancelled and cleared by the handler block.
- (void)wakeSettleTimerFired {
  // Bail out if the system is going (back) to sleep before this runs.
  // dispatch_source_t timers fire on wall-clock schedule and may execute
  // while _systemSleeping=YES if the system slipped back into sleep
  // during the settle window. Issuing CG configuration calls in that
  // state returns err=1014 (internal CG error) and leaves daemon state
  // desynced from reality. The next systemDidWake re-arms the wake-settle
  // timer via handleSystemWake, so the deferred work happens then.
  // Confirmed failure mode: 2026-04-29 14:42 incident, see docs/debug/.
  if (_systemSleeping) {
    NSLog(@"[wake] — settle timer fired but system is sleeping; deferring");
    return;
  }
  NSLog(@"[wake] — display pipeline settled");
  BOOL ok = [self recommitDisplayConfiguration];
  NSLog(@"[wake] — recommit after settle: %s", ok ? "ok" : "failed");
  BOOL hasExternal = [self hasActiveExternalDisplay];
  if (!hasExternal && _isBlackedOut) {
    NSLog(@"[state] hasExternal=0 isBlackedOut=1 — no external display, "
          @"disabling blackout (post-wake invariant)");
    [self applyEnable:YES];
    return;
  }
  if (_autoBlackoutOnExternalConnect && !_isBlackedOut && hasExternal) {
    NSLog(@"[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating "
          @"blackout action");
    [self applyEnable:NO];
  }
  if (hasExternal)
    [self attemptCursorOnBlackRecovery];
}

// MARK: - Cursor-on-black wake recovery (P20 / P29)

// The one host-visible signal that separates cursor-on-black wakes from
// clean ones: SkyLight coalescing a still-pending hotplug "out" with the
// wake's "in" for the external display. Validated 56/56 black vs 0/33
// clean across matrix runs 1-104 (docs/debug/cursor-on-black-matrix.md).
// Private log wording — pinned to macOS 26 behavior; absence is treated as
// "clean or unknown", never as an error.
static NSString *const kBDHotplugCoalescedNeedle =
    @"for state \"out\" with \"in\"";

// Queries the unified log for the coalescing marker between `since` and
// now, via /usr/bin/log show — the same unprivileged path `diagnose` uses
// for windowserver.txt. The predicate matches the stable message prefix;
// the exact out/in direction is confirmed in-process so a future
// in-with-out sibling line cannot false-positive. Runs off the main queue
// (the query takes ~1 s). Returns NO on any spawn/read failure.
static BOOL BDWakeMarkerPresentSince(NSDate *since) {
  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  // Explicit zone and offset: log(1) documents "YYYY-MM-DD HH:MM:SSZZZZZ"
  // as an accepted --start form, so emit the offset (Z pattern -> "-0400")
  // rather than relying on the formatter's local-zone default matching
  // log's local-zone interpretation of an unqualified timestamp.
  f.timeZone = NSTimeZone.localTimeZone;
  f.dateFormat = @"yyyy-MM-dd HH:mm:ssZ";
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
  NSString *predicate =
      @"process == \"WindowServer\" AND eventMessage CONTAINS \"Replacing "
      @"existing hotplug event\"";
  task.arguments = @[
    @"show", @"--style", @"compact", @"--start", [f stringFromDate:since],
    @"--predicate", predicate
  ];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  NSError *err = nil;
  if (![task launchAndReturnError:&err]) {
    NSLog(@"[wake] recovery marker query failed to launch: %@",
          err.localizedDescription);
    return NO;
  }
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  if (task.terminationStatus != 0) {
    NSLog(@"[wake] recovery marker query exited rc=%d",
          (int)task.terminationStatus);
    return NO;
  }
  NSString *out = [[NSString alloc] initWithData:data
                                        encoding:NSUTF8StringEncoding];
  return [out containsString:kBDHotplugCoalescedNeedle];
}

// Runs one display-sleep cycle: pmset displaysleepnow (unprivileged), a 2 s
// pause, then caffeinate -u to re-declare user activity and relight the
// panels. The one recovery the matrix confirms end-to-end, locked and
// unlocked (runs 37-104: every programmatic clear). Called off the main
// queue.
static void BDRunDisplaySleepCycle(void) {
  NSTask *sleepTask = [[NSTask alloc] init];
  sleepTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
  sleepTask.arguments = @[ @"displaysleepnow" ];
  NSError *err = nil;
  if (![sleepTask launchAndReturnError:&err]) {
    NSLog(@"[wake] recovery displaysleep failed to launch: %@",
          err.localizedDescription);
    return;
  }
  [sleepTask waitUntilExit];
  if (sleepTask.terminationStatus != 0) {
    NSLog(@"[wake] recovery displaysleep exited rc=%d — skipping wake nudge",
          (int)sleepTask.terminationStatus);
    return;
  }
  [NSThread sleepForTimeInterval:2.0];
  NSTask *wakeTask = [[NSTask alloc] init];
  wakeTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/caffeinate"];
  wakeTask.arguments = @[ @"-u", @"-t", @"2" ];
  if (![wakeTask launchAndReturnError:&err]) {
    NSLog(@"[wake] recovery caffeinate failed to launch: %@",
          err.localizedDescription);
    return;
  }
  [wakeTask waitUntilExit];
  NSLog(@"[wake] recovery=displaysleep cycle complete (pmset rc=%d)",
        (int)sleepTask.terminationStatus);
}

// At settle time, decide whether this wake needs the recovery. Gated on the
// recoveryStrategy pref, once per wake, and on the marker being present in
// this wake's log window. The display-sleep cycle produces screen (not
// system) sleep notifications, so it cannot re-arm handleSystemWake and
// loop; the once-per-wake latch is belt and suspenders.
- (void)attemptCursorOnBlackRecovery {
  if (![_recoveryStrategy isEqualToString:@"displaysleep"])
    return;
  if (_wakeRecoveryAttempted || !_lastWakeAt)
    return;
  _wakeRecoveryAttempted = YES;
  // Query from shortly before the wake: the marker lands at the wake
  // instant. 30 s comfortably covers the skew between the marker's log
  // timestamp and _lastWakeAt (the NSWorkspace notification can trail the
  // hardware wake by a few seconds) plus log-flush latency, while staying
  // far inside the >= 2-3 min spacing of consecutive repro wakes — so the
  // previous wake's marker can never leak into this window.
  NSDate *since = [_lastWakeAt dateByAddingTimeInterval:-30.0];
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    BOOL present = BDWakeMarkerPresentSince(since);
    if (!present) {
      NSLog(@"[wake] recovery=displaysleep marker=absent — no action");
      return;
    }
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_systemSleeping) {
      NSLog(@"[wake] recovery=displaysleep marker=present but system "
            @"sleeping — skipped");
      return;
    }
    NSLog(@"[wake] recovery=displaysleep marker=present — issuing "
          @"display-sleep cycle");
    BDRunDisplaySleepCycle();
  });
}

// MARK: - Private

- (void)applyEnable:(BOOL)enable {
  _currentAction = enable ? @"restore" : @"blackout";
  NSLog(@"[builtin] id=%u action=%@ result=pending isBlackedOut=%d", _builtInID,
        _currentAction, _isBlackedOut);
  _actionInProgress = YES;
  CGError err = [self setDisplay:_builtInID enabled:enable];
  if (err != kCGErrorSuccess) {
    // kCGErrorIllegalArgument (1001) means the display is already in the
    // requested state — another process changed it before we could. Treat
    // as success and sync internal state accordingly.
    if (err == kCGErrorIllegalArgument) {
      NSLog(
          @"[builtin] id=%u action=%@ result=synced — already in desired state",
          _builtInID, _currentAction);
    } else {
      NSLog(@"[builtin] id=%u action=%@ result=failed err=%d", _builtInID,
            _currentAction, err);
      _actionInProgress = NO;
      // Any genuine failure here is treated as transient and retried through
      // the wake-settle path: the timer fires after the display pipeline goes
      // quiet, and wakeSettleTimerFired re-evaluates the safety invariant. The
      // _systemSleeping guard inside that handler prevents recursing into
      // another sleeping CG call. kCGErrorIllegalArgument is handled above as
      // "synced" and does not reach here. The dominant observed failure is the
      // internal error 1014 (CGCompleteDisplayConfiguration blocked by sleep);
      // 1014 has no public CGError symbol — the 1012-1014 range is reserved for
      // internal errors — so the retry must NOT be gated on a single named
      // constant such as kCGErrorCannotComplete (1004).
      if (_failedActionRetries < kBDMaxFailedActionRetries) {
        _failedActionRetries++;
        NSLog(@"[builtin] err=%d — arming retry %ld/%ld via wake-settle "
              @"timer",
              err, (long)_failedActionRetries, (long)kBDMaxFailedActionRetries);
        [self resetWakeSettleTimer];
      } else {
        NSLog(@"[builtin] err=%d — retry budget exhausted (%ld/%ld); "
              @"deferring until next wake or display change",
              err, (long)_failedActionRetries, (long)kBDMaxFailedActionRetries);
        // Zero (not saturate) so the next genuine trigger — a wake or a real
        // display change — gets a fresh budget. No retry is armed here, and a
        // failed action emits no reconfiguration callback, so this cannot spin:
        // applyEnable: is only re-entered on an external event.
        _failedActionRetries = 0;
      }
      return;
    }
  }
  _isBlackedOut = !enable;
  // Successful action: clear the err=1014 retry budget.
  _failedActionRetries = 0;
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
  // Real disconnect events arriving inside the window are NOT suppressed —
  // handleReconfiguration: evaluates the safety invariant before consulting
  // _actionInProgress. The settle-time check below remains as a safety net
  // for any state that diverged during the action itself.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        self->_actionInProgress = NO;
        NSLog(@"[builtin] id=%u action=%@ result=settled isBlackedOut=%d",
              self->_builtInID, self->_currentAction, self->_isBlackedOut);
        // If the system slipped back into sleep during the 2-second settle
        // window, defer the post-action invariant check to the next
        // post-wake cycle. Issuing CG calls while sleeping returns
        // err=1014 and leaves daemon state desynced.
        // Confirmed failure mode: 2026-04-29 17:28 incident, see docs/debug/.
        if (self->_systemSleeping) {
          NSLog(@"[builtin] settle handler — system sleeping; deferring "
                @"post-action invariant check to next wake");
          return;
        }
        if (self->_isBlackedOut && ![self hasActiveExternalDisplay]) {
          NSLog(@"[state] hasExternal=0 isBlackedOut=1 — no external display, "
                @"disabling blackout (missed during action window)");
          [self applyEnable:YES];
        }
      });
}

- (CGDirectDisplayID)discoverBuiltInID {
  CGDirectDisplayID displays[8];
  uint32_t count = 0;
  CGGetOnlineDisplayList(8, displays, &count);
  for (uint32_t i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(displays[i]))
      return displays[i];
  }
  return 1;
}

// Forces WindowServer to re-evaluate the display configuration graph.
// Matches the recommit pattern from displayrecommitd. No visible flicker.
// CGCompleteDisplayConfiguration consumes the config object regardless of
// whether it succeeds or fails, so CGCancelDisplayConfiguration must not
// be called after it.
- (BOOL)recommitDisplayConfiguration {
  CGDisplayConfigRef config;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess)
    return NO;
  return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) ==
         kCGErrorSuccess;
}

- (CGError)setDisplay:(CGDirectDisplayID)display enabled:(BOOL)enabled {
  // When re-enabling the built-in, issue a no-op CGConfig transaction first.
  // This ensures the compositor is healthy before the display is turned on,
  // preventing cursor-on-black when the compositor was in a broken state
  // (e.g., after a USB-C Alt Mode dropout).
  // See displayrecommitd for the standalone implementation of this pattern.
  if (enabled) {
    BOOL ok = [self recommitDisplayConfiguration];
    NSLog(@"[builtin] recommit before restore: %s", ok ? "ok" : "failed");
  }
  CGDisplayConfigRef config;
  CGError err = CGBeginDisplayConfiguration(&config);
  if (err != kCGErrorSuccess)
    return err;
  err = CGSConfigureDisplayEnabled(config, display, enabled);
  if (err != kCGErrorSuccess) {
    CGCancelDisplayConfiguration(config);
    return err;
  }
  return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}

- (void)handleReconfiguration:(CGDirectDisplayID)displayID
                        flags:(CGDisplayChangeSummaryFlags)flags {
  if (flags & kCGDisplayBeginConfigurationFlag)
    return;

  // If the post-wake settle timer is armed, push it back — the display
  // pipeline is still issuing callbacks. It fires only once things go quiet.
  if (_wakeSettleTimer)
    [self resetWakeSettleTimer];

  if (_systemSleeping) {
    BOOL isDisconnect = flags & (kCGDisplayRemoveFlag | kCGDisplayDisabledFlag);
    BOOL isExternal = displayID != _builtInID;
    if (isDisconnect && isExternal && _isBlackedOut) {
      _externalDisconnectedDuringSleep = YES;
      BDLog(1,
            @"[change] id=%u event=%@ — external disconnect noted during sleep",
            displayID, displayEventName(flags));
    } else {
      BDLog(1, @"[change] id=%u event=%@ — ignored, sleeping", displayID,
            displayEventName(flags));
    }
    return;
  }

  const CGDisplayChangeSummaryFlags connectivity =
      kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
      kCGDisplayDisabledFlag;

  NSString *event = displayEventName(flags);

  // Safety invariant — checked unconditionally, BEFORE the connectivity
  // and _actionInProgress filters below. Restoring the built-in when no
  // real external is present must never be skipped, even if the callback
  // arrives during our own action window or carries no connectivity flag
  // (the disconnect event sometimes arrives as a layout/mode change).
  // _actionInProgress will be cleared by applyEnable: when the new action
  // settles, so re-entering applyEnable: here is safe.
  BOOL hasExternal = [self hasActiveExternalDisplay];
  if (!hasExternal && _isBlackedOut) {
    NSLog(@"[state] hasExternal=0 isBlackedOut=1 — no external display, "
          @"disabling blackout (invariant)");
    [self applyEnable:YES];
    return;
  }

  if (!(flags & connectivity)) {
    BDLog(1, @"[change] id=%u event=%@ — ignored, no connectivity change",
          displayID, event);
    BDLog(2,
          @"id=%u event=%@ flags=%@ connectivity=%@ — ignored, no connectivity "
          @"change",
          displayID, event, flagsDescription(flags),
          connectivityFlagNames(flags));
    return;
  }

  if (_actionInProgress) {
    BDLog(1, @"[change] id=%u event=%@ — ignored, action in progress",
          displayID, event);
    BDLog(2,
          @"id=%u event=%@ flags=%@ connectivity=%@ — ignored, action in "
          @"progress (%@)",
          displayID, event, flagsDescription(flags),
          connectivityFlagNames(flags), _currentAction);
    return;
  }

  NSString *displayClass = (displayID == _builtInID)            ? @"builtin"
                           : displayIsHardwareBacked(displayID) ? @"hardware"
                                                                : @"virtual";
  BDLog(1, @"[change] id=%u event=%@ class=%@", displayID, event, displayClass);
  BDLog(2, @"[change] id=%u event=%@ class=%@ flags=%@ connectivity=%@",
        displayID, event, displayClass, flagsDescription(flags),
        connectivityFlagNames(flags));

  if (hasExternal && _autoBlackoutOnExternalConnect && !_isBlackedOut) {
    NSLog(@"[state] hasExternal=1 autoBlackout=1 isBlackedOut=0 — initiating "
          @"blackout action");
    [self applyEnable:NO];
  } else {
    NSLog(@"[state] hasExternal=%d autoBlackout=%d isBlackedOut=%d — no action",
          hasExternal, _autoBlackoutOnExternalConnect, _isBlackedOut);
  }
}

@end
