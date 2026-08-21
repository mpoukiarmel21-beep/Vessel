//  VSUIController.m

#import "VSUIController.h"
#import "VSOverlayWindow.h"
#import "VSFloatingButton.h"
#import "VSPanelVC.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSLog.h"
#import <stdlib.h>

@interface VSUIController ()
@property (nonatomic, strong) VSOverlayWindow *window;
@property (nonatomic, strong) VSFloatingButton *button;
@property (nonatomic, assign) BOOL attached;
@end

@implementation VSUIController

+ (instancetype)shared {
    static VSUIController *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [VSUIController new]; });
    return s;
}

#pragma mark - Attach lifecycle

+ (void)scheduleAttach {
    dispatch_async(dispatch_get_main_queue(), ^{
        VSUIController *c = VSUIController.shared;
        [NSNotificationCenter.defaultCenter addObserver:c
            selector:@selector(sceneBecameActive:)
                name:UISceneDidActivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:c
            selector:@selector(sceneBecameActive:)
                name:UIApplicationDidBecomeActiveNotification object:nil];
        [c attachIfPossible];   // in case a scene is already active
    });
}

- (void)sceneBecameActive:(NSNotification *)n { [self attachIfPossible]; }

+ (UIWindowScene *)activeScene {
    UIWindowScene *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)attachIfPossible {
    if (self.attached) return;
    UIWindowScene *ws = [VSUIController activeScene];
    if (!ws) return;    // no live scene yet — a later notification will retry

    VSOverlayWindow *w = [[VSOverlayWindow alloc] initWithWindowScene:ws];
    w.frame = ws.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelStatusBar + 100;   // above IG content, below system alerts
    w.backgroundColor = UIColor.clearColor;

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;
    w.hidden = NO;                                   // NOT makeKeyAndVisible

    VSFloatingButton *btn = [VSFloatingButton new];
    __weak VSUIController *weakSelf = self;
    btn.onTap = ^{ [weakSelf presentPanel]; };
    [root.view addSubview:btn];

    self.window = w;
    self.button = btn;
    self.attached = YES;

    [NSNotificationCenter.defaultCenter addObserver:btn selector:@selector(refresh)
        name:VSContainersDidChangeNotification object:nil];
    [[VSLog shared] breadcrumb:VSBootStepUIAttached note:@"floating button attached"];
    VSLogI(@"ui", @"overlay attached to scene");
}

#pragma mark - Reaching Instagram's VC stack

+ (UIViewController *)topFrom:(UIViewController *)vc {
    if (vc.presentedViewController) return [self topFrom:vc.presentedViewController];
    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nc = (UINavigationController *)vc;
        UIViewController *vis = nc.visibleViewController;
        return (vis && vis != nc) ? [self topFrom:vis] : nc;
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        UITabBarController *tc = (UITabBarController *)vc;
        UIViewController *sel = tc.selectedViewController;
        return (sel && sel != tc) ? [self topFrom:sel] : tc;
    }
    return vc;
}

+ (UIViewController *)topViewController {
    UIWindowScene *ws = [self activeScene];
    UIWindow *key = ws.keyWindow;
    if (!key) {
        for (UIWindow *win in ws.windows)
            if (![win isKindOfClass:VSOverlayWindow.class] && !win.hidden) { key = win; break; }
    }
    return [self topFrom:key.rootViewController];
}

#pragma mark - Presentation

- (void)presentPanel {
    UIViewController *top = [VSUIController topViewController];
    if (!top) { VSLogW(@"ui", @"no top VC — cannot present panel"); return; }
    if (top.presentedViewController) return;   // don't stack over an open sheet

    VSPanelVC *panel = [VSPanelVC new];
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    sheet.preferredCornerRadius = [VSTheme panelCornerRadius];

    // The button sits above IG content; hide it so it does not float over the
    // sheet, and bring it back when the sheet is gone.
    self.button.hidden = YES;
    __weak VSUIController *weakSelf = self;
    panel.onDismiss = ^{ weakSelf.button.hidden = NO; [weakSelf.button refresh]; };

    [top presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Relaunch

+ (void)relaunchToApplyContainerSwitch {
    VSLogI(@"ui", @"terminating to apply container switch");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

@end
