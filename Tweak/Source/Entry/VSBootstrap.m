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
//    4. load persistent state
//    5. install hooks, cheapest/safest first
//    6. schedule UI once UIApplication exists

#import <UIKit/UIKit.h>
#import "Core/VSLog.h"
#import "Core/VSPaths.h"
#import "Core/VSStore.h"

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

    // --- 4. persistent state --------------------------------------------
    // (VSManager arrives in phase 2; for now prove the store round-trips.)
    VSStore *state = [[VSStore alloc] initWithPath:[VSPaths statePath] label:@"state"];
    [state attachLifecycleFlush];
    NSInteger boots = [[state objectForKey:@"bootCount"] integerValue] + 1;
    [state setObject:@(boots) forKey:@"bootCount"];
    [state setObject:@"1" forKey:@"schema"];
    [state flushNow];
    [log breadcrumb:VSBootStepStoreLoaded
               note:[NSString stringWithFormat:@"state ok, boot #%ld", (long)boots]];

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
