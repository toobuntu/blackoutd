/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// CLI entry point — daemon run loop is at the bottom of this file.

#import "AppDelegate.h"
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <errno.h>
#import <libproc.h>
#import <sys/sysctl.h>

// Build identity, injected by the Makefile via -D. Fallbacks keep a bare
// `clang src/*.m` compile working without the Makefile.
#ifndef BD_BUILD_GIT
#define BD_BUILD_GIT "unknown"
#endif
#ifndef BD_BUILD_TIME
#define BD_BUILD_TIME "unknown"
#endif

static NSString *const kBundleID = @BD_BUNDLE_ID;
static NSString *const kSuiteName = @"blackoutd";
static NSString *const kAutoBlackoutKey = @"autoBlackoutOnExternalConnect";
static NSString *const kVerbosityKey = @"verbosityLevel";
static NSString *const kAgentLabel = @BD_BUNDLE_ID;

static NSString *agentPlistPath(void) {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:
          [@"Library/LaunchAgents/"
              stringByAppendingString:[kAgentLabel
                                          stringByAppendingString:@".plist"]]];
}

static NSString *agentDomain(void) {
  return [NSString stringWithFormat:@"gui/%d", getuid()];
}

static NSString *agentService(void) {
  return [NSString stringWithFormat:@"gui/%d/%@", getuid(), kAgentLabel];
}

// Reads ProgramArguments[0] from the installed LaunchAgent plist.
// Returns nil if the plist is missing or malformed. The result is the
// canonical path to the daemon binary as registered with launchd, used
// to disambiguate the daemon process from CLI invocations of the same
// binary in daemonPid().
static NSString *registeredDaemonPath(void) {
  NSDictionary *plist =
      [NSDictionary dictionaryWithContentsOfFile:agentPlistPath()];
  NSArray *args = plist[@"ProgramArguments"];
  if (![args isKindOfClass:[NSArray class]] || args.count == 0)
    return nil;
  NSString *path = args.firstObject;
  return [path isKindOfClass:[NSString class]] ? path : nil;
}

static int runLaunchctl(NSArray<NSString *> *args) {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
  task.arguments = args;
  NSError *err = nil;
  if (![task launchAndReturnError:&err]) {
    fprintf(stderr, "blackoutd: launchctl failed: %s\n",
            err.localizedDescription.UTF8String);
    return 1;
  }
  [task waitUntilExit];
  return (int)task.terminationStatus;
}

// Returns the daemon's PID if running, 0 otherwise.
//
// Liveness and PID discovery share one mechanism: enumerate processes via
// sysctl and identify the daemon by four properties. A bootstrap_look_up()
// fast path was considered and rejected because that call is documented as
// potentially activating an on-demand service (see Apple's bootstrap_look_up
// man page). Even with KeepAlive=true making activation harmless in practice,
// it is a side-effect we do not need: sysctl alone is authoritative and the
// cost is a single system call enumerating ~400 processes.
//
// A candidate process must satisfy ALL of:
//
//   1. p_comm matches "blackoutd" (cheap pre-filter).
//   2. Effective UID matches the calling user. Defends against unusual
//      gui/$UID configurations where another user's daemon might be visible.
//   3. Parent process is launchd (pid 1) — LaunchAgents are direct children
//      of the per-user launchd, so a match here excludes CLI processes
//      launched from a shell (parent is the shell or its descendant).
//   4. Executable path matches the path registered in the LaunchAgent plist
//      (ProgramArguments[0]). Defends against an unrelated binary named
//      "blackoutd" running in the same session.
//
// p_comm is limited to MAXCOMLEN (16) characters; "blackoutd" (9) fits.
//
// The daemon-side bootstrap_check_in() in AppDelegate is retained: it holds
// the Mach service receive right for the v1.0 Mach IPC command channel
// (which will replace signal-based commands). It is not used for liveness
// from the CLI.
static pid_t daemonPid(void) {
  NSString *expectedPath = registeredDaemonPath();
  uid_t self_uid = getuid();

  // Enumerate running processes to find the daemon PID.
  // The process table can grow between the sizing call and the data call,
  // so retry with a larger buffer on ENOMEM.
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  struct kinfo_proc *procs = NULL;
  BOOL sysctlOK = NO;
  for (int attempt = 0; attempt < 5; attempt++) {
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) {
      free(procs);
      return 0;
    }
    // Add headroom for processes that may appear between calls.
    size += size / 8;
    struct kinfo_proc *tmp = (struct kinfo_proc *)realloc(procs, size);
    if (!tmp) {
      free(procs);
      return 0;
    }
    procs = tmp;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
      sysctlOK = YES;
      break;
    }
    if (errno != ENOMEM) {
      free(procs);
      return 0;
    }
  }
  if (!sysctlOK) {
    free(procs);
    return 0;
  }
  int count = (int)(size / sizeof(struct kinfo_proc));
  pid_t found = 0;
  pid_t self_pid = getpid();
  for (int i = 0; i < count && !found; i++) {
    if (procs[i].kp_proc.p_pid == self_pid)
      continue;
    if (strcmp(procs[i].kp_proc.p_comm, "blackoutd") != 0)
      continue;
    // Effective UID must match the calling user.
    if (procs[i].kp_eproc.e_ucred.cr_uid != self_uid)
      continue;
    // Parent must be launchd (pid 1) for a LaunchAgent.
    if (procs[i].kp_eproc.e_ppid != 1)
      continue;
    // Executable path must match ProgramArguments[0] from the plist.
    if (expectedPath) {
      char path[PROC_PIDPATHINFO_MAXSIZE];
      int n = proc_pidpath(procs[i].kp_proc.p_pid, path, sizeof(path));
      if (n <= 0)
        continue;
      if (strcmp(path, expectedPath.UTF8String) != 0)
        continue;
    }
    found = procs[i].kp_proc.p_pid;
  }
  free(procs);
  return found;
}

static BOOL daemonIsRunning(void) { return daemonPid() > 0; }
static int sendSignalToDaemon(int sig) {
  pid_t pid = daemonPid();
  if (pid <= 0) {
    fprintf(stderr, "blackoutd: daemon not running\n");
    return 1;
  }
  if (kill(pid, sig) != 0) {
    perror("blackoutd: kill");
    return 1;
  }
  return 0;
}

static BOOL builtInIsOnline(void) {
  CGDirectDisplayID displays[8];
  uint32_t count = 0;
  CGGetOnlineDisplayList(8, displays, &count);
  for (uint32_t i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(displays[i]))
      return YES;
  }
  return NO;
}

// Runs an executable with arguments, capturing stdout to a file.
// Returns the process exit code, or -1 on launch failure.
static int runToFile(NSString *filePath, NSString *path,
                     NSArray<NSString *> *args) {
  [[NSFileManager defaultManager] createFileAtPath:filePath
                                          contents:nil
                                        attributes:nil];
  NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:filePath];
  if (!fh)
    return -1;
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:path];
  task.arguments = args;
  task.standardOutput = fh;
  task.standardError = fh;
  NSError *err = nil;
  if (![task launchAndReturnError:&err]) {
    [fh closeFile];
    return -1;
  }
  [task waitUntilExit];
  [fh closeFile];
  return (int)task.terminationStatus;
}

// Runs a capture into a bundle file. Warns and returns NO only if the tool
// could not be launched or the file could not be created (runToFile < 0); a
// nonzero tool exit (e.g. grep with no matches) is not a bundle failure.
static BOOL captureToFile(NSString *filePath, NSString *path,
                          NSArray<NSString *> *args) {
  if (runToFile(filePath, path, args) >= 0)
    return YES;
  fprintf(stderr, "blackoutd: failed to capture %s\n", filePath.UTF8String);
  return NO;
}

// Runs a fixed /bin/sh -c pipeline (no interpolated values) into a bundle file.
static BOOL captureShellToFile(NSString *filePath, NSString *command) {
  return captureToFile(filePath, @"/bin/sh", @[ @"-c", command ]);
}

// Writes bundle text, warning and returning NO on failure so diagnose does not
// claim a complete bundle after a partial write.
static BOOL writeBundleText(NSString *text, NSString *filePath) {
  NSError *err = nil;
  if ([text writeToFile:filePath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:&err])
    return YES;
  fprintf(stderr, "blackoutd: failed to write %s: %s\n", filePath.UTF8String,
          err.localizedDescription.UTF8String);
  return NO;
}

// MARK: - Diagnostics

static NSString *localBuildTimeLine(void);

// Captures a command's combined stdout+stderr as a string so the same text
// is both printed and written to the bundle. readDataToEndOfFile drains the
// pipe as the child writes, so this does not deadlock on bounded output.
static NSString *captureCommand(NSString *path, NSArray<NSString *> *args) {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:path];
  task.arguments = args;
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = pipe;
  if (![task launchAndReturnError:NULL])
    return nil;
  NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *daemonLogPath(void) {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Logs/blackoutd.log"];
}

// Last line of the daemon log containing `needle`, trimmed; nil if absent.
// Parsing the persistent log is the v0.2 stand-in for querying the daemon
// directly; planned Mach IPC will replace it.
static NSString *lastLogToken(NSString *needle) {
  NSString *log = daemonLogPath();
  if (![NSFileManager.defaultManager fileExistsAtPath:log])
    return nil;
  NSString *out = captureCommand(@"/usr/bin/grep",
                                 @[ @"--fixed-strings", @"--", needle, log ]);
  if (!out.length)
    return nil;
  NSString *last = nil;
  for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    if (trimmed.length)
      last = trimmed;
  }
  return last;
}

// Lid state via the IOKit clamshell key. AppleClamshellState is YES when the
// lid is closed (clamshell engaged), NO when open; the raw value is named in
// the result so the mapping is unambiguous in a bug report.
static NSString *clamshellState(void) {
  NSString *cmd = @"ioreg -r -k AppleClamshellState | "
                  @"awk -F'= ' '/AppleClamshellState/ {print $2; exit}'";
  NSString *out = captureCommand(@"/bin/sh", @[ @"-c", cmd ]);
  out = [out
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if ([out isEqualToString:@"Yes"])
    return @"closed (AppleClamshellState=Yes)";
  if ([out isEqualToString:@"No"])
    return @"open (AppleClamshellState=No)";
  return @"unknown";
}

static void appendDisplays(NSMutableString *r) {
  CGDirectDisplayID displays[8];
  uint32_t count = 0;
  CGGetOnlineDisplayList(8, displays, &count);
  [r appendFormat:@"\n--- Displays (%u online) ---\n", count];
  for (uint32_t i = 0; i < count; i++) {
    CGDirectDisplayID d = displays[i];
    CGRect bounds = CGDisplayBounds(d);
    CGSize size = CGDisplayScreenSize(d);
    [r appendFormat:@"\nDisplay %u (%s)\n", d,
                    CGDisplayIsBuiltin(d) ? "built-in" : "external"];
    [r appendFormat:@"  Active          : %s\n",
                    CGDisplayIsActive(d) ? "yes" : "no"];
    [r appendFormat:@"  Vendor          : 0x%04x\n", CGDisplayVendorNumber(d)];
    [r appendFormat:@"  Model           : 0x%04x\n", CGDisplayModelNumber(d)];
    uint32_t serial = CGDisplaySerialNumber(d);
    if (serial != 0)
      [r appendFormat:@"  Serial          : 0x%08x\n", serial];
    [r appendFormat:@"  Resolution      : %.0f x %.0f\n", bounds.size.width,
                    bounds.size.height];
    [r appendFormat:@"  Physical size   : %.1fmm x %.1fmm\n", size.width,
                    size.height];
  }
}

// MARK: - DCP / framebuffer forensic readers

// IOMFB pixel-encoding enum -> short label. 0=RGB and 3=YCbCr444 are confirmed
// from captures; 1=YCbCr422 / 2=YCbCr420 are the conventional IOMFB values.
// The raw PixelEncoding number is always emitted alongside the label, so an
// off-by-one in the 1/2 mapping can never mislead a reader of the bundle.
static NSString *pixelEncodingName(long enc) {
  switch (enc) {
  case 0:
    return @"RGB";
  case 1:
    return @"YCbCr422";
  case 2:
    return @"YCbCr420";
  case 3:
    return @"YCbCr444";
  default:
    return @"other";
  }
}

// Reads an IORegistry entry's properties as an autoreleased dictionary, or nil.
static NSDictionary *ioEntryProperties(io_registry_entry_t entry) {
  CFMutableDictionaryRef props = NULL;
  if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault,
                                        0) != KERN_SUCCESS)
    return nil;
  return CFBridgingRelease(props);
}

// Appends the AppleDCPExpert controllers, attributed by their "role" property
// ("DCP" = built-in, "DCPEXT" = external) rather than by iteration order.
// DCPPowerState is forensic only: the external DCPEXT value is constant across
// cursor-on-black, clean, and recovered wakes (technical-debt.md P29), so this
// is captured to confirm/observe state, NOT as a detector to gate on.
static void appendDCPControllers(NSMutableString *r) {
  io_iterator_t it = MACH_PORT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("AppleDCPExpert"),
                                   &it) != KERN_SUCCESS)
    return;
  [r appendString:@"\n--- DCP controllers (AppleDCPExpert, by role) ---\n"];
  io_service_t svc;
  while ((svc = IOIteratorNext(it)) != MACH_PORT_NULL) {
    NSDictionary *p = ioEntryProperties(svc);
    NSString *role = p[@"role"] ?: @"?";
    [r appendFormat:@"\n%@ (%@)\n", role,
                    [role isEqualToString:@"DCPEXT"] ? @"external"
                                                     : @"built-in"];
    [r appendFormat:@"  DCPPowerState          : %@\n",
                    p[@"DCPPowerState"] ?: @"?"];
    [r appendFormat:@"  DCPPowerAssertionCount : %@\n",
                    p[@"DCPPowerAssertionCount"] ?: @"?"];
    IOObjectRelease(svc);
  }
  IOObjectRelease(it);
}

// Appends each AppleCLCD2 framebuffer's scanout/timing state, attributed by its
// "external" flag. NormalModeActive is a candidate cursor-on-black signal worth
// observing during the broken state; Transport names the link (e.g. DP ->
// HDMI) for Alt Mode context. Color/encoding lives in connection-mode.txt.
static void appendFramebufferState(NSMutableString *r) {
  io_iterator_t it = MACH_PORT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("AppleCLCD2"),
                                   &it) != KERN_SUCCESS)
    return;
  [r appendString:@"\n--- Framebuffers (AppleCLCD2, by external flag) ---\n"];
  io_service_t svc;
  while ((svc = IOIteratorNext(it)) != MACH_PORT_NULL) {
    NSDictionary *p = ioEntryProperties(svc);
    BOOL external = [p[@"external"] boolValue];
    [r appendFormat:@"\n%@ (DCPIndex %@)\n",
                    external ? @"external" : @"built-in",
                    p[@"DCPIndex"] ?: @"?"];
    [r appendFormat:@"  NormalModeActive : %@\n",
                    [p[@"NormalModeActive"] boolValue] ? @"yes" : @"no"];
    if (p[@"DisplayWidth"] && p[@"DisplayHeight"])
      [r appendFormat:@"  Resolution       : %@ x %@\n", p[@"DisplayWidth"],
                      p[@"DisplayHeight"]];
    if (p[@"DPTimingModeId"])
      [r appendFormat:@"  DPTimingModeId   : %@\n", p[@"DPTimingModeId"]];
    if (p[@"PixelClock"])
      [r appendFormat:@"  PixelClock       : %@\n", p[@"PixelClock"]];
    NSDictionary *transport = p[@"Transport"];
    if ([transport isKindOfClass:NSDictionary.class])
      [r appendFormat:@"  Transport        : %@ -> %@\n",
                      transport[@"Upstream"] ?: @"?",
                      transport[@"Downstream"] ?: @"?"];
    IOObjectRelease(svc);
  }
  IOObjectRelease(it);
}

// Appends each AppleCLCD2's advertised color modes, decoded from ColorElements,
// for connection-mode.txt. This is the color/pixel-encoding view (the
// inject_edid / SP2309W concern, ADR 0009) and is deliberately kept in its own
// file, separate from the cursor-on-black scanout forensics in dcp.txt. The
// ACTIVE wire encoding (e.g. fmt:YCbCr444_10bit) is not an ioreg scalar; read
// it from windowserver.txt.
static void appendConnectionModes(NSMutableString *r) {
  io_iterator_t it = MACH_PORT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("AppleCLCD2"),
                                   &it) != KERN_SUCCESS)
    return;
  io_service_t svc;
  while ((svc = IOIteratorNext(it)) != MACH_PORT_NULL) {
    NSDictionary *p = ioEntryProperties(svc);
    BOOL external = [p[@"external"] boolValue];
    [r appendFormat:@"\n%@ (DCPIndex %@)\n",
                    external ? @"external" : @"built-in",
                    p[@"DCPIndex"] ?: @"?"];
    if (p[@"EDID UUID"])
      [r appendFormat:@"  EDID UUID : %@\n", p[@"EDID UUID"]];
    NSArray *colors = p[@"ColorElements"];
    if (![colors isKindOfClass:NSArray.class] || colors.count == 0) {
      [r appendString:@"  (no ColorElements)\n"];
      IOObjectRelease(svc);
      continue;
    }
    NSMutableOrderedSet<NSString *> *summary = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *c in colors) {
      if (![c isKindOfClass:NSDictionary.class])
        continue;
      [summary addObject:[NSString stringWithFormat:@"%@/%@bpc",
                                                    pixelEncodingName(
                                                        [c[@"PixelEncoding"]
                                                            longValue]),
                                                    c[@"Depth"] ?: @"?"]];
    }
    [r appendFormat:@"  Advertised (%lu): %@\n", (unsigned long)colors.count,
                    [summary.array componentsJoinedByString:@", "]];
    for (NSDictionary *c in colors) {
      if (![c isKindOfClass:NSDictionary.class])
        continue;
      [r appendFormat:@"    id=%@ %@ PixelEncoding=%@ Depth=%@ DynamicRange=%@ "
                      @"Colorimetry=%@\n",
                      c[@"ID"] ?: @"?",
                      pixelEncodingName([c[@"PixelEncoding"] longValue]),
                      c[@"PixelEncoding"] ?: @"?", c[@"Depth"] ?: @"?",
                      c[@"DynamicRange"] ?: @"?", c[@"Colorimetry"] ?: @"?"];
    }
    IOObjectRelease(svc);
  }
  IOObjectRelease(it);
}

// Builds dcp.txt: DCP power + framebuffer scanout/timing state, role and
// "external"-attributed so the two controllers and two framebuffers are never
// confused by position (the misattribution that derailed the P29 DCPPowerState
// analysis). Read-only.
static NSString *dcpReport(void) {
  NSMutableString *r = [NSMutableString string];
  [r appendString:@"--- blackoutd DCP / framebuffer state ---\n"];
  appendDCPControllers(r);
  appendFramebufferState(r);
  return r;
}

// Builds connection-mode.txt: the advertised color/encoding catalog per
// display. Kept separate from dcp.txt per the cursor-on-black vs color-cast
// boundary (ADR 0009). Read-only.
static NSString *connectionModeReport(void) {
  NSMutableString *r = [NSMutableString string];
  [r appendString:@"--- blackoutd connection modes (advertised) ---\n"];
  appendConnectionModes(r);
  return r;
}

// Builds the human-readable report as a single string so the same text is
// printed to stdout and written to the bundle's config.txt.
static NSString *buildReport(void) {
  NSProcessInfo *info = NSProcessInfo.processInfo;
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  BOOL autoMode = [defaults objectForKey:kAutoBlackoutKey] != nil
                      ? [defaults boolForKey:kAutoBlackoutKey]
                      : YES;
  NSInteger verbosity = [defaults objectForKey:kVerbosityKey] != nil
                            ? [defaults integerForKey:kVerbosityKey]
                            : 1;

  NSMutableString *r = [NSMutableString string];
  [r appendString:@"--- blackoutd diagnostic info ---\n\n"];

  pid_t pid = daemonPid();
  [r appendFormat:@"daemon          : %s\n",
                  pid > 0 ? "running" : "not running"];
  if (pid > 0)
    [r appendFormat:@"daemon pid      : %d\n", pid];
  [r appendFormat:@"built-in (CG)   : %s\n",
                  builtInIsOnline() ? "online" : "offline"];
  NSString *state = lastLogToken(@"isBlackedOut=");
  if (state)
    [r appendFormat:@"daemon log tail : %@\n", state];
  [r appendFormat:@"auto-blackout   : %s\n", autoMode ? "enabled" : "disabled"];
  [r appendFormat:@"verbosity       : %ld\n", (long)verbosity];
  [r appendFormat:@"bundle-id       : %s\n", kBundleID.UTF8String];
  [r appendFormat:@"lid             : %@\n", clamshellState()];
  NSString *batt = captureCommand(@"/usr/bin/pmset", @[ @"-g", @"batt" ]);
  NSString *power =
      batt.length ? [batt componentsSeparatedByString:@"\n"].firstObject : nil;
  [r appendFormat:@"power           : %@\n", power ?: @"unknown"];

  NSOperatingSystemVersion v = info.operatingSystemVersion;
  [r appendFormat:@"macOS           : %ld.%ld.%ld\n", (long)v.majorVersion,
                  (long)v.minorVersion, (long)v.patchVersion];
  NSString *arch = captureCommand(@"/usr/bin/uname", @[ @"-m" ]);
  [r appendFormat:@"arch            : %@", arch.length ? arch : @"unknown\n"];

  [r appendString:@"\n--- build provenance ---\n"];
  [r appendFormat:@"cli build       : %s (built %s)\n", BD_BUILD_GIT,
                  BD_BUILD_TIME];
  NSString *daemonBuild = lastLogToken(@"build=");
  if (daemonBuild) {
    [r appendFormat:@"daemon startup  : %@\n", daemonBuild];
    if (strstr(daemonBuild.UTF8String, BD_BUILD_GIT) == NULL)
      [r appendString:@"WARNING         : CLI and daemon build stamps differ "
                      @"(stale PATH binary?)\n"];
  }

  appendDisplays(r);

  [r appendString:@"\n--- system_profiler ---\n"];
  NSString *sp = captureCommand(@"/usr/sbin/system_profiler", @[
    @"SPHardwareDataType", @"SPDisplaysDataType", @"-detailLevel", @"mini"
  ]);
  [r appendString:sp.length ? sp : @"(unavailable)\n"];
  return r;
}

// Builds the `log show` time-window arguments as an argv array (passed to
// NSTask, never a shell), so user-supplied --start/--end values cannot be
// interpreted by a shell. Explicit --start/--end take precedence (precise,
// low-noise); otherwise --last <minutes>m.
static NSArray<NSString *> *logWindowArgs(int minutes, NSString *start,
                                          NSString *end) {
  if (start.length) {
    NSMutableArray<NSString *> *w =
        [NSMutableArray arrayWithObjects:@"--start", start, nil];
    if (end.length) {
      [w addObject:@"--end"];
      [w addObject:end];
    }
    return w;
  }
  return @[ @"--last", [NSString stringWithFormat:@"%dm", minutes] ];
}

// Self-bounds the diagnostic window from the daemon's own sleep/wake markers.
// The "incident wake" is the most recent wake that followed a substantive
// sleep (gap > 60 s) — a real system wake rather than a brief recovery
// sleep/wake cycle. The window runs from a lead before that wake to a tail
// after the most recent wake (which may be a recovery cycle). Sets *startOut
// and *endOut to "yyyy-MM-dd HH:mm:ss" strings, or leaves them untouched if no
// wake is recorded. Lets `diagnose` bound the capture without user input.
static void deriveWindow(NSString **startOut, NSString **endOut) {
  NSString *log = daemonLogPath();
  if (![NSFileManager.defaultManager fileExistsAtPath:log])
    return;
  NSString *out = captureCommand(@"/usr/bin/grep", @[
    @"--fixed-strings", @"-e", @"resuming display change", @"-e",
    @"ignoring display changes", @"--", log
  ]);
  if (!out.length)
    return;

  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.dateFormat = @"yyyy-MM-dd HH:mm:ss";

  NSDate *prevSleep = nil, *lastWake = nil, *incidentWake = nil;
  for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
    if (line.length < 19)
      continue;
    NSDate *t = [f dateFromString:[line substringToIndex:19]];
    if (!t)
      continue;
    if ([line containsString:@"ignoring display changes"]) {
      prevSleep = t;
    } else {
      lastWake = t;
      if (prevSleep && [t timeIntervalSinceDate:prevSleep] > 60)
        incidentWake = t;
    }
  }
  NSDate *anchor = incidentWake ?: lastWake;
  if (!anchor)
    return;
  *startOut = [f stringFromDate:[anchor dateByAddingTimeInterval:-90]];
  *endOut = [f stringFromDate:[lastWake dateByAddingTimeInterval:90]];
}

// Collects a diagnostic bundle into /tmp and prints the report to stdout.
static int runDiagnose(int minutes, NSString *start, NSString *end, BOOL quiet,
                       NSString *label, NSString **bundleDirOut) {
  NSDate *t0 = NSDate.date;
  NSDateFormatter *clock = [[NSDateFormatter alloc] init];
  clock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  clock.dateFormat = @"yyyy-MM-dd HH:mm:ss";
  printf("diagnose: started %s%s — collecting (can take ~1 min)...\n",
         [clock stringFromDate:t0].UTF8String,
         label.length ? [NSString stringWithFormat:@" [%@]", label].UTF8String
                      : "");

  // Sample the live registry BEFORE buildReport() runs system_profiler, which
  // can probe and perturb displays — keeps dcp.txt / connection-mode.txt a
  // pristine snapshot of the state at capture time.
  NSString *dcp = dcpReport();
  NSString *connMode = connectionModeReport();

  NSString *report = buildReport();
  if (!quiet)
    fputs(report.UTF8String, stdout);

  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.dateFormat = @"yyyyMMdd-HHmmss";
  NSString *dir = [NSString stringWithFormat:@"/tmp/blackoutd-diag-%@",
                                             [fmt stringFromDate:NSDate.date]];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *mkdirErr = nil;
  if (![fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&mkdirErr]) {
    fprintf(stderr, "blackoutd: cannot create bundle directory %s: %s\n",
            dir.UTF8String, mkdirErr.localizedDescription.UTF8String);
    return 1;
  }
  if (bundleDirOut)
    *bundleDirOut = dir;

  BOOL complete = YES;
  if (label.length &&
      !writeBundleText([label stringByAppendingString:@"\n"],
                       [dir stringByAppendingPathComponent:@"label.txt"]))
    complete = NO;
  if (!writeBundleText(report,
                       [dir stringByAppendingPathComponent:@"config.txt"]))
    complete = NO;

  NSMutableString *version = [NSMutableString string];
  NSString *ver = [NSBundle.mainBundle
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  [version appendFormat:@"blackoutd %s (%s)\n",
                        ver ? ver.UTF8String : "unknown", BD_BUILD_GIT];
  [version appendFormat:@"built: %s (UTC)\n", BD_BUILD_TIME];
  NSString *local = localBuildTimeLine();
  if (local)
    [version appendFormat:@"local: %@\n", local];
  if (!writeBundleText(version,
                       [dir stringByAppendingPathComponent:@"version.txt"]))
    complete = NO;

  if (!writeBundleText(dcp, [dir stringByAppendingPathComponent:@"dcp.txt"]))
    complete = NO;

  if (!writeBundleText(
          connMode,
          [dir stringByAppendingPathComponent:@"connection-mode.txt"]))
    complete = NO;

  NSString *log = daemonLogPath();
  if ([fm fileExistsAtPath:log] &&
      !captureToFile([dir stringByAppendingPathComponent:@"daemon-log.txt"],
                     @"/usr/bin/tail", @[ @"-n", @"500", log ]))
    complete = NO;

  // Self-bounding default: derive a window around the most recent incident
  // from the daemon's own sleep/wake markers. Explicit --start/--end or
  // --minutes override.
  if (!start.length && minutes <= 0) {
    NSString *autoStart = nil, *autoEnd = nil;
    deriveWindow(&autoStart, &autoEnd);
    if (autoStart) {
      start = autoStart;
      if (!end.length)
        end = autoEnd;
    }
  }
  NSArray<NSString *> *window =
      logWindowArgs(minutes > 0 ? minutes : 3, start, end);
  NSString *windowText = [window componentsJoinedByString:@" "];
  NSArray<NSString *> *logBase =
      [@[ @"show" ] arrayByAddingObjectsFromArray:window];
  // runToFile sends stdout+stderr to the file (the old shell `2>&1`) and uses
  // an argv array, so the window values are never parsed by a shell.
  if (!captureToFile(
          [dir stringByAppendingPathComponent:@"system-log.txt"],
          @"/usr/bin/log", [logBase arrayByAddingObjectsFromArray:@[
            @"--predicate", @"process == \"blackoutd\"", @"--style", @"compact"
          ]]))
    complete = NO;
  if (!captureToFile(
          [dir stringByAppendingPathComponent:@"windowserver.txt"],
          @"/usr/bin/log", [logBase arrayByAddingObjectsFromArray:@[
            @"--debug", @"--info", @"--predicate",
            @"process == \"WindowServer\" OR process == \"displaypolicyd\"",
            @"--style", @"compact"
          ]]))
    complete = NO;
  if (!captureShellToFile(
          [dir stringByAppendingPathComponent:@"sleep-wake.txt"],
          @"pmset -g log 2>/dev/null | grep --extended-regexp "
          @"'Sleep|Wake|Clamshell' | tail -n 40"))
    complete = NO;
  if (!captureShellToFile(
          [dir stringByAppendingPathComponent:@"ioreg.txt"],
          @"echo '=== IODisplayConnect ==='; ioreg -lw0 -r -c "
          @"IODisplayConnect; echo; echo '=== dcpext ==='; ioreg -lw0 -p "
          @"IOService -n dcpext"))
    complete = NO;

  if (!complete)
    fprintf(stderr,
            "blackoutd: WARNING — bundle incomplete; some files failed\n");
  printf("\nDiagnostic bundle written to %s/ (%.1fs, finished %s)\n",
         dir.UTF8String, -[t0 timeIntervalSinceNow],
         [clock stringFromDate:NSDate.date].UTF8String);
  if (label.length)
    printf("  label.txt        — %s\n", label.UTF8String);
  printf("  config.txt       — this report (build, lid, displays)\n");
  printf("  version.txt      — CLI build identity\n");
  printf(
      "  dcp.txt          — DCP power + framebuffer scanout state (by role)\n");
  printf("  connection-mode.txt — advertised color/encoding catalog (by "
         "display)\n");
  printf("  daemon-log.txt   — blackoutd.log (last 500 lines)\n");
  printf("  system-log.txt   — blackoutd unified log (%s)\n",
         windowText.UTF8String);
  printf("  windowserver.txt — WindowServer/displaypolicyd (%s)\n",
         windowText.UTF8String);
  printf("  sleep-wake.txt   — pmset Sleep/Wake/Clamshell (last 40)\n");
  printf("  ioreg.txt        — IODisplayConnect + dcpext nodes\n");
  return complete ? 0 : 1;
}

static int printStatus(void) {
  pid_t pid = daemonPid();
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  BOOL autoMode = [defaults objectForKey:kAutoBlackoutKey] != nil
                      ? [defaults boolForKey:kAutoBlackoutKey]
                      : YES;
  NSInteger verbosity = [defaults objectForKey:kVerbosityKey] != nil
                            ? [defaults integerForKey:kVerbosityKey]
                            : 1;
  if (pid > 0)
    printf("blackoutd: running (pid %d)\n", pid);
  else
    printf("blackoutd: not running\n");
  printf("  built-in display : %s\n",
         builtInIsOnline() ? "active" : "blacked out");
  printf("  auto-blackout    : %s\n", autoMode ? "enabled" : "disabled");
  printf("  verbosity        : %ld\n", (long)verbosity);
  return pid > 0 ? 0 : 1;
}

static int setAutoBlackout(const char *value) {
  if (strcmp(value, "on") != 0 && strcmp(value, "off") != 0) {
    fprintf(stderr, "Usage: blackoutd auto [on|off]\n");
    return 1;
  }
  BOOL enable = strcmp(value, "on") == 0;
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  [defaults setBool:enable forKey:kAutoBlackoutKey];
  [defaults synchronize];
  printf("auto-blackout: %s\n", enable ? "enabled" : "disabled");
  return sendSignalToDaemon(SIGHUP);
}

// Sets the daemon's log verbosity level, persisted in NSUserDefaults so it
// survives daemon restart, and signals the running daemon (if any) to
// reload preferences immediately. Single-step replacement for the
// two-command `defaults write blackoutd verbosityLevel -int N && killall
// -HUP blackoutd` procedure documented in `docs/technical-debt.md` P20.
//
// Reads-back from NSUserDefaults rather than echoing the input so the
// output reflects what the daemon will actually see on the next reload.
//
// Daemon-not-running case is non-error: the new value persists in
// defaults and takes effect on next start. Returns 0.
static int setVerbosity(const char *value) {
  // Reject non-numeric input early (e.g. "blackoutd verbosity high"). The
  // strtol fallback would silently produce 0, which is a valid level.
  static const char *kVerbosityUsage = "Usage: blackoutd verbosity <0|1|2>\n";

  if (value == NULL || value[0] == '\0') {
    fprintf(stderr, "%s", kVerbosityUsage);
    return 1;
  }

  char *end = NULL;
  errno = 0;
  long level = strtol(value, &end, 10);

  if (*end != '\0' || errno == ERANGE || level < 0 || level > 2) {
    fprintf(stderr, "%s", kVerbosityUsage);
    return 1;
  }

  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  [defaults setInteger:level forKey:kVerbosityKey];
  [defaults synchronize];
  // Read the persisted value back so the reported number is what the daemon
  // will load on reload, not merely the parsed input.
  long applied = (long)[defaults integerForKey:kVerbosityKey];
  pid_t pid = daemonPid();
  if (pid > 0) {
    if (kill(pid, SIGHUP) != 0) {
      if (errno == ESRCH) {
        // Benign race: daemon vanished between lookup and signal. Same outcome
        // as the not-running branch (value persisted, loads on next start), so
        // report success; non-ESRCH errors fall through to a real failure.
        printf("verbosity: %ld (daemon exited before signal delivery; "
               "takes effect on next start)\n",
               applied);
        return 0;
      }

      perror("blackoutd: kill SIGHUP");
      return 1;
    }
    printf("verbosity: %ld (daemon notified)\n", applied);
  } else {
    printf("verbosity: %ld (daemon not running; takes effect on next "
           "start)\n",
           applied);
  }
  return 0;
}

// launchctl bootout exit code 3 means the service was not loaded (launchctl
// maps this to ESRCH). Inconsequential when stopping; suppress it.
static int bootout(void) {
  int rc = runLaunchctl(@[ @"bootout", agentService() ]);
  if (rc == 3)
    return 0;
  return rc;
}

// launchctl bootstrap exit code 5 (EIO) means the service is already
// bootstrapped. Surface a clear message rather than a cryptic exit code.
static int bootstrap(void) {
  if (daemonIsRunning()) {
    fprintf(stderr, "blackoutd: already running\n");
    return 1;
  }
  NSString *plist = agentPlistPath();
  if (![NSFileManager.defaultManager fileExistsAtPath:plist]) {
    fprintf(stderr, "blackoutd: agent plist not found: %s\n", plist.UTF8String);
    fprintf(stderr, "  Run 'make install' first.\n");
    return 1;
  }
  int rc = runLaunchctl(@[ @"bootstrap", agentDomain(), plist ]);
  if (rc == 5) {
    fprintf(stderr, "blackoutd: already bootstrapped (not running). "
                    "Use 'daemon stop' then 'daemon start'.\n");
    return 1;
  }
  if (rc == 0)
    printf("blackoutd: started\n");
  return rc;
}

static void printUsage(void) {
  fprintf(
      stderr,
      "Usage: blackoutd <command>\n"
      "\n"
      "Commands:\n"
      "  on              Black out built-in display\n"
      "  off             Restore built-in display\n"
      "  status          Show daemon and display status (even if not running)\n"
      "  auto on|off     Enable or disable auto-blackout on external connect\n"
      "  verbosity <N>   Set daemon log verbosity (0=quiet, 1=normal,"
      " 2=verbose)\n"
      "  diagnose        Collect a diagnostic bundle for bug reports\n"
      "                  (auto-bounds the window to the last wake; override\n"
      "                  with --minutes N or --start \"T\" --end \"T\";\n"
      "                  --quiet/-q prints only the summary;\n"
      "                  --label TXT tags the bundle)\n"
      "  --version       Print version\n"
      "  daemon start    Start the background daemon via launchctl\n"
      "  daemon stop     Stop the daemon and restore built-in display\n"
      "\n"
      "Experimental (cursor-on-black investigation; maintainer-run):\n"
      "  recover         Run one display-sleep recovery cycle\n"
      "                  (--method displaysleep, --dry-run)\n"
      "  repro           Sleep/wake repro with labeled captures + recovery\n"
      "                  (--wake N, --settle S, --recover METHOD,\n"
      "                  --silent, --dry-run)\n"
      "\n"
      "Internal (used by launchd; not for direct use):\n"
      "  daemon          Run as daemon\n");
}

// Derives a local-time rendering of the embedded UTC build instant for the
// human-facing --version output. Returns nil if BD_BUILD_TIME is the
// "unknown" fallback or otherwise unparseable, in which case the caller
// omits the local line. Local zone reflects whoever runs --version, not the
// build host.
static NSString *localBuildTimeLine(void) {
  NSISO8601DateFormatter *parser = [[NSISO8601DateFormatter alloc] init];
  // Require an explicit zone in the parsed string (the stamp always carries
  // +00:00), so there is no silent assume-local/assume-UTC fallback.
  parser.formatOptions =
      NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithTimeZone;
  NSDate *date = [parser dateFromString:@BD_BUILD_TIME];
  if (!date)
    return nil;
  NSDateFormatter *out = [[NSDateFormatter alloc] init];
  out.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  // Lowercase xxx always emits a numeric offset (+00:00 at zero) rather than
  // collapsing to Z like XXX/ZZZZZ; matches the offset-form build stamp.
  out.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssxxx";
  out.timeZone = NSTimeZone.localTimeZone;
  NSString *abbrev = NSTimeZone.localTimeZone.abbreviation ?: @"local";
  return
      [NSString stringWithFormat:@"%@ (%@)", [out stringFromDate:date], abbrev];
}

static int printVersion(void) {
  // Version is embedded in the binary's __TEXT,__info_plist section.
  NSBundle *main = [NSBundle mainBundle];
  NSString *ver =
      [main objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  printf("blackoutd %s (%s)\n", ver ? ver.UTF8String : "unknown", BD_BUILD_GIT);
  printf("built: %s (UTC)\n", BD_BUILD_TIME);
  NSString *localLine = localBuildTimeLine();
  if (localLine)
    printf("local: %s\n", localLine.UTF8String);
  return 0;
}

// MARK: - Repro / recovery (experimental, maintainer-run)
//
// These subcommands gather empirical cursor-on-black data and prototype the
// one recovery confirmed to work from user space regardless of lock state: a
// programmatic display-sleep cycle. `pmset displaysleepnow` needs no root —
// only `pmset schedule wake` does. They shell out to power-management tools and
// are meant to be run by the maintainer during a repro, never by the daemon.
// `--dry-run` prints each step instead of executing it.

// Runs an external command, or prints it under dry-run. Returns the exit code
// (0 under dry-run), or -1 if the tool could not be launched.
static int runStep(NSString *path, NSArray<NSString *> *args, BOOL dryRun) {
  if (dryRun) {
    printf("  [dry-run] %s %s\n", path.UTF8String,
           [args componentsJoinedByString:@" "].UTF8String);
    return 0;
  }
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:path];
  task.arguments = args;
  NSError *err = nil;
  if (![task launchAndReturnError:&err]) {
    fprintf(stderr, "blackoutd: failed to run %s: %s\n", path.UTF8String,
            err.localizedDescription.UTF8String);
    return -1;
  }
  [task waitUntilExit];
  return (int)task.terminationStatus;
}

// Speaks a short cue so the maintainer can follow blind steps while the screen
// is black, and echoes it to stdout. Best-effort; never fatal.
static void sayCue(NSString *text, BOOL silent, BOOL dryRun) {
  printf("  [step] %s\n", text.UTF8String);
  fflush(stdout);
  // Post a Notification Center banner stamped HH:mm:ss. Invisible while the
  // screen is black, but Notification Center retains it, so after recovery
  // the banner log shows when each stage ran and pairs with the diag
  // bundles' timestamps. --silent suppresses speech only; the notification
  // record is most of the point of a blind run. Cue strings are internal
  // constants, so embedding them in the AppleScript source is safe.
  NSDateFormatter *clock = [[NSDateFormatter alloc] init];
  clock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  clock.dateFormat = @"HH:mm:ss";
  NSString *script =
      [NSString stringWithFormat:@"display notification \"%@ @ %@\" with title "
                                 @"\"blackoutd repro\"",
                                 text, [clock stringFromDate:NSDate.date]];
  runStep(@"/usr/bin/osascript", @[ @"-e", script ], dryRun);
  if (!silent)
    runStep(@"/usr/bin/say", @[ text ], dryRun);
}

// Performs one recovery attempt. The only method today is "displaysleep": a
// programmatic display-sleep cycle (pmset displaysleepnow, then caffeinate -u
// to re-declare user activity and wake the panel). Flicker is accepted; this
// supersedes the older "displaysleepnow = flicker dead end" note now that the
// maintainer confirms it reliably recovers regardless of lock state.
static int performRecovery(NSString *method, BOOL dryRun) {
  if (![method isEqualToString:@"displaysleep"]) {
    fprintf(stderr, "blackoutd: unknown recovery method '%s'\n",
            method.UTF8String);
    return 1;
  }
  int rc = runStep(@"/usr/bin/pmset", @[ @"displaysleepnow" ], dryRun);
  if (rc != 0)
    return rc;
  if (!dryRun)
    [NSThread sleepForTimeInterval:2.0];
  return runStep(@"/usr/bin/caffeinate", @[ @"-u", @"-t", @"2" ], dryRun);
}

// blackoutd recover [--method displaysleep] [--dry-run]
static int recoverCommand(int argc, const char *argv[]) {
  NSString *method = @"displaysleep";
  BOOL dryRun = NO;
  for (int i = 2; i < argc; i++) {
    const char *opt = argv[i];
    if (strcmp(opt, "--dry-run") == 0) {
      dryRun = YES;
    } else if (strcmp(opt, "--method") == 0) {
      if (i + 1 >= argc) {
        fprintf(stderr, "blackoutd: --method requires a value\n");
        return 1;
      }
      method = @(argv[++i]);
    } else {
      fprintf(stderr, "blackoutd: unknown recover option '%s'\n", opt);
      return 1;
    }
  }
  return performRecovery(method, dryRun);
}

// Captures a labeled diagnose bundle (or prints the intent under dry-run).
static void reproCapture(NSString *label, BOOL dryRun) {
  if (dryRun) {
    printf("  [dry-run] diagnose --quiet --label %s\n", label.UTF8String);
    return;
  }
  NSString *bundleDir = nil;
  runDiagnose(0, nil, nil, YES, label, &bundleDir);
  if (!bundleDir)
    return;
  // Pair the stage with its bundle by NAME, not by clock correlation: the
  // sayCue banner precedes the capture by the (synchronous) speech duration,
  // so timestamps alone drift by a couple of seconds. Label and dir basename
  // are internal values, safe to embed in the AppleScript source.
  NSString *script = [NSString
      stringWithFormat:@"display notification \"%@ -> %@\" with title "
                       @"\"blackoutd repro\"",
                       label, bundleDir.lastPathComponent];
  runStep(@"/usr/bin/osascript", @[ @"-e", script ], NO);
}

// blackoutd repro [--wake N] [--settle S] [--recover METHOD] [--silent]
//                 [--dry-run]
// Schedules an auto-wake (sudo — only the schedule needs it), sleeps, then on
// wake captures a labeled bundle, optionally runs a recovery, and captures
// again. Built to run blind: it narrates each step via `say`.
static int reproCommand(int argc, const char *argv[]) {
  int wake = 15, settle = 20;
  NSString *recover = nil;
  BOOL silent = NO, dryRun = NO;
  for (int i = 2; i < argc; i++) {
    const char *opt = argv[i];
    if (strcmp(opt, "--silent") == 0) {
      silent = YES;
    } else if (strcmp(opt, "--dry-run") == 0) {
      dryRun = YES;
    } else if (strcmp(opt, "--wake") == 0 || strcmp(opt, "--settle") == 0 ||
               strcmp(opt, "--recover") == 0) {
      if (i + 1 >= argc) {
        fprintf(stderr, "blackoutd: %s requires a value\n", opt);
        return 1;
      }
      const char *val = argv[++i];
      if (strcmp(opt, "--recover") == 0) {
        recover = @(val);
      } else {
        char *parseEnd = NULL;
        errno = 0;
        long n = strtol(val, &parseEnd, 10);
        if (*parseEnd != '\0' || errno != 0 || n < 0) {
          fprintf(stderr, "blackoutd: %s requires a non-negative integer\n",
                  opt);
          return 1;
        }
        if (strcmp(opt, "--wake") == 0)
          wake = (int)n;
        else
          settle = (int)n;
      }
    } else {
      fprintf(stderr, "blackoutd: unknown repro option '%s'\n", opt);
      return 1;
    }
  }

  // Schedule the auto-wake first (only this needs sudo). wake=0 means the
  // maintainer will wake the machine manually (e.g. by opening the lid).
  if (wake > 0) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"MM/dd/yy HH:mm:ss";
    NSString *when =
        [f stringFromDate:[NSDate dateWithTimeIntervalSinceNow:wake]];
    printf("repro: scheduling wake at %s (sudo)\n", when.UTF8String);
    if (runStep(@"/usr/bin/sudo", @[ @"pmset", @"schedule", @"wake", when ],
                dryRun) != 0) {
      fprintf(stderr, "repro: could not schedule wake; aborting\n");
      return 1;
    }
  }

  sayCue(@"sleeping now", silent, dryRun);
  if (runStep(@"/usr/bin/pmset", @[ @"sleepnow" ], dryRun) != 0)
    return 1;
  // System sleeps here; execution resumes on the scheduled wake.
  if (!dryRun)
    [NSThread sleepForTimeInterval:settle];

  sayCue(@"capturing post wake", silent, dryRun);
  reproCapture(@"post-wake", dryRun);

  int recoveryRC = 0;
  if (recover.length) {
    sayCue(@"recovering", silent, dryRun);
    // Surface a failed recovery loudly and in the exit code: a post-recover
    // capture taken after a recovery that never ran would otherwise read as
    // "recovery did not clear the black" and poison the matrix data. The
    // capture still proceeds — the bundle is useful either way.
    recoveryRC = performRecovery(recover, dryRun);
    if (recoveryRC != 0)
      fprintf(stderr,
              "repro: recovery method '%s' failed (rc=%d); continuing\n",
              recover.UTF8String, recoveryRC);
    if (!dryRun)
      [NSThread sleepForTimeInterval:settle];
    sayCue(@"capturing post recover", silent, dryRun);
    reproCapture(@"post-recover", dryRun);
  }
  printf("repro: done\n");
  return recoveryRC;
}

int main(int argc, const char *argv[]) {
  setvbuf(stderr, NULL, _IONBF, 0);

  @autoreleasepool {
    if (argc < 2) {
      printUsage();
      return 1;
    }

    const char *cmd = argv[1];
    if (strcmp(cmd, "on") == 0)
      return sendSignalToDaemon(SIGUSR1);
    if (strcmp(cmd, "off") == 0)
      return sendSignalToDaemon(SIGUSR2);
    if (strcmp(cmd, "status") == 0)
      return printStatus();
    if (strcmp(cmd, "diagnose") == 0) {
      int minutes = 0;
      BOOL quiet = NO;
      NSString *start = nil, *end = nil, *label = nil;
      for (int i = 2; i < argc; i++) {
        const char *opt = argv[i];
        if (strcmp(opt, "--quiet") == 0 || strcmp(opt, "-q") == 0) {
          quiet = YES;
          continue;
        }
        BOOL isMinutes = strcmp(opt, "--minutes") == 0;
        BOOL isStart = strcmp(opt, "--start") == 0;
        BOOL isEnd = strcmp(opt, "--end") == 0;
        BOOL isLabel = strcmp(opt, "--label") == 0;
        if (!isMinutes && !isStart && !isEnd && !isLabel) {
          fprintf(stderr, "blackoutd: unknown diagnose option '%s'\n", opt);
          return 1;
        }
        if (i + 1 >= argc) {
          fprintf(stderr, "blackoutd: diagnose option '%s' requires a value\n",
                  opt);
          return 1;
        }
        const char *val = argv[++i];
        if ((isStart || isEnd || isLabel) && *val == '\0') {
          fprintf(stderr, "blackoutd: %s requires a non-empty value\n", opt);
          return 1;
        }
        if (isMinutes) {
          char *parseEnd = NULL;
          errno = 0;
          long m = strtol(val, &parseEnd, 10);
          if (*parseEnd != '\0' || errno != 0 || m <= 0) {
            fprintf(stderr,
                    "blackoutd: --minutes requires a positive integer\n");
            return 1;
          }
          minutes = (int)m;
        } else if (isStart) {
          start = @(val);
        } else if (isEnd) {
          end = @(val);
        } else {
          label = @(val);
        }
      }
      if (end && !start) {
        fprintf(stderr, "blackoutd: --end requires --start\n");
        return 1;
      }
      return runDiagnose(minutes, start, end, quiet, label, NULL);
    }
    if (strcmp(cmd, "recover") == 0)
      return recoverCommand(argc, argv);
    if (strcmp(cmd, "repro") == 0)
      return reproCommand(argc, argv);
    if (strcmp(cmd, "--version") == 0)
      return printVersion();
    if (strcmp(cmd, "daemon") == 0) {
      if (argc >= 3) {
        if (strcmp(argv[2], "start") == 0)
          return bootstrap();
        if (strcmp(argv[2], "stop") == 0)
          return bootout();
        fprintf(stderr, "Usage: blackoutd daemon [start|stop]\n");
        return 1;
      }
      // No subcommand — fall through to daemon run loop below.
    } else if (strcmp(cmd, "auto") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Usage: blackoutd auto [on|off]\n");
        return 1;
      }
      return setAutoBlackout(argv[2]);
    } else if (strcmp(cmd, "verbosity") == 0) {
      if (argc < 3) {
        fprintf(stderr, "Usage: blackoutd verbosity <0|1|2>\n");
        return 1;
      }
      return setVerbosity(argv[2]);
    }
    // "daemon" with no subcommand falls through to daemon run loop below.
    if (strcmp(cmd, "daemon") != 0) {
      printUsage();
      return 1;
    }
  }

  // Daemon path. Record build identity at the top of every session so the
  // running binary can be matched against source from the log alone.
  NSLog(@"[startup] — build=%s built=%s", BD_BUILD_GIT, BD_BUILD_TIME);

  NSApplication *app = [NSApplication sharedApplication];
  AppDelegate *delegate = [[AppDelegate alloc] init];
  app.delegate = delegate;
  [app run];
  return 0;
}
