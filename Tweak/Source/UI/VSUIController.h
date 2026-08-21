//  VSUIController.h — the UI coordinator (bootstrap step 8).
//
//  Owns the overlay window and the floating button, and is the one place that
//  knows how to reach Instagram's own view-controller stack. It exists because
//  the two hard UI constraints from ARCHITECTURE §5 are coordination problems,
//  not view problems: the button must attach only once a foreground scene is
//  live, and every panel must be presented from Instagram's top view controller
//  (never from the overlay window, which cannot present a keyboard-driven UI
//  without stealing focus).

#import <UIKit/UIKit.h>

@interface VSUIController : NSObject

+ (instancetype)shared;

/// Called from VSBootstrap after the self-test. Safe before UIApplication
/// exists: it waits for the first foreground-active scene, then attaches the
/// button exactly once.
+ (void)scheduleAttach;

/// Instagram's current top-most view controller, for presenting our panels over
/// its content. nil before a scene is live.
+ (UIViewController *)topViewController;

/// Present the main panel (called by the floating button).
- (void)presentPanel;

/// Records nothing itself — the switch is already persisted — then terminates so
/// the next launch comes up cleanly on the chosen container (ARCHITECTURE rule 5:
/// a hot switch leaves Instagram in a hybrid state and freezes).
+ (void)relaunchToApplyContainerSwitch;

@end
