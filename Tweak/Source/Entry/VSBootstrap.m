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

/// Set when the crash streak trips the breaker. Modules must consult this and
/// no-op rather than install anything.
BOOL VSSafeModeActive = NO;

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
