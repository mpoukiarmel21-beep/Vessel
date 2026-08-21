//  VSPanelVC.h — the main panel (ARCHITECTURE §6).
//
//  Presented as a page-sheet from Instagram's top view controller by
//  VSUIController. Root of its own navigation controller, so it can push the
//  create assistant and the diagnostics screen. It never re-points a running
//  Instagram: switching container records the choice and relaunches (rule 5),
//  which is the whole reason "my account disappeared" cannot happen here.

#import <UIKit/UIKit.h>

@interface VSPanelVC : UIViewController

/// Fired when the panel's sheet is actually dismissed — NOT when it merely pushes
/// a child screen. VSUIController uses it to bring the floating button back.
@property (nonatomic, copy) void (^onDismiss)(void);

@end
