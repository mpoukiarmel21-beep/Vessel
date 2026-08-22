//  VSUIController.m

#import "VSUIController.h"
#import "VSOverlayWindow.h"
#import "VSFloatingButton.h"
#import "VSPanelVC.h"
#import "VSQuickSwitchVC.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSLog.h"
#import <stdlib.h>

@interface VSUIController ()
@property (nonatomic, strong) VSOverlayWindow *window;
@property (nonatomic, strong) VSFloatingButton *button;
- (void)presentQuickSwitch;   // defined below; declared so the attach block can see it
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
        // A scene tearing down (app backgrounded to the switcher, then killed, or
        // iPad multiwindow) leaves our window pointing at a dead scene. Drop it so
        // the next activation rebuilds cleanly instead of latching onto a corpse.
        [NSNotificationCenter.defaultCenter addObserver:c
            selector:@selector(sceneDidDisconnect:)
                name:UISceneDidDisconnectNotification object:nil];
        [c ensureAttachedWithRetries:12];   // scene may already be active; self-heals a missed activation
    });
}

- (void)sceneBecameActive:(NSNotification *)n { [self attachIfPossible]; }

// Belt-and-braces for the cold-boot race. On a heavy boot — notably the first
// launch right after "Tout réinitialiser" — scheduleAttach's main-queue block can
// run just AFTER the scene already posted its activation notification, so a single
// attachIfPossible finds no ForegroundActive scene yet and the button never
// appears until the user backgrounds and re-foregrounds. Retry a bounded number of
// times (≈6 s) until the overlay is healthy on a live scene, then stop. The scene
// observers remain the long-term safety net; this only covers the first seconds.
- (void)ensureAttachedWithRetries:(NSInteger)tries {
    [self attachIfPossible];
    UIWindowScene *ws = [VSUIController activeScene];
    if (ws && [self overlayHealthyOnScene:ws]) return;   // attached — done
    if (tries <= 0) return;                               // give up; an activation notif can still fire later
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self ensureAttachedWithRetries:tries - 1]; });
}

- (void)sceneDidDisconnect:(NSNotification *)n {
    if ([n.object isKindOfClass:UIWindowScene.class] &&
        self.window.windowScene == (UIWindowScene *)n.object) {
        VSLogI(@"ui", @"overlay scene disconnected — dropping window");
        [self teardownOverlay];
    }
}

// Only a genuinely foreground-active scene. The old code fell back to any
// connected scene, so on a cold relaunch it could bind the overlay to a scene
// that never came to the front — the window then lived on a scene the user never
// saw, which is why the button "disappeared" after a force-quit and reopen.
+ (UIWindowScene *)activeScene {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    return nil;
}

// The overlay is healthy only if every piece is still wired to the live scene.
// Any NO here means a stale or half-torn-down overlay that must be rebuilt.
- (BOOL)overlayHealthyOnScene:(UIWindowScene *)ws {
    return self.window != nil
        && self.button != nil
        && self.window.windowScene == ws
        && !self.window.hidden
        && self.button.superview != nil;
}

- (void)teardownOverlay {
    [NSNotificationCenter.defaultCenter removeObserver:self.button
        name:VSContainersDidChangeNotification object:nil];
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.button = nil;
}

- (void)attachIfPossible {
    UIWindowScene *ws = [VSUIController activeScene];
    if (!ws) return;                              // no live scene yet — retry on the next notification
    if ([self overlayHealthyOnScene:ws]) {        // already good on this scene
        self.window.frame = ws.coordinateSpace.bounds;   // re-assert after a rotation/resize
        return;
    }
    [self teardownOverlay];                       // rebuild from a clean slate

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
    btn.onLongPress = ^{ [weakSelf presentQuickSwitch]; };
    [root.view addSubview:btn];

    self.window = w;
    self.button = btn;

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
    // Force the whole stack dark so pushed VCs (create, diagnostics, map) match the
    // frosted-dark pane instead of flipping with Instagram's appearance.
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
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

// Long-press shortcut: a compact medium-detent carousel of containers. With a
// single container there is nothing to switch between, so fall through to the full
// panel (where the user can create a second one). Presented WITHOUT a nav
// controller — it is a one-screen sheet, not a stack.
- (void)presentQuickSwitch {
    UIViewController *top = [VSUIController topViewController];
    if (!top) { VSLogW(@"ui", @"no top VC — cannot present quick switch"); return; }
    if (top.presentedViewController) return;   // don't stack over an open sheet
    if (VSManager.shared.containers.count <= 1) { [self presentPanel]; return; }

    VSQuickSwitchVC *qs = [VSQuickSwitchVC new];
    qs.modalPresentationStyle = UIModalPresentationPageSheet;
    qs.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UISheetPresentationController *sheet = qs.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
    sheet.prefersGrabberVisible = YES;
    sheet.preferredCornerRadius = [VSTheme panelCornerRadius];

    self.button.hidden = YES;
    __weak VSUIController *weakSelf = self;
    qs.onDismiss = ^{ weakSelf.button.hidden = NO; [weakSelf.button refresh]; };

    [top presentViewController:qs animated:YES completion:nil];
}

#pragma mark - Relaunch

// A sideloaded app cannot relaunch itself: there is no entitlement to spawn a new
// instance, and the old code's bare exit(0) just made Instagram vanish with no
// explanation — which read as "the switch/reset did nothing". Be honest instead:
// explain that Instagram must be closed and reopened by hand. The pending choice
// is already flushed, so it applies on the next launch whether the user closes
// now or later.
+ (void)relaunchToApplyContainerSwitch {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {                       // no UI to explain with — just terminate
            VSLogI(@"ui", @"no top VC; terminating directly to apply change");
            exit(0);
        }
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Redémarrage requis"
            message:@"Le changement s'appliquera au prochain lancement.\n\n"
                    @"Fermez complètement Instagram (glissez-la hors du sélecteur "
                    @"d'apps), puis rouvrez-la."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Fermer maintenant"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                VSLogI(@"ui", @"user chose to close now — terminating");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ exit(0); });
            }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Plus tard"
            style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

@end
