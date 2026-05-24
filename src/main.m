/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// CLI entry point — daemon run loop is at the bottom of this file.

#import "AppDelegate.h"
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <errno.h>
#import <libproc.h>
#import <sys/sysctl.h>

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

// Runs a shell pipeline via /bin/sh -c, capturing stdout to a file.
static int runShellToFile(NSString *filePath, NSString *command) {
  return runToFile(filePath, @"/bin/sh", @[ @"-c", command ]);
}

// Runs an executable with arguments, prints its stdout to our stdout.
// Returns the process exit code, or -1 on launch failure.
static int runAndPrint(NSString *path, NSArray<NSString *> *args) {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:path];
  task.arguments = args;
  NSError *err = nil;
  if (![task launchAndReturnError:&err])
    return -1;
  [task waitUntilExit];
  return (int)task.terminationStatus;
}

static void printDisplays(void) {
  CGDirectDisplayID displays[8];
  uint32_t count = 0;
  CGGetOnlineDisplayList(8, displays, &count);
  printf("\n--- Displays (%u online) ---\n", count);
  for (uint32_t i = 0; i < count; i++) {
    CGDirectDisplayID d = displays[i];
    BOOL builtin = CGDisplayIsBuiltin(d);
    BOOL active = CGDisplayIsActive(d);
    uint32_t vendor = CGDisplayVendorNumber(d);
    uint32_t model = CGDisplayModelNumber(d);
    uint32_t serial = CGDisplaySerialNumber(d);
    CGRect bounds = CGDisplayBounds(d);
    CGSize size = CGDisplayScreenSize(d);

    printf("\nDisplay %u (%s)\n", d, builtin ? "built-in" : "external");
    printf("  Active          : %s\n", active ? "yes" : "no");
    printf("  Vendor          : 0x%04x\n", vendor);
    printf("  Model           : 0x%04x\n", model);
    if (serial != 0)
      printf("  Serial          : 0x%08x\n", serial);
    printf("  Resolution      : %.0f x %.0f\n", bounds.size.width,
           bounds.size.height);
    printf("  Physical size   : %.1fmm x %.1fmm\n", size.width, size.height);
  }
}

static int printConfig(void) {
  NSProcessInfo *info = [NSProcessInfo processInfo];
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  BOOL autoMode = [defaults objectForKey:kAutoBlackoutKey] != nil
                      ? [defaults boolForKey:kAutoBlackoutKey]
                      : YES;
  NSInteger verbosity = [defaults objectForKey:kVerbosityKey] != nil
                            ? [defaults integerForKey:kVerbosityKey]
                            : 1;

  printf("--- blackoutd diagnostic info ---\n\n");

  pid_t pid = daemonPid();
  printf("daemon          : %s\n", pid > 0 ? "running" : "not running");
  if (pid > 0)
    printf("daemon pid      : %d\n", pid);
  printf("built-in display: %s\n",
         builtInIsOnline() ? "active" : "blacked out");
  printf("auto-blackout   : %s\n", autoMode ? "enabled" : "disabled");
  printf("verbosity       : %ld\n", (long)verbosity);
  printf("bundle-id       : %s\n", kBundleID.UTF8String);

  NSOperatingSystemVersion ver = info.operatingSystemVersion;
  printf("macOS           : %ld.%ld.%ld\n", (long)ver.majorVersion,
         (long)ver.minorVersion, (long)ver.patchVersion);

  printf("arch            : ");
  runAndPrint(@"/usr/bin/uname", @[ @"-m" ]);

  printDisplays();

  printf("\n--- system_profiler ---\n");
  runAndPrint(@"/usr/sbin/system_profiler", @[
    @"SPHardwareDataType", @"SPDisplaysDataType", @"-detailLevel", @"mini"
  ]);

  // Collect logs into a temp directory to avoid flooding stdout.
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.dateFormat = @"yyyyMMdd-HHmmss";
  NSString *stamp = [fmt stringFromDate:[NSDate date]];
  NSString *dir = [NSString stringWithFormat:@"/tmp/blackoutd-diag-%@", stamp];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  NSString *logFile = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Logs/blackoutd.log"];
  if ([fm fileExistsAtPath:logFile]) {
    runShellToFile([dir stringByAppendingPathComponent:@"daemon-log.txt"],
                   [NSString stringWithFormat:@"tail -500 '%@'", logFile]);
  }

  runShellToFile([dir stringByAppendingPathComponent:@"system-log.txt"],
                 @"log show --last 5m --predicate 'process == \"blackoutd\"' "
                 @"--style compact 2>&1");

  runShellToFile(
      [dir stringByAppendingPathComponent:@"sleep-wake.txt"],
      @"pmset -g log 2>/dev/null | grep -E 'Sleep|Wake|Clamshell' | tail -30");

  printf("\nLog files collected in %s/\n", dir.UTF8String);
  printf("  daemon-log.txt  — blackoutd.log (last 500 lines)\n");
  printf("  system-log.txt  — system log filtered by blackoutd "
         "(last 5 minutes)\n");
  printf("  sleep-wake.txt  — pmset sleep/wake events (last 30)\n");

  return 0;
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
  for (const char *p = value; *p; p++) {
    if (*p < '0' || *p > '9') {
      fprintf(stderr, "Usage: blackoutd verbosity <0|1|2>\n");
      return 1;
    }
  }
  long level = strtol(value, NULL, 10);
  if (level < 0 || level > 2) {
    fprintf(stderr, "verbosity level must be 0, 1, or 2\n");
    return 1;
  }
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
  [defaults setInteger:level forKey:kVerbosityKey];
  [defaults synchronize];
  pid_t pid = daemonPid();
  if (pid > 0) {
    if (kill(pid, SIGHUP) != 0) {
      perror("blackoutd: kill SIGHUP");
      return 1;
    }
    printf("verbosity: %ld (daemon notified)\n", level);
  } else {
    printf("verbosity: %ld (daemon not running; takes effect on next "
           "start)\n",
           level);
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
      "  --config        Print diagnostic info for bug reports\n"
      "  --version       Print version\n"
      "  daemon start    Start the background daemon via launchctl\n"
      "  daemon stop     Stop the daemon and restore built-in display\n"
      "\n"
      "Internal (used by launchd; not for direct use):\n"
      "  daemon          Run as daemon\n");
}

static int printVersion(void) {
  // Version is embedded in the binary's __TEXT,__info_plist section.
  NSBundle *main = [NSBundle mainBundle];
  NSString *ver =
      [main objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  printf("blackoutd %s\n", ver ? ver.UTF8String : "unknown");
  return 0;
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
    if (strcmp(cmd, "--config") == 0)
      return printConfig();
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

  NSApplication *app = [NSApplication sharedApplication];
  AppDelegate *delegate = [[AppDelegate alloc] init];
  app.delegate = delegate;
  [app run];
  return 0;
}
