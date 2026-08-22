//  VSQuickSwitchVC.h — "Bascule rapide", the long-press quick account switcher.
//
//  A compact medium-detent frosted sheet showing every container as a card in a
//  horizontal carousel. Tapping a non-active card confirms, records the choice and
//  relaunches (ARCHITECTURE rule 5: never re-point a running app). It is a shortcut
//  onto the same switch flow as the full panel — creation, deletion and settings
//  still live there. The coordinator only opens it when there are ≥2 containers;
//  with a single one there is nothing to switch between, so it opens the full panel.

#import <UIKit/UIKit.h>

@interface VSQuickSwitchVC : UIViewController

/// Fired once when the sheet is dismissed, so the coordinator can bring the
/// floating button back (it is hidden while any Vessel sheet is up).
@property (nonatomic, copy) void (^onDismiss)(void);

@end
