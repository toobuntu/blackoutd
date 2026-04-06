/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "AppDelegate.h"
#import <notify.h>

static NSString *const kBundleID = @BD_BUNDLE_ID;
static NSString *const kSuiteName = @"blackoutd";
static NSString *const kAutoBlackoutKey = @"autoBlackoutOnExternalConnect";
static NSString *const kBlackoutActiveKey = @"blackoutActive";
static NSString *const kAgentLabel = @BD_BUNDLE_ID;

@implementation AppDelegate {
  DisplayController *_displayController;
  NSStatusItem *_statusItem;
  NSMenuItem *_toggleItem;
  NSMenuItem *_autoItem;
  NSUserDefaults *_defaults;
  dispatch_source_t _sigusr1Source;
  dispatch_source_t _sigusr2Source;
  dispatch_source_t _sighupSource;
  dispatch_source_t _sigtermSource;
  dispatch_source_t _sigintSource;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

  _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];

  _displayController = [[DisplayController alloc] init];
  _displayController.delegate = self;

  [self reloadPreferences];
  NSLog(@"[startup] — verbosityLevel=%ld",
        (long)_displayController.verbosityLevel);
  [self setupMenuBar];
  [self setupSignalHandlers];
  [self setupSleepWakeObservers];
  [self waitForWindowServerThenRestoreState];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  NSLog(@"[quit] — stopping");
  [_displayController disableBlackout];
}

// MARK: - WindowServer Readiness

- (void)waitForWindowServerThenRestoreState {
  // CGMainDisplayID returns non-zero only when the WindowServer connection
  // is already established. If so, restore state immediately rather than
  // waiting for a notification that may already have fired.
  if (CGMainDisplayID() != 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self restorePersistedState];
    });
    return;
  }
  int __block token = 0;
  notify_register_dispatch("com.apple.windowserver.active", &token,
                           dispatch_get_main_queue(), ^(int t) {
                             notify_cancel(t);
                             [self restorePersistedState];
                           });
}

// MARK: - State Restoration

- (void)restorePersistedState {
  if (![_displayController builtInIsOnline]) {
    NSLog(@"blackoutd: built-in already offline at startup — adopting state");
    [_displayController adoptBlackedOutState];
    [self updateMenuBarIcon];
    return;
  }

  // Attempt blackout if persisted intent or auto-blackout is enabled.
  // enableBlackout checks for an active external display internally.
  if ([_defaults boolForKey:kBlackoutActiveKey] ||
      _displayController.autoBlackoutOnExternalConnect) {
    [_displayController enableBlackout];
  }
}

// MARK: - Preferences

- (void)reloadPreferences {
  [_defaults synchronize];
  BOOL autoOn = [_defaults objectForKey:kAutoBlackoutKey] != nil
                    ? [_defaults boolForKey:kAutoBlackoutKey]
                    : YES;
  _displayController.autoBlackoutOnExternalConnect = autoOn;
  if (_autoItem) {
    _autoItem.state = autoOn ? NSControlStateValueOn : NSControlStateValueOff;
  }
  NSInteger verbosity = [_defaults objectForKey:@"verbosityLevel"] != nil
                            ? [_defaults integerForKey:@"verbosityLevel"]
                            : 1;
  _displayController.verbosityLevel = verbosity;
}

// MARK: - Quitting

- (void)bootoutAndQuit {
  NSString *domain =
      [NSString stringWithFormat:@"gui/%d/%@", getuid(), kAgentLabel];
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
  task.arguments = @[ @"bootout", domain ];
  [task launch];
}

// MARK: - Menu Bar

- (void)setupMenuBar {
  _statusItem = [NSStatusBar.systemStatusBar
      statusItemWithLength:NSVariableStatusItemLength];
  [self updateMenuBarIcon];

  NSMenu *menu = [[NSMenu alloc] init];

  _toggleItem = [[NSMenuItem alloc] initWithTitle:[self toggleItemTitle]
                                           action:@selector(toggleBlackout:)
                                    keyEquivalent:@""];
  _toggleItem.target = self;
  [menu addItem:_toggleItem];

  [menu addItem:NSMenuItem.separatorItem];

  _autoItem =
      [[NSMenuItem alloc] initWithTitle:@"Auto-blackout on External Connect"
                                 action:@selector(toggleAutoBlackout:)
                          keyEquivalent:@""];
  _autoItem.target = self;
  _autoItem.state = _displayController.autoBlackoutOnExternalConnect
                        ? NSControlStateValueOn
                        : NSControlStateValueOff;
  [menu addItem:_autoItem];

  [menu addItem:NSMenuItem.separatorItem];

  NSMenuItem *quitItem =
      [[NSMenuItem alloc] initWithTitle:@"Quit blackoutd"
                                 action:@selector(bootoutAndQuit)
                          keyEquivalent:@"q"];
  quitItem.target = self;
  [menu addItem:quitItem];

  _statusItem.menu = menu;
}

- (NSString *)toggleItemTitle {
  return _displayController.isBlackedOut ? @"Restore Built-in Display"
                                         : @"Black Out Built-in Display";
}

- (void)updateMenuBarIcon {
  NSString *symbol =
      _displayController.isBlackedOut ? @"macbook.slash" : @"macbook";
  NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                             accessibilityDescription:nil];
  image.template = YES;
  _statusItem.button.image = image;
  _toggleItem.title = [self toggleItemTitle];
}

- (void)toggleBlackout:(id)sender {
  if (_displayController.isBlackedOut)
    [_displayController disableBlackout];
  else
    [_displayController enableBlackout];
}

- (void)toggleAutoBlackout:(id)sender {
  BOOL newValue = !_displayController.autoBlackoutOnExternalConnect;
  _displayController.autoBlackoutOnExternalConnect = newValue;
  [_defaults setBool:newValue forKey:kAutoBlackoutKey];
  _autoItem.state = newValue ? NSControlStateValueOn : NSControlStateValueOff;

  if (newValue) {
    // Enabling: black out immediately if external is already connected.
    if (!_displayController.isBlackedOut &&
        [_displayController hasActiveExternalDisplay]) {
      [_displayController enableBlackout];
    }
  } else {
    // Disabling: restore built-in if currently blacked out.
    if (_displayController.isBlackedOut) {
      [_displayController disableBlackout];
    }
  }
}

// MARK: - DisplayControllerDelegate

- (void)displayController:(DisplayController *)controller
     blackoutStateChanged:(BOOL)isBlackedOut {
  [_defaults setBool:isBlackedOut forKey:kBlackoutActiveKey];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateMenuBarIcon];
  });
}

// MARK: - Sleep / Wake

- (void)setupSleepWakeObservers {
  NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
  [nc addObserver:self
         selector:@selector(systemWillSleep:)
             name:NSWorkspaceWillSleepNotification
           object:nil];
  [nc addObserver:self
         selector:@selector(systemDidWake:)
             name:NSWorkspaceDidWakeNotification
           object:nil];
}

- (void)systemWillSleep:(NSNotification *)note {
  NSLog(@"[sleep] — ignoring display changes");
  _displayController.systemSleeping = YES;
}

- (void)systemDidWake:(NSNotification *)note {
  // Clear stale in-process state. If a hardware external disconnect was
  // observed during sleep, restore the built-in now — the display system
  // is still settling at wake time so a live hardware query is unreliable.
  NSLog(@"[wake] — resuming display change monitoring");
  _displayController.systemSleeping = NO;
  BOOL externalUnplugged = [_displayController invalidateDisplayState];
  if (externalUnplugged) {
    NSLog(@"[wake] — external disconnected during sleep — disabling blackout");
    [_defaults setBool:NO forKey:kBlackoutActiveKey];
    [_displayController disableBlackout];
    return;
  }

  // The display system may have already settled while systemSleeping was YES,
  // meaning the external's re-announcement callback was dropped. Schedule a
  // deferred check: after 2 seconds (display pipeline settle time), if
  // auto-blackout is enabled, an external is present, and we are not blacked
  // out, re-apply blackout. If the callback path handles it first, the guard
  // in enableBlackout prevents a duplicate action.
  if (_displayController.autoBlackoutOnExternalConnect) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          if (!self->_displayController.isBlackedOut &&
              self->_displayController.autoBlackoutOnExternalConnect &&
              [self->_displayController hasActiveExternalDisplay]) {
            NSLog(@"[wake] — deferred check: external present, re-applying "
                  @"blackout");
            [self->_displayController enableBlackout];
          }
        });
  }
}

// MARK: - Signal Handling

- (void)setupSignalHandlers {
  signal(SIGUSR1, SIG_IGN);
  signal(SIGUSR2, SIG_IGN);
  signal(SIGHUP, SIG_IGN);
  signal(SIGTERM, SIG_IGN);
  signal(SIGINT, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);

  _sigusr1Source =
      [self dispatchSourceForSignal:SIGUSR1
                            handler:^{
                              [self->_displayController enableBlackout];
                            }];
  _sigusr2Source =
      [self dispatchSourceForSignal:SIGUSR2
                            handler:^{
                              [self->_displayController disableBlackout];
                            }];
  _sighupSource = [self dispatchSourceForSignal:SIGHUP
                                        handler:^{
                                          [self reloadPreferences];
                                        }];
  _sigtermSource = [self dispatchSourceForSignal:SIGTERM
                                         handler:^{
                                           [NSApp terminate:nil];
                                         }];
  _sigintSource = [self dispatchSourceForSignal:SIGINT
                                        handler:^{
                                          [NSApp terminate:nil];
                                        }];
}

- (dispatch_source_t)dispatchSourceForSignal:(int)sig
                                     handler:(dispatch_block_t)handler {
  dispatch_source_t source = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, handler);
  dispatch_resume(source);
  return source;
}

@end
