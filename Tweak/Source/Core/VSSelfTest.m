//  VSSelfTest.m

#import "VSSelfTest.h"
#import "VSStore.h"
#import "VSPaths.h"
#import "VSIdentity.h"
#import "VSContainer.h"
#import "VSManager.h"
#import "VSLog.h"
#import "../Hooks/VSHookHome.h"
#import "../Hooks/VSHookKeychain.h"
#import "../Hooks/VSHookDefaults.h"
#import "../Hooks/VSHookCookies.h"
#import "../Hooks/VSHookWebKit.h"
#import "../Hooks/VSHookDevice.h"
#import "../Hooks/VSHookLocation.h"
#import "../Hooks/VSHookLocale.h"
#import "../Hooks/VSHookImage.h"
#import <UIKit/UIKit.h>
#import <math.h>

extern BOOL VSSafeModeActive;

static NSMutableString *gReport = nil;
static NSString *gLastReport = nil;
static NSInteger gPass = 0, gFail = 0;

/// Records one check. A FAIL is also logged at error level: the report file is
/// something someone has to think to open, whereas the log tail is what gets
/// read after a crash and what the remote sink forwards.
static void VSCheck(BOOL ok, NSString *name, NSString *detail) {
    NSString *why = detail.length ? detail : @"(no detail)";
    if (ok) {
        gPass++;
        [gReport appendFormat:@"PASS  %@\n", name];
    } else {
        gFail++;
        [gReport appendFormat:@"FAIL  %@ — %@\n", name, why];
        VSLogE(@"selftest", @"FAIL %@ — %@", name, why);
    }
}

/// Informational line: context that makes a FAIL diagnosable, never a verdict.
static void VSNote(NSString *line) {
    [gReport appendFormat:@"      %@\n", line ?: @""];
}

/// Scratch directory for the store tests, inside diag — i.e. outside every
/// container, so nothing here can be mistaken for container payload, and a
/// "Tout réinitialiser" leaves it alone. Wiped again at the end of the run.
static NSString *VSScratchDir(void) {
    NSString *d = [[VSPaths vesselRoot] stringByAppendingPathComponent:@"diag/selftest"];
    [NSFileManager.defaultManager createDirectoryAtPath:d
                           withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return d;
}

static NSString *VSReportPath(void) {
    return [[VSPaths vesselRoot] stringByAppendingPathComponent:@"diag/selftest.txt"];
}

#pragma mark - 1. Persistence

/// The "my account disappeared" bug reduced to its mechanism: write, reopen,
/// compare — then corrupt the primary file and prove the store comes back with
/// the backup generation instead of an empty dictionary. An empty dictionary is
/// what the user experiences as a lost login.
static void VSTestStore(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = VSScratchDir();
    NSString *p = [dir stringByAppendingPathComponent:@"roundtrip.plist"];
    for (NSString *ext in @[ @"", @"bak", @"tmp", @"corrupt" ]) {
        [fm removeItemAtPath:(ext.length ? [p stringByAppendingPathExtension:ext] : p) error:NULL];
    }

    NSDate *when = [NSDate dateWithTimeIntervalSince1970:1750000000];
    NSArray *nested = @[ @"x", @{ @"k": @YES } ];

    VSStore *a = [[VSStore alloc] initWithPath:p label:@"st-write"];
    [a setObject:@"héllo" forKey:@"str"];       // non-ASCII: plist encoding check
    [a setObject:@(42) forKey:@"num"];
    [a setObject:when forKey:@"date"];
    [a setObject:nested forKey:@"nested"];
    VSCheck([a flushNow], @"store/flush", @"flushNow returned NO");

    VSStore *b = [[VSStore alloc] initWithPath:p label:@"st-read"];
    NSDate *d = [b objectForKey:@"date"];
    BOOL ok = [[b objectForKey:@"str"] isEqual:@"héllo"]
           && [[b objectForKey:@"num"] isEqual:@(42)]
           && [d isKindOfClass:NSDate.class] && fabs([d timeIntervalSinceDate:when]) < 1.0
           && [[b objectForKey:@"nested"] isEqual:nested];
    VSCheck(ok, @"store/round-trip",
            [NSString stringWithFormat:@"reopened with %lu key(s): %@",
             (unsigned long)b.count, b.allValues]);

    // Second write: the previous primary becomes .bak, which is the generation
    // the recovery path is supposed to find.
    [a setObject:@"v2" forKey:@"str"];
    [a flushNow];
    VSCheck([fm fileExistsAtPath:[p stringByAppendingPathExtension:@"bak"]],
            @"store/backup-exists", @"no .bak after a second write");

    NSData *garbage = [@"this is not a plist" dataUsingEncoding:NSUTF8StringEncoding];
    [garbage writeToFile:p options:NSDataWritingAtomic error:NULL];
    VSStore *c = [[VSStore alloc] initWithPath:p label:@"st-recover"];
    VSCheck(c.count >= 4, @"store/recovery",
            [NSString stringWithFormat:@"corrupt primary left %lu key(s)", (unsigned long)c.count]);
    VSCheck([[c objectForKey:@"str"] isEqual:@"héllo"], @"store/recovery-content",
            [NSString stringWithFormat:@"str=%@ (expected the pre-corruption value)",
             [c objectForKey:@"str"]]);

    [c destroy];
    [fm removeItemAtPath:dir error:NULL];
}

#pragma mark - 2. Identity

/// The Darwin major/minor rule, restated independently of VSIdentity's own
/// implementation. A test that called the same helper would only prove the
/// helper agrees with itself.
static NSString *VSExpectedKernel(NSString *osVersion) {
    NSArray<NSString *> *parts = [(osVersion ?: @"") componentsSeparatedByString:@"."];
    int major = parts.count > 0 ? parts[0].intValue : 0;
    int minor = parts.count > 1 ? parts[1].intValue : 0;
    return [NSString stringWithFormat:@"%d.%d.0", major >= 26 ? major - 1 : major + 6, minor];
}

static void VSTestIdentity(void) {
    CGFloat realScale = 0;
    CGSize realPx = [VSIdentity realNativePixelSize:&realScale];
    VSNote([NSString stringWithFormat:@"real hw: %@ / %@ · iOS %@ (%@) · %.2f GB · %d cores",
            [VSIdentity realMachine], [VSIdentity realBoardID], [VSIdentity realOSVersion],
            [VSIdentity realOSBuild], [VSIdentity realMemSize] / 1073741824.0,
            [VSIdentity realCPUCount]]);

    // If the real machine is missing from the model table, generation cannot pick
    // a screen-consistent model and every container falls back to the real one.
    // That is a table gap I have to close, so it must surface as a FAIL naming
    // the identifier rather than a silent downgrade.
    VSCheck(realPx.width > 0 && realScale > 0, @"identity/real-model-known",
            [NSString stringWithFormat:@"%@ (%@) is not in the model table — model left "
             @"unspoofed; add its row", [VSIdentity realMachine], [VSIdentity realBoardID]]);

    NSMutableSet *taken = [NSMutableSet set];
    BOOL collisionFree = YES, geometryOK = YES, roundTripOK = YES, kernelOK = YES;
    NSString *firstBad = nil;

    for (int i = 0; i < 4; i++) {
        VSIdentity *x = [VSIdentity generateForRealDeviceWithLocale:@"fr_FR"
                                                          timeZone:@"Europe/Paris"
                                                             taken:taken];
        if (!x) { VSCheck(NO, @"identity/generate", @"generator returned nil"); return; }

        if ([x.uniqueValues intersectsSet:taken]) {
            collisionFree = NO;
            if (!firstBad) firstBad = [NSString stringWithFormat:@"identity %d reuses a value", i];
        }
        [taken unionSet:x.uniqueValues];

        if (realPx.width > 0) {
            CGFloat s = 0;
            CGSize px = [VSIdentity nativePixelSizeForMachine:x.machine scale:&s];
            if (!CGSizeEqualToSize(px, realPx) || (int)s != (int)realScale) {
                geometryOK = NO;
                if (!firstBad) firstBad = [NSString stringWithFormat:
                    @"%@ claims %.0fx%.0f@%.0fx but the real panel is %.0fx%.0f@%.0fx",
                    x.machine, px.width, px.height, s, realPx.width, realPx.height, realScale];
            }
        }

        VSIdentity *back = [VSIdentity identityWithDictionary:x.dictionaryRepresentation];
        if (!back || ![back.dictionaryRepresentation isEqualToDictionary:x.dictionaryRepresentation]) {
            roundTripOK = NO;
            if (!firstBad) firstBad = back ? @"a field changed through the plist form"
                                           : @"identityWithDictionary: rejected its own output";
        }
        if (![x.darwinKernel isEqualToString:VSExpectedKernel(x.osVersion)]) {
            kernelOK = NO;
            if (!firstBad) firstBad = [NSString stringWithFormat:@"kern.osrelease %@ for iOS %@",
                                       x.darwinKernel, x.osVersion];
        }
    }

    VSCheck(collisionFree, @"identity/collision-free", firstBad);
    VSCheck(geometryOK,    @"identity/screen-consistent", firstBad);
    VSCheck(roundTripOK,   @"identity/plist-round-trip", firstBad);
    VSCheck(kernelOK,      @"identity/darwin-kernel", firstBad);
}

#pragma mark - 3. Containers

static void VSTestContainers(void) {
    VSManager *m = VSManager.shared;
    NSArray<VSContainer *> *cs = m.containers;
    VSContainer *active = m.active;

    VSCheck(cs.count > 0, @"containers/non-empty", @"list empty after bootstrap");
    VSCheck(active != nil, @"containers/active-resolved", @"no active container");

    BOOL hasDefault = NO;
    for (VSContainer *c in cs) if (c.isDefault) { hasDefault = YES; break; }
    VSCheck(hasDefault, @"containers/default-exists",
            @"no default container — a deleted-everything state would leave no working storage");

    NSMutableSet *cids = [NSMutableSet set], *vals = [NSMutableSet set];
    BOOL uniqueIDs = YES, uniqueVals = YES, allIdentified = YES;
    NSString *bad = nil;
    for (VSContainer *c in cs) {
        if (c.cid.length == 0 || [cids containsObject:c.cid]) {
            uniqueIDs = NO; if (!bad) bad = [NSString stringWithFormat:@"duplicate cid %@", c.cid];
        }
        [cids addObject:c.cid ?: @""];
        if (!c.identity) {
            allIdentified = NO; if (!bad) bad = [NSString stringWithFormat:@"%@ has no identity", c.cid];
            continue;
        }
        if ([c.identity.uniqueValues intersectsSet:vals]) {
            uniqueVals = NO;
            if (!bad) bad = [NSString stringWithFormat:@"%@ shares an identifier with another container", c.cid];
        }
        [vals unionSet:c.identity.uniqueValues];
    }
    VSCheck(uniqueIDs,     @"containers/unique-ids", bad);
    VSCheck(allIdentified, @"containers/all-have-identity", bad);
    VSCheck(uniqueVals,    @"containers/disjoint-identifiers", bad);

    // On disk, not merely in memory: the tree the HOME hook is about to redirect
    // into has to exist, and the choice has to survive a kill.
    VSCheck(active.rootPath.length > 0 &&
            [NSFileManager.defaultManager fileExistsAtPath:active.rootPath],
            @"containers/active-tree-exists", active.rootPath);

    // The literal key is deliberate: "activeContainer" is part of the on-disk
    // contract, and renaming it in VSManager without a migration must fail here.
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:[VSPaths statePath]];
    VSCheck([st[@"activeContainer"] isEqual:active.cid], @"containers/active-persisted",
            [NSString stringWithFormat:@"state.plist says %@, memory says %@",
             st[@"activeContainer"], active.cid]);

    VSNote([NSString stringWithFormat:@"active: %@ (%@) · %@",
            active.name, active.cid, active.identity.shortDescription]);
}

#pragma mark - 4. Isolation layers

/// Layers 1 (filesystem) and 2 (keychain) verify themselves through their own
/// +firstLeak, which do physical write-then-read-back probes rather than trusting
/// our own bookkeeping: layer 1 writes through the redirected Documents path and
/// looks for the bytes at the container path computed independently; layer 2
/// stores a keychain item through the public API and proves securityd holds it
/// only under the namespaced service. Layers 3 (defaults) and 4 (cookies) do the
/// same: each writes through the public API and proves the value physically landed
/// in this container's private store on disk, not in the process-wide plist or
/// cookie jar. Layer 5 (identity) reads the spoofed sources — sysctl/uname/UIDevice
/// /ASIdentifierManager, and NSTimeZone/NSLocale — back through the public API and
/// proves they describe the container, not the real phone. Layer 6 (fake GPS) reads
/// CoreLocation back — services enabled, authorization, and a fix near the container's
/// base point — or is a silent pass when the container pins no location. In safe mode
/// the hooks are deliberately absent, so "not installed" is the expected state and is
/// a note, not a failure.
static void VSTestIsolation(void) {
    if (VSSafeModeActive) {
        VSNote(@"isolation: hooks disabled (safe mode) — layer 1-6 checks skipped");
        return;
    }
    NSString *l1 = [VSHookHome firstLeak];
    VSCheck(l1 == nil, @"isolation/layer1-filesystem", l1);

    NSString *l2 = [VSHookKeychain firstLeak];
    VSCheck(l2 == nil, @"isolation/layer2-keychain", l2);

    NSString *l3 = [VSHookDefaults firstLeak];
    VSCheck(l3 == nil, @"isolation/layer3-defaults", l3);

    NSString *l4 = [VSHookCookies firstLeak];
    VSCheck(l4 == nil, @"isolation/layer4-cookies", l4);

    // Layer 4b is allowed to be absent: on a pre-iOS 17 OS (or if WebKit is missing)
    // it installs nothing by design and the app stays on the shared web store — a
    // documented, non-regressing fallback, so treat "not installed" as a note, not a
    // failure. When it IS installed we hold it to the same zero-leak bar as the rest.
    if ([VSHookWebKit isInstalled]) {
        NSString *l4b = [VSHookWebKit firstLeak];
        VSCheck(l4b == nil, @"isolation/layer4b-webkit", l4b);
    } else {
        VSNote(@"isolation/layer4b-webkit: not installed (shared web store) — non-fatal");
    }

    NSString *l5 = [VSHookDevice firstLeak];
    VSCheck(l5 == nil, @"identity/device-hook", l5);

    NSString *l6 = [VSHookLocale firstLeak];
    VSCheck(l6 == nil, @"identity/locale-hook", l6);

    NSString *l7 = [VSHookLocation firstLeak];
    VSCheck(l7 == nil, @"identity/location-hook", l7);

    // Image cloak is anti-detection, not isolation, and is not gated on HOME; if it
    // could not install (dladdr/dlsym/rebind miss) the image list is simply genuine,
    // which regresses nothing — a note, not a failure. When active it must actually
    // hide our image.
    if ([VSHookImage isInstalled]) {
        NSString *l8 = [VSHookImage firstLeak];
        VSCheck(l8 == nil, @"anti-detect/image-cloak", l8);
    } else {
        VSNote(@"anti-detect/image-cloak: not active — non-fatal");
    }
}

#pragma mark - Report

static NSString *VSHeader(void) {
    return [NSString stringWithFormat:
            @"Vessel self-test — %@\n%ld passed, %ld failed · boot #%ld · safeMode=%@\n",
            [NSDate date], (long)gPass, (long)gFail,
            (long)VSManager.shared.bootCount, VSSafeModeActive ? @"YES" : @"NO"];
}

static void VSPublish(void) {
    gLastReport = [NSString stringWithFormat:@"%@\n%@", VSHeader(), gReport ?: @""];
    [gLastReport writeToFile:VSReportPath() atomically:YES
                   encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - 4. Screen (deferred)

/// UIScreen is not dependable from a dylib constructor, so this single check runs
/// a couple of seconds into the launch and appends to the report. It validates the
/// model table against the physical panel: if the table's row for the real machine
/// disagrees with what UIScreen reports, then every container built from that row
/// carries a model/resolution mismatch — the cheapest inconsistency there is for a
/// server to test. Runs on the main queue; the synchronous checks ran on the same
/// thread at load time, so the counters are never touched concurrently.
static void VSTestScreenLate(void) {
    UIScreen *scr = UIScreen.mainScreen;
    if (!scr) { VSCheck(NO, @"screen/available", @"UIScreen.mainScreen is nil"); return; }

    CGSize px = scr.nativeBounds.size;          // physical pixels, portrait-up
    CGFloat nsc = scr.nativeScale;
    CGFloat tableScale = 0;
    CGSize table = [VSIdentity nativePixelSizeForMachine:[VSIdentity realMachine]
                                                   scale:&tableScale];
    VSNote([NSString stringWithFormat:@"UIScreen %.0fx%.0f @%.2fx · table %.0fx%.0f @%.0fx",
            px.width, px.height, nsc, table.width, table.height, tableScale]);

    if (table.width > 0) {
        BOOL match = lround(MIN(px.width, px.height)) == lround(MIN(table.width, table.height))
                  && lround(MAX(px.width, px.height)) == lround(MAX(table.width, table.height));
        VSCheck(match, @"screen/table-matches-panel",
                @"the model table row for the real machine disagrees with the panel");
    }

    VSIdentity *idn = VSManager.shared.active.identity;
    if (idn) {
        VSNote([NSString stringWithFormat:@"UA Instagram would build: %@",
                [idn expectedUserAgentWithAppVersion:nil pixelSize:px scale:nsc]]);
    }
}

#pragma mark - Entry point

@implementation VSSelfTest

+ (void)runAtBoot {
    gReport = [NSMutableString string];
    gPass = gFail = 0;

    NSTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    @try {
        VSTestStore();
        VSTestIdentity();
        VSTestContainers();
        VSTestIsolation();
    } @catch (NSException *e) {
        // A self-test that could crash Instagram would be worse than no
        // self-test, so its own failure is just another FAIL line.
        VSCheck(NO, @"selftest/itself",
                [NSString stringWithFormat:@"%@: %@", e.name, e.reason]);
    }
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    VSNote([NSString stringWithFormat:@"%.1f ms", ms]);
    VSPublish();

    if (gFail == 0) {
        VSLogI(@"selftest", @"%ld passed, 0 failed (%.1f ms)", (long)gPass, ms);
    } else {
        VSLogE(@"selftest", @"%ld passed, %ld FAILED (%.1f ms) — see diag/selftest.txt",
               (long)gPass, (long)gFail, ms);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { VSTestScreenLate(); } @catch (NSException *e) {
            VSCheck(NO, @"screen/itself", [NSString stringWithFormat:@"%@: %@", e.name, e.reason]);
        }
        VSPublish();
        VSLogI(@"selftest", @"screen check done — %ld passed, %ld failed total",
               (long)gPass, (long)gFail);
    });
}

+ (NSString *)lastReport {
    if (gLastReport.length) return gLastReport;
    NSString *onDisk = [NSString stringWithContentsOfFile:VSReportPath()
                                                encoding:NSUTF8StringEncoding error:NULL];
    return onDisk.length ? onDisk : @"(self-test has not run yet)";
}

@end
