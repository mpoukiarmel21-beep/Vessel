//  VSBootstrap.m — the single entry point.
//
//  There is exactly ONE constructor in this dylib, on purpose. The previous
//  project used one __attribute__((constructor)) per file, which leaves the
//  execution order up to link order — so path redirection could (and did) run
//  after modules that already depended on it. Here every step is explicit and
//  ordered, and every step drops a breadcrumb so a boot crash is traceable to
//  the exact module that caused it.
//
//  Ordering contract:
//    1. capture the real home            (nothing may redirect before this)
//    2. bring up logging + crash capture (so later failures are recorded)
//    3. safe-mode decision               (2 crashed boots in a row => hooks off)
//    4. snapshot the REAL hardware       (before any sysctl rebinding exists)
//    5. load containers, resolve the active one
//    6. install hooks, cheapest/safest first
//    7. self-test                        (re-proves 1-6 actually held, on device)
//    8. schedule UI once UIApplication exists

#import <UIKit/UIKit.h>
#import "Core/VSLog.h"
#import "Core/VSPaths.h"
#import "Core/VSIdentity.h"
#import "Core/VSManager.h"
#import "Core/VSSelfTest.h"
#import "Hooks/VSHookHome.h"
#import "Hooks/VSHookKeychain.h"
#import "Hooks/VSHookDefaults.h"
#import "Hooks/VSHookCookies.h"
#import "Hooks/VSHookWebKit.h"
#import "Hooks/VSHookDevice.h"
#import "Hooks/VSHookLocation.h"
#import "Hooks/VSHookLocale.h"
#import "Hooks/VSHookImage.h"
#import "UI/VSUIController.h"

/// Set when the crash streak trips the breaker. Modules must consult this and
/// no-op rather than install anything.
BOOL VSSafeModeActive = NO;

// --- Phase-8 hardening hooks, temporarily disabled ---------------------------
// These two were the leading suspects for the signup hang seen on build-17, and
// neither is required for the core "one account per container" isolation:
//   * WebKit isolation (layer 4b): swizzles +defaultDataStore and builds a
//     per-container WKWebsiteDataStore via +dataStoreForIdentifier: — Apple code
//     whose internal threading we don't control, and the signup flow may run
//     through a web view. Disabled -> a log-only probe runs instead (below).
//   * Image cloak (layer 7): hides our dylib from the loaded-image list, but only
//     rebinds _dyld_image_count/name (not _header/_slide), so a paired name<->header
//     image walk sees a mismatch: a detection tell AND a crash risk exactly when
//     anti-automation is harshest (account creation).
// Core isolation (FS / keychain / defaults / cookies / device / locale) is
// unaffected and stays ON. Flip either constant to YES to re-enable after an
// on-device test proves the flow it guards is stable.
static const BOOL kEnableWebKitIsolation = NO;
static const BOOL kEnableImageCloak      = NO;

static void VSBootstrapMain(void) {
    // --- 1. real home, before anything can redirect it -------------------
    [VSPaths snapshotRealHome];

    // --- 2. logging + crash capture -------------------------------------
    VSLog *log = VSLog.shared;
    [log bootstrapWithRealDataRoot:[VSPaths vesselRoot]];
    [log installCrashHandlers];
    [log breadcrumb:VSBootStepConstructor note:@"constructor entered"];
    [log drainPreviousCrashReport];
    [log breadcrumb:VSBootStepPathsResolved
               note:[NSString stringWithFormat:@"realHome=%@", [VSPaths realHome]]];

    // --- 3. safe mode ----------------------------------------------------
    NSInteger streak = [log crashStreak];
    [log markBootStarted];
    if (streak >= 2) {
        VSSafeModeActive = YES;
        VSLogE(@"boot", @"SAFE MODE: %ld consecutive crashed boots — all hooks disabled. "
                        @"Instagram runs unmodified; logs are still collected.", (long)streak);
    }

    // A boot that survives 8 s of runtime is considered healthy. Long enough to
    // cover launch, UI setup and Instagram's own start-up work.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [log markBootSucceeded]; });

    // --- 4. genuine hardware facts --------------------------------------
    // Must happen before VSHookDevice rebinds sysctlbyname for the whole image:
    // afterwards even our own reads return the active container's spoofed values,
    // and a container created later would inherit the previous one's identity.
    [VSIdentity snapshotRealHardware];

    // --- 5. containers ---------------------------------------------------
    // Runs even in safe mode: it installs nothing, and the diagnostics UI needs a
    // container list. What safe mode suppresses is step 6.
    [VSManager.shared bootstrapBeforeHooks];
    VSContainer *active = VSManager.shared.active;
    [log breadcrumb:VSBootStepStoreLoaded
               note:[NSString stringWithFormat:@"boot #%ld, active=%@ (%@), %lu container(s)",
                     (long)VSManager.shared.bootCount, active.name, active.cid,
                     (unsigned long)VSManager.shared.containers.count]];
    VSLogI(@"boot", @"identity: %@", active.identity.shortDescription);

    // --- 6. isolation hooks, cheapest/safest first -----------------------
    // Skipped entirely in safe mode: two crashed boots in a row means we let
    // Instagram run unmodified until the user recovers, rather than risk a third.
    // All-or-nothing: if HOME (layer 1) refuses, the keychain is left shared too,
    // so the app runs fully unmodified on its real state instead of half-isolated
    // (split keychain over a shared filesystem is a state nobody has tested).
    if (!VSSafeModeActive) {
        BOOL home = [VSHookHome installForContainerRoot:active.rootPath];
        [log breadcrumb:VSBootStepHomeHooked
                   note:(home ? [NSString stringWithFormat:@"HOME -> %@", active.rootPath]
                              : @"HOME install refused — running unmodified")];
        if (!home) VSLogE(@"boot", @"layer 1 (HOME) did not install — containers are NOT isolated");

        BOOL keys = home ? [VSHookKeychain installForContainerID:active.cid] : NO;
        [log breadcrumb:VSBootStepKeychainHooked
                   note:(keys ? [NSString stringWithFormat:@"keychain ns=%@",
                                 [VSHookKeychain namespacePrefix]]
                              : (home ? @"keychain install refused" : @"skipped (HOME refused)"))];
        if (home && !keys)
            VSLogE(@"boot", @"layer 2 (keychain) did not install — sessions may leak between containers");

        // Layer 3: cfprefsd is out-of-process, so HOME redirect isolates none of
        // Instagram's per-account preferences (saved logins, current-user hint).
        BOOL defs = home ? [VSHookDefaults installForContainerID:active.cid] : NO;
        [log breadcrumb:VSBootStepDefaultsHooked
                   note:(defs ? @"defaults isolated"
                              : (home ? @"defaults install refused" : @"skipped (HOME refused)"))];
        if (home && !defs)
            VSLogE(@"boot", @"layer 3 (defaults) did not install — per-account prefs may leak between containers");

        // Layer 4: the shared cookie jar is likewise process-wide; without this a
        // web-view sessionid written by one container is visible to the next.
        BOOL cook = home ? [VSHookCookies installForContainerID:active.cid] : NO;
        [log breadcrumb:VSBootStepCookiesHooked
                   note:(cook ? @"cookies isolated"
                              : (home ? @"cookies install refused" : @"skipped (HOME refused)"))];
        if (home && !cook)
            VSLogE(@"boot", @"layer 4 (cookies) did not install — web sessions may leak between containers");

        // Layer 4b (WebKit): a WKWebView keeps its cookies and localStorage in an
        // out-of-process WKWebsiteDataStore the shared cookie jar above does not
        // cover. No breadcrumb — the VSBootStep enum is frozen (see VSLog.h) and the
        // "furthest breadcrumb = guilty module" invariant must hold, so this logs
        // instead. Gated on HOME with the rest of the isolation block. A NO here is
        // non-fatal (pre-iOS 17 or WebKit absent): the app stays on the shared store.
        // Layer 4b (WebKit): per-container web data store. Disabled by default
        // (see kEnableWebKitIsolation) — when off, a log-only probe records whether
        // the signup/login flow uses a web view, with zero lock/build hazard.
        if (home && kEnableWebKitIsolation) {
            BOOL web = [VSHookWebKit installForContainerID:active.cid];
            VSLogI(@"boot", @"layer 4b (WebKit): %@",
                   web ? @"isolated" : @"not isolated (shared default store)");
        } else {
            [VSHookWebKit installProbe];
            VSLogI(@"boot", @"layer 4b (WebKit): DISABLED (probe only) — reliability-first for signup");
        }

        // Layer 5 (identity): make the active container look like a different
        // iPhone. Gated on HOME like the isolation layers — if we are running
        // unmodified (no container isolation), there is no per-container identity
        // to project, and spoofing a lone real account's device would be pointless
        // and inconsistent. Order: device (fingerprint sources), then location
        // (GPS), then locale (clock/formatting) — the full identity block.
        BOOL dev = home ? [VSHookDevice installWithIdentity:active.identity] : NO;
        [log breadcrumb:VSBootStepDeviceHooked
                   note:(dev ? @"device identity spoofed"
                              : (home ? @"device install refused" : @"skipped (HOME refused)"))];
        if (home && !dev)
            VSLogE(@"boot", @"layer 5 (device) did not install — model/IDFV/serial are the real device's");

        // Layer 6 (fake GPS): drive CoreLocation to the container's chosen city.
        // Installs PASSIVE (touches nothing) when the container has no base
        // location, which is the default — so this is a no-op until the user
        // pins a location. Between device and locale so the whole identity block
        // (fingerprint → position → clock/formatting) lands together.
        BOOL gps = home ? [VSHookLocation installForContainer:active] : NO;
        [log breadcrumb:VSBootStepLocationHooked
                   note:(gps ? @"location ready"
                              : (home ? @"location install refused" : @"skipped (HOME refused)"))];
        if (home && !gps)
            VSLogE(@"boot", @"layer 6 (location) did not install — real GPS position is exposed");

        BOOL loc = home ? [VSHookLocale installWithIdentity:active.identity] : NO;
        [log breadcrumb:VSBootStepLocaleHooked
                   note:(loc ? @"locale/timezone aligned"
                              : (home ? @"locale install refused" : @"skipped (HOME refused)"))];

        // Layer 7 (image cloak): hide our own dylib from the loaded-image walk.
        // Installed LAST — after every fishhook rebind above — because it rebinds
        // _dyld_image_count/name, and doing that before another rebind would corrupt
        // fishhook's own image iteration (see VSHookImage.h). NOT gated on HOME: it
        // isolates no state, it only removes the "this process is modified" tell, so
        // it is worth doing even when we are otherwise running unmodified. No
        // breadcrumb (the VSBootStep enum is frozen); logs instead.
        if (kEnableImageCloak) {
            BOOL cloak = [VSHookImage install];
            VSLogI(@"boot", @"image cloak: %@", cloak ? @"active" : @"inactive (image list genuine)");
        } else {
            // Disabled by default (see kEnableImageCloak): the cloak rebinds
            // _dyld_image_count/name but not _header/_slide, so a paired
            // name<->header walk would see a mismatch — a detection tell and a
            // crash risk during signup. Consistency beats stealth until the full
            // quartet can be hooked safely.
            VSLogI(@"boot", @"image cloak: DISABLED — image list left genuine (consistency > stealth)");
        }
    } else {
        [log breadcrumb:VSBootStepHomeHooked note:@"skipped (safe mode)"];
    }

    // --- 7. self-test ----------------------------------------------------
    // Runs last so it can verify what the earlier steps installed; the hooks of
    // step 6 slot in immediately above this line as each phase lands. It reports
    // failures, it never raises them — this is the one place where a bug in the
    // verification code could take Instagram down, and it must not.
    [VSSelfTest runAtBoot];
    NSArray<NSString *> *lines = [VSSelfTest.lastReport componentsSeparatedByString:@"\n"];
    [log breadcrumb:VSBootStepSelfTestDone
               note:(lines.count > 1 ? lines[1] : @"self-test ran")];

    VSLogI(@"boot", @"Vessel ready (safeMode=%@)", VSSafeModeActive ? @"YES" : @"NO");

    // --- 8. UI -----------------------------------------------------------
    // Scheduled even in safe mode: the floating button is how the user reaches
    // Diagnostics and the container list to recover, so it must appear exactly
    // when hooks are off. scheduleAttach waits for a live UIWindowScene, then
    // adds the overlay window; it never blocks the constructor.
    [log breadcrumb:VSBootStepUIScheduled note:@"scheduling UI attach"];
    [VSUIController scheduleAttach];
}


__attribute__((constructor))
static void VSEntry(void) {
    @autoreleasepool {
        @try {
            VSBootstrapMain();
        } @catch (NSException *e) {
            // Never let our own init take Instagram down with us.
            NSLog(@"[Vessel] FATAL during bootstrap: %@: %@", e.name, e.reason);
        }
    }
}
