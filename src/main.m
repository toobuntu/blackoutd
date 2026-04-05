/*
 * SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// CLI entry point — daemon run loop is at the bottom of this file.

#import "AppDelegate.h"
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

static NSString *const kBundleID = @BD_BUNDLE_ID;
static NSString *const kSuiteName = @"blackoutd";
static NSString *const kAutoBlackoutKey = @"autoBlackoutOnExternalConnect";
static NSString *const kAgentLabel = @BD_BUNDLE_ID;

static NSString *agentPlistPath(void) {
    return [NSHomeDirectory()
        stringByAppendingPathComponent:
            [@"Library/LaunchAgents/"
                stringByAppendingString:[kAgentLabel stringByAppendingString:@".plist"]]];
}

static NSString *agentDomain(void) { return [NSString stringWithFormat:@"gui/%d", getuid()]; }

static NSString *agentService(void) {
    return [NSString stringWithFormat:@"gui/%d/%@", getuid(), kAgentLabel];
}

static int runLaunchctl(NSArray<NSString *> *args) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = args;
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        fprintf(stderr, "blackoutd: launchctl failed: %s\n", err.localizedDescription.UTF8String);
        return 1;
    }
    [task waitUntilExit];
    return (int)task.terminationStatus;
}

// Returns the daemon's PID if running, 0 otherwise.
// Uses `launchctl list` with no arguments — its tab-separated output
// (PID\tStatus\tLabel) is the stable legacy format per man launchctl.
// The PID field is '-' when the agent is registered but not running.
static pid_t daemonPid(void) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[ @"list" ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![task launchAndReturnError:&err])
        return 0;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0)
        return 0;
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if (![line containsString:kAgentLabel])
            continue;
        NSString *firstField = [[line componentsSeparatedByString:@"\t"] firstObject];
        if (!firstField || [firstField hasPrefix:@"-"])
            return 0;
        return (pid_t)[firstField intValue];
    }
    return 0;
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

// Runs a shell pipeline via /bin/sh -c, prints its stdout to our stdout.
static int runShell(NSString *command) { return runAndPrint(@"/bin/sh", @[ @"-c", command ]); }

static int printConfig(void) {
    NSProcessInfo *info = [NSProcessInfo processInfo];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    BOOL autoMode = [defaults objectForKey:kAutoBlackoutKey] != nil
                        ? [defaults boolForKey:kAutoBlackoutKey]
                        : YES;

    printf("--- blackoutd diagnostic info ---\n\n");

    // Daemon status
    pid_t pid = daemonPid();
    printf("daemon          : %s\n", pid > 0 ? "running" : "not running");
    if (pid > 0)
        printf("daemon pid      : %d\n", pid);
    printf("built-in display: %s\n", builtInIsOnline() ? "active" : "blacked out");
    printf("auto-blackout   : %s\n", autoMode ? "enabled" : "disabled");
    printf("bundle-id       : %s\n", kBundleID.UTF8String);

    // macOS version (API)
    NSOperatingSystemVersion ver = info.operatingSystemVersion;
    printf("macOS           : %ld.%ld.%ld\n", (long)ver.majorVersion, (long)ver.minorVersion,
           (long)ver.patchVersion);

    // Architecture (API — sysctl via uname is simpler)
    printf("\n");
    runAndPrint(@"/usr/bin/uname", @[ @"-m" ]);

    // Hardware and display info
    printf("\n--- system_profiler ---\n");
    runAndPrint(@"/usr/sbin/system_profiler",
                @[ @"SPHardwareDataType", @"SPDisplaysDataType", @"-detailLevel", @"mini" ]);

    // Recent sleep/wake events
    printf("\n--- pmset sleep/wake log (last 30 entries) ---\n");
    runShell(@"pmset -g log | grep -E 'Sleep|Wake|Clamshell' | tail -30");

    // Recent daemon logs
    printf("\n--- blackoutd log (last 5 minutes) ---\n");
    runShell(@"log show --last 5m --predicate 'process == \"blackoutd\"' --style compact");

    return 0;
}

static int printStatus(void) {
    if (!daemonIsRunning()) {
        printf("blackoutd: not running\n");
        return 1;
    }
    pid_t pid = daemonPid();
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    BOOL autoMode = [defaults objectForKey:kAutoBlackoutKey] != nil
                        ? [defaults boolForKey:kAutoBlackoutKey]
                        : YES;
    printf("blackoutd: running (pid %d)\n", pid);
    printf("  built-in display : %s\n", builtInIsOnline() ? "active" : "blacked out");
    printf("  auto-blackout    : %s\n", autoMode ? "enabled" : "disabled");
    return 0;
}

static int setAutoBlackout(const char *value) {
    if (strcmp(value, "on") != 0 && strcmp(value, "off") != 0) {
        fprintf(stderr, "Usage: blackoutd auto [on|off]\n");
        return 1;
    }
    BOOL enable = strcmp(value, "on") == 0;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [defaults setBool:enable forKey:kAutoBlackoutKey];
    [defaults synchronize];
    printf("auto-blackout: %s\n", enable ? "enabled" : "disabled");
    return sendSignalToDaemon(SIGHUP);
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
    fprintf(stderr, "Usage: blackoutd <command>\n"
                    "\n"
                    "Commands:\n"
                    "  on              Black out built-in display\n"
                    "  off             Restore built-in display\n"
                    "  status          Show daemon and display status (even if not running)\n"
                    "  auto on|off     Enable or disable auto-blackout on external connect\n"
                    "  --config        Print diagnostic info for bug reports\n"
                    "  daemon start    Start the background daemon via launchctl\n"
                    "  daemon stop     Stop the daemon and restore built-in display\n"
                    "\n"
                    "Internal (used by launchd; not for direct use):\n"
                    "  daemon          Run as daemon\n");
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
