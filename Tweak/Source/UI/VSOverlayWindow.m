//  VSOverlayWindow.m

#import "VSOverlayWindow.h"
#import "VSTheme.h"

@implementation VSOverlayWindow

// Never key: if the overlay stole key status, the first tap in a text field would
// resign Instagram's first responder and the keyboard would collapse. This single
// override is the whole fix for "the keyboard stopped working".
- (BOOL)canBecomeKeyWindow { return NO; }

// Strict passthrough. super's hit-test walks our subviews (the button and its
// contents); if it comes back as the window itself or the bare root view, the
// point missed the button and belongs to Instagram — return nil so UIKit keeps
// looking in the window below us. Anything else is a real hit on the button.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

@end
