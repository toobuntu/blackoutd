/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DisplayController;

@protocol DisplayControllerDelegate <NSObject>
- (void)displayController:(DisplayController *)controller
     blackoutStateChanged:(BOOL)isBlackedOut;
@end

@interface DisplayController : NSObject

@property(nonatomic, weak, nullable) id<DisplayControllerDelegate> delegate;
@property(nonatomic, readonly) BOOL isBlackedOut;
@property(nonatomic, assign) BOOL autoBlackoutOnExternalConnect;

/// Verbosity level for logging. 1 = semantic (default), 2 = verbose (adds
/// [verbose=2]-tagged lines with raw flags and connectivity details).
/// Reload at runtime via SIGHUP without restarting the daemon:
///
///   defaults write blackoutd verbosityLevel -int 2
///   killall -HUP blackoutd
///
/// Reset to default:
///
///   defaults delete blackoutd verbosityLevel
///   killall -HUP blackoutd
@property(nonatomic, assign) NSInteger verbosityLevel;

/// Set to YES during system sleep. Display change events are still logged
/// but state changes are not acted on until wake.
@property(nonatomic, assign) BOOL systemSleeping;

- (BOOL)enableBlackout;
- (BOOL)disableBlackout;
- (BOOL)hasActiveExternalDisplay;
- (BOOL)builtInIsOnline;

/// Adopt blacked-out state without issuing a CGS call — for use when the
/// built-in is already offline at startup.
- (void)adoptBlackedOutState;

/// Clear in-process display state without touching hardware. Call before
/// re-applying state after a sleep/wake cycle to treat ivar state as stale.
/// Returns YES if a hardware external display disconnect was observed during
/// sleep — the caller should restore the built-in in that case.
- (BOOL)invalidateDisplayState;

// Called by the CGDisplay reconfiguration callback — not for external use.
- (void)handleReconfiguration:(CGDirectDisplayID)displayID
                        flags:(CGDisplayChangeSummaryFlags)flags;

@end

NS_ASSUME_NONNULL_END
