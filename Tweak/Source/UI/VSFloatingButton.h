//  VSFloatingButton.h — the always-present entry point to Vessel.
//
//  A 56 pt frosted capsule that shows the active container's accent ring, its
//  initial, and a badge with the container count. Draggable, with edge magnetism
//  and a spring settle; it dims to semi-transparent after a few seconds idle and
//  wakes on touch. Position is remembered across launches (in a store outside all
//  containers, so a container switch never moves the button). Tapping it calls
//  `onTap` — the coordinator then presents the panel from Instagram's own top VC.

#import <UIKit/UIKit.h>

@interface VSFloatingButton : UIView

/// Invoked on a tap (not a drag). The coordinator presents the main panel.
@property (nonatomic, copy) void (^onTap)(void);

/// Invoked on a long press (hold in place). The coordinator presents the quick
/// account switcher ("Bascule rapide"). A drag still moves the button, and a plain
/// tap still opens the full panel — the three gestures do not collide.
@property (nonatomic, copy) void (^onLongPress)(void);

/// Re-read the active container (accent, initial) and the container count (badge).
/// Safe to call from the container-changed notification.
- (void)refresh;

@end
