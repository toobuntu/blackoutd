// displayprobe — display state watcher and compositor recovery test harness.
//
// Compile:
//   clang -fobjc-arc -framework Cocoa -framework IOKit \
//         -o displayprobe displayprobe.m
//
// Modes:
//   ./displayprobe [--log path] [--no-pmset]
//       Persistent watcher. Captures display state and reconfig events at
//       sleep and wake. On qualifying wakes (battery at sleep, clamshell
//       closed at sleep, battery at wake), arms auto-nudge: tries a no-op
//       CGConfig transaction after display settles, then pmset displaysleepnow
//       15s later as fallback unless --no-pmset is given.
//       Use --no-pmset to isolate whether CGConfig alone is sufficient.
//
//   ./displayprobe --nudge-cgconfig
//       Issue a no-op CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration
//       transaction immediately and exit.
//
//   ./displayprobe --nudge-pmset
//       Issue pmset displaysleepnow immediately and exit.

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

static const NSTimeInterval kQuietInterval      = 2.0;
static const NSTimeInterval kPmsetFallbackDelay = 15.0;

// Controlled by --no-pmset. When NO, CGConfig is tried but pmset is skipped,
// letting you observe whether CGConfig alone recovers the compositor.
static BOOL gPmsetEnabled = YES;

// MARK: - System State

static BOOL isOnBattery(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return NO;
    CFStringRef source = IOPSGetProvidingPowerSourceType(info);
    BOOL result = source &&
        [(__bridge NSString *)source isEqualToString:@kIOPSBatteryPowerValue];
    CFRelease(info);
    return result;
}

static BOOL clamshellIsClosed(void) {
    io_service_t pmrd = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (pmrd == MACH_PORT_NULL) return NO;
    CFBooleanRef val = IORegistryEntryCreateCFProperty(
        pmrd, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(pmrd);
    if (!val) return NO;
    BOOL closed = CFBooleanGetValue(val);
    CFRelease(val);
    return closed;
}

// MARK: - Output

static NSFileHandle *gOutput = nil;

static void emit(NSString *line) {
    NSString *stamped = [NSString stringWithFormat:@"%@  %@\n",
        [[NSDate date] descriptionWithLocale:nil], line];
    if (gOutput) {
        [gOutput writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        fputs(stamped.UTF8String, stdout);
        fflush(stdout);
    }
}

// MARK: - Display Snapshot

static NSString *vendorName(uint32_t vendor) {
    switch (vendor) {
    case 0x0610: return @"Apple";
    case 0x10AC: return @"Dell";
    case 0x1E6D: return @"LG";
    default:     return [NSString stringWithFormat:@"0x%04x", vendor];
    }
}

static NSString *modeDescription(CGDisplayModeRef mode) {
    if (!mode) return @"(no mode)";
    return [NSString stringWithFormat:@"%zux%zu @%.0fHz ioflags=0x%08x",
            CGDisplayModeGetWidth(mode),
            CGDisplayModeGetHeight(mode),
            CGDisplayModeGetRefreshRate(mode),
            CGDisplayModeGetIOFlags(mode)];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static BOOL hasIOService(CGDirectDisplayID displayID) {
    io_service_t svc = CGDisplayIOServicePort(displayID);
    if (svc == MACH_PORT_NULL) return NO;
    IOObjectRelease(svc);
    return YES;
}
#pragma clang diagnostic pop

static NSString *displaySummary(void) {
    CGDirectDisplayID all[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, all, &count);

    NSMutableString *out = [NSMutableString stringWithFormat:@"(%u display%s)",
                            count, count == 1 ? "" : "s"];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = all[i];
        CGRect bounds = CGDisplayBounds(d);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d);
        [out appendFormat:
            @"\n    id=%-4u vendor=%-6s model=0x%04x  "
             "builtin=%-3s active=%-3s online=%-3s asleep=%-3s mirror=%-3s main=%-3s  "
             "bounds=(%.0f,%.0f %.0fx%.0f) pixels=(%zux%zu)  mode=%@  iokit=%@",
            d,
            vendorName(CGDisplayVendorNumber(d)).UTF8String,
            CGDisplayModelNumber(d),
            CGDisplayIsBuiltin(d)     ? "Y" : "N",
            CGDisplayIsActive(d)      ? "Y" : "N",
            CGDisplayIsOnline(d)      ? "Y" : "N",
            CGDisplayIsAsleep(d)      ? "Y" : "N",
            CGDisplayIsInMirrorSet(d) ? "Y" : "N",
            CGDisplayIsMain(d)        ? "Y" : "N",
            bounds.origin.x, bounds.origin.y,
            bounds.size.width, bounds.size.height,
            mode ? CGDisplayModeGetPixelWidth(mode)  : 0,
            mode ? CGDisplayModeGetPixelHeight(mode) : 0,
            modeDescription(mode),
            hasIOService(d) ? @"present" : @"absent"];
        if (mode) CGDisplayModeRelease(mode);
    }
    return out;
}

static NSString *flagDescription(CGDisplayChangeSummaryFlags flags) {
    NSMutableArray *parts = [NSMutableArray array];
    if (flags & kCGDisplayMovedFlag)               [parts addObject:@"moved"];
    if (flags & kCGDisplaySetMainFlag)             [parts addObject:@"setMain"];
    if (flags & kCGDisplaySetModeFlag)             [parts addObject:@"setMode"];
    if (flags & kCGDisplayAddFlag)                 [parts addObject:@"add"];
    if (flags & kCGDisplayRemoveFlag)              [parts addObject:@"remove"];
    if (flags & kCGDisplayEnabledFlag)             [parts addObject:@"enabled"];
    if (flags & kCGDisplayDisabledFlag)            [parts addObject:@"disabled"];
    if (flags & kCGDisplayMirrorFlag)              [parts addObject:@"mirror"];
    if (flags & kCGDisplayUnMirrorFlag)            [parts addObject:@"unmirror"];
    if (flags & kCGDisplayDesktopShapeChangedFlag) [parts addObject:@"desktopShape"];
    return parts.count ? [parts componentsJoinedByString:@"|"] : @"none";
}

// MARK: - Nudges

static void nudgeCGConfig(void) {
    emit(@"[nudge] trying CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration");
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        emit([NSString stringWithFormat:@"[nudge] CGBeginDisplayConfiguration error=%d", err]);
        return;
    }
    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        emit([NSString stringWithFormat:@"[nudge] CGCompleteDisplayConfiguration error=%d", err]);
        return;
    }
    emit(@"[nudge] CGConfig done — observe whether display recovered");
}

static void nudgePmset(void) {
    emit(@"[nudge] issuing pmset displaysleepnow");
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
    task.arguments     = @[@"displaysleepnow"];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        emit([NSString stringWithFormat:@"[nudge] pmset failed: %@",
              err.localizedDescription]);
    }
}

// MARK: - Reconfig Callback

static void reconfigCallback(CGDirectDisplayID display,
                              CGDisplayChangeSummaryFlags flags,
                              void *userInfo);

// MARK: - Watcher

@interface Watcher : NSObject
- (void)displayReconfigured:(CGDirectDisplayID)display
                      flags:(CGDisplayChangeSummaryFlags)flags;
@end

@implementation Watcher {
    BOOL    _sleepOnBattery;
    BOOL    _clamshellClosedAtSleep;  // lid state recorded at sleep, not at wake
    BOOL    _nudgePending;
    NSTimer *_quietTimer;
    NSTimer *_pmsetFallbackTimer;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, (__bridge void *)self);
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(willSleep:)
               name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:)
               name:NSWorkspaceDidWakeNotification object:nil];
    return self;
}

- (void)dealloc {
    CGDisplayRemoveReconfigurationCallback(reconfigCallback, (__bridge void *)self);
}

- (void)willSleep:(NSNotification *)note {
    _sleepOnBattery        = isOnBattery();
    _clamshellClosedAtSleep = clamshellIsClosed();
    [self cancelNudge];
    emit([NSString stringWithFormat:@"[pre-sleep] battery=%@ clamshell=%@  %@",
          _sleepOnBattery ? @"yes" : @"no",
          _clamshellClosedAtSleep ? @"closed" : @"open",
          displaySummary()]);
}

- (void)didWake:(NSNotification *)note {
    BOOL batteryAtWake = isOnBattery();
    // Conditions: battery at sleep, clamshell closed at sleep, battery at wake.
    // Clamshell is expected to be open at wake (user opens lid); checking it
    // here would always be NO and is not one of the repro conditions.
    BOOL qualifying = _sleepOnBattery && _clamshellClosedAtSleep && batteryAtWake;
    emit([NSString stringWithFormat:
          @"[wake] battery_sleep=%@ clamshell_sleep=%@ battery_wake=%@ — %@",
          _sleepOnBattery        ? @"yes" : @"no",
          _clamshellClosedAtSleep ? @"closed" : @"open",
          batteryAtWake          ? @"yes" : @"no",
          qualifying             ? @"arming nudge" : @"conditions not met"]);
    if (qualifying) {
        [self armNudge];
    }
}

- (void)displayReconfigured:(CGDirectDisplayID)display
                      flags:(CGDisplayChangeSummaryFlags)flags {
    emit([NSString stringWithFormat:@"[reconfig] id=%u flags=%@  %@",
          display, flagDescription(flags), displaySummary()]);
    if (!_nudgePending) return;
    // Reset quiet timer on every reconfig; nudge fires only after settled.
    [_quietTimer invalidate];
    _quietTimer = [NSTimer scheduledTimerWithTimeInterval:kQuietInterval
                                                  target:self
                                                selector:@selector(quietTimerFired)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)armNudge {
    _nudgePending = YES;
    [_quietTimer invalidate];
    _quietTimer = [NSTimer scheduledTimerWithTimeInterval:kQuietInterval
                                                  target:self
                                                selector:@selector(quietTimerFired)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)cancelNudge {
    _nudgePending = NO;
    [_quietTimer invalidate];
    [_pmsetFallbackTimer invalidate];
    _quietTimer = _pmsetFallbackTimer = nil;
}

- (void)quietTimerFired {
    _quietTimer   = nil;
    _nudgePending = NO;
    nudgeCGConfig();
    // Fire pmset 3s later regardless — lets us observe in the log whether
    // CGConfig alone was sufficient (display already recovered before pmset)
    // or whether pmset was needed.
    _pmsetFallbackTimer =
        [NSTimer scheduledTimerWithTimeInterval:kPmsetFallbackDelay
                                         target:self
                                       selector:@selector(pmsetFallbackFired)
                                       userInfo:nil
                                        repeats:NO];
}

- (void)pmsetFallbackFired {
    _pmsetFallbackTimer = nil;
    emit([NSString stringWithFormat:@"[nudge] display state at fallback: %@", displaySummary()]);
    if (gPmsetEnabled) {
        nudgePmset();
    } else {
        emit(@"[nudge] pmset skipped (--no-pmset) — was display already recovered by CGConfig?");
    }
}

@end

static void reconfigCallback(CGDirectDisplayID display,
                              CGDisplayChangeSummaryFlags flags,
                              void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    [(__bridge Watcher *)userInfo displayReconfigured:display flags:flags];
}

// MARK: - Entry Point

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--nudge-cgconfig") == 0) {
                nudgeCGConfig();
                return 0;
            }
            if (strcmp(argv[i], "--nudge-pmset") == 0) {
                nudgePmset();
                return 0;
            }
            if (strcmp(argv[i], "--no-pmset") == 0) {
                gPmsetEnabled = NO;
            }
        }

        NSString *logPath = nil;
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--log") == 0) {
                logPath = @(argv[i + 1]);
            }
        }

        if (logPath) {
            [[NSFileManager defaultManager] createFileAtPath:logPath
                                                    contents:nil attributes:nil];
            gOutput = [NSFileHandle fileHandleForWritingAtPath:logPath];
            [gOutput seekToEndOfFile];
            fprintf(stdout, "displayprobe: logging to %s\n", logPath.UTF8String);
            fflush(stdout);
        }

        emit([NSString stringWithFormat:@"[start] battery=%@ clamshell=%@ pmset=%@  %@",
              isOnBattery() ? @"yes" : @"no",
              clamshellIsClosed() ? @"closed" : @"open",
              gPmsetEnabled ? @"enabled" : @"disabled",
              displaySummary()]);

        __unused Watcher *watcher = [[Watcher alloc] init];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp run];
    }
    return 0;
}
