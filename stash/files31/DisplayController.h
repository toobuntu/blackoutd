#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class DisplayController;

@protocol DisplayControllerDelegate <NSObject>
- (void)displayController:(DisplayController *)controller
      blackoutStateChanged:(BOOL)isBlackedOut;
@end

@interface DisplayController : NSObject

@property (nonatomic, weak, nullable) id<DisplayControllerDelegate> delegate;
@property (nonatomic, readonly) BOOL isBlackedOut;
@property (nonatomic, assign) BOOL autoBlackoutOnExternalConnect;

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
@property (nonatomic, assign) NSInteger verbosityLevel;

/// When YES, reconfiguration callbacks are suppressed — set during sleep
/// to prevent false restores from OS-generated display events.
@property (nonatomic, assign) BOOL suppressCallbacks;

- (BOOL)enableBlackout;
- (BOOL)disableBlackout;
- (BOOL)hasActiveExternalDisplay;
- (BOOL)builtInIsOnline;

/// Adopt blacked-out state without issuing a CGS call — for use when the
/// built-in is already offline at startup.
- (void)adoptBlackedOutState;

/// Clear in-process display state without touching hardware. Call before
/// re-applying state after a sleep/wake cycle to treat ivar state as stale.
/// Returns the prior isBlackedOut value for wake-path decision making.
- (BOOL)invalidateDisplayState;

// Called by the CGDisplay reconfiguration callback — not for external use.
- (void)handleReconfiguration:(CGDirectDisplayID)displayID
                         flags:(CGDisplayChangeSummaryFlags)flags;

@end

NS_ASSUME_NONNULL_END
