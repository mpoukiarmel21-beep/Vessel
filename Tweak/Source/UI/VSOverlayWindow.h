//  VSOverlayWindow.h — the passthrough window that hosts the floating button.
//
//  Three of the classic "the tweak froze Instagram" bugs are prevented right
//  here (ARCHITECTURE §5): the window never becomes key (so the keyboard keeps
//  working), and its hit-testing is strict passthrough (so only touches that
//  actually land on the button are consumed — every other touch falls through to
//  Instagram). The panel and wizards are NOT hosted here; they are presented on
//  Instagram's own top view controller, which is the fourth fix.

#import <UIKit/UIKit.h>

@interface VSOverlayWindow : UIWindow
@end
