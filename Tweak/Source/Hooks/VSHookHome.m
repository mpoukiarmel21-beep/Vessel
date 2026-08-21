//  VSHookHome.m

#import "VSHookHome.h"
#import "../Core/VSPaths.h"
#import "../Core/VSLog.h"
#import "../vendor/fishhook/fishhook.h"
#import <objc/runtime.h>
#import <stdlib.h>
#import <dlfcn.h>

static NSString *gRoot = nil;      // container root, standardised
static NSString *gReal = nil;      // real home, standardised
static NSString *gVessel = nil;    // <real home>/Library/Application Support/Vessel
static NSString *gRootC = nil, *gRealC = nil, *gVesselC = nil;   // canonical forms
static BOOL gInstalled = NO;

static NSString *(*orig_NSHomeDirectory)(void) = NULL;
static NSString *(*orig_NSTemporaryDirectory)(void) = NULL;
static NSArray<NSString *> *(*orig_NSSearchPath)(NSSearchPathDirectory,
                                                 NSSearchPathDomainMask, BOOL) = NULL;

#pragma mark - Mapping

/// /var is a symlink to /private/var, and Foundation entry points disagree about
/// which of the two they hand back — NSHomeDirectory() says /var/mobile/...,
/// while a URL that has been through -URLByResolvingSymlinksInPath says
/// /private/var/mobile/... Comparing prefixes without collapsing the two would
/// silently stop mapping half the paths, and a path that is not mapped is a path
/// Instagram writes outside its container.
static NSString *VSCanon(NSString *p) {
    if ([p hasPrefix:@"/private/var/"]) return [p substringFromIndex:8];
    if ([p isEqualToString:@"/private/var"]) return @"/var";
    return p;
}

static BOOL VSHasDirPrefix(NSString *p, NSString *dir) {
    return dir.length > 0 && ([p isEqualToString:dir] ||
                              [p hasPrefix:[dir stringByAppendingString:@"/"]]);
}

/// The one rule the whole layer rests on. Order matters: the container check and
/// the Vessel-storage check both come before the rewrite, so mapping is
/// idempotent and can never nest a container inside another one or drag the
/// tweak's own state (state.plist, containers.plist, diag/) into a container.
static NSString *VSMapPath(NSString *path) {
    if (gRoot.length == 0 || path.length == 0 || ![path hasPrefix:@"/"]) return path;
    NSString *c = VSCanon(path);
    if (VSHasDirPrefix(c, gRootC))   return path;
    if (VSHasDirPrefix(c, gVesselC)) return path;
    if ([c isEqualToString:gRealC])  return gRoot;
    if (![c hasPrefix:[gRealC stringByAppendingString:@"/"]]) return path;
    return [gRoot stringByAppendingPathComponent:[c substringFromIndex:gRealC.length + 1]];
}

#pragma mark - fishhook replacements

static NSString *vs_NSHomeDirectory(void) {
    return gRoot.length ? gRoot : orig_NSHomeDirectory();
}

static NSString *vs_NSTemporaryDirectory(void) {
    return VSMapPath(orig_NSTemporaryDirectory());
}

static NSArray<NSString *> *vs_NSSearchPath(NSSearchPathDirectory dir,
                                            NSSearchPathDomainMask domain,
                                            BOOL expand) {
    NSArray<NSString *> *real = orig_NSSearchPath(dir, domain, expand);
    if (real.count == 0 || gRoot.length == 0) return real;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:real.count];
    for (NSString *p in real) [out addObject:VSMapPath(p)];
    return out;
}

#pragma mark - NSFileManager swizzles

static NSArray<NSURL *> *(*orig_URLsForDirectory)(id, SEL, NSSearchPathDirectory,
                                                  NSSearchPathDomainMask) = NULL;
static NSURL *(*orig_containerURL)(id, SEL, NSString *) = NULL;

static NSArray<NSURL *> *vs_URLsForDirectory(id self_, SEL sel,
                                             NSSearchPathDirectory dir,
                                             NSSearchPathDomainMask dom) {
    NSArray<NSURL *> *real = orig_URLsForDirectory(self_, sel, dir, dom);
    if (real.count == 0 || gRoot.length == 0) return real;
    NSMutableArray<NSURL *> *out = [NSMutableArray arrayWithCapacity:real.count];
    for (NSURL *u in real) {
        // A non-file URL has a nil path, and +fileURLWithPath:nil raises. Anything
        // we cannot read a path from is passed through exactly as Foundation
        // returned it.
        NSString *p = u.path;
        NSString *m = p.length ? VSMapPath(p) : nil;
        [out addObject:(m.length && ![m isEqualToString:p])
                        ? [NSURL fileURLWithPath:m isDirectory:YES] : u];
    }
    return out;
}

/// A nil answer is passed through untouched. Sideloading strips the app-group
/// entitlement, so this already returns nil on the user's device and Instagram
/// already copes with that; handing it a directory it does not get today would
/// push it down a code path nobody has tested. When the group does exist, it is
/// redirected like everything else.
static NSURL *vs_containerURL(id self_, SEL sel, NSString *group) {
    NSURL *real = orig_containerURL(self_, sel, group);
    if (!real || gRoot.length == 0 || group.length == 0) return real;
    NSString *safe = [group stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *p = [[gRoot stringByAppendingPathComponent:@"_vessel/appgroups"]
                   stringByAppendingPathComponent:safe];
    [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return [NSURL fileURLWithPath:p isDirectory:YES];
}

/// method_setImplementation, not class_addMethod + exchange: both selectors here
/// are implemented on NSFileManager itself, and swapping the implementation in
/// place keeps the original callable through a plain function pointer without
/// adding a selector Instagram could see.
static BOOL VSSwizzle(Class cls, SEL sel, void *repl, void **outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}

#pragma mark - Install

@implementation VSHookHome

+ (BOOL)isInstalled { return gInstalled; }
+ (NSString *)containerRoot { return gRoot; }
+ (NSString *)mapPath:(NSString *)path { return VSMapPath(path); }

+ (BOOL)installForContainerRoot:(NSString *)root {
    if (gInstalled) return YES;

    NSString *r = root.stringByStandardizingPath;
    NSString *real = [VSPaths realHome].stringByStandardizingPath;
    if (r.length == 0 || real.length == 0) {
        VSLogE(@"home", @"refusing to install: root=%@ realHome=%@", root, real);
        return NO;
    }

    // A home that half-works is worse than the real one: Instagram would create
    // a fresh account state in a directory it then cannot write to.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *probe = [r stringByAppendingPathComponent:@"_vessel/.homeprobe"];
    [fm createDirectoryAtPath:probe.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        VSLogE(@"home", @"refusing to install: %@ is not writable", r);
        return NO;
    }
    [fm removeItemAtPath:probe error:NULL];

    gRoot   = [r copy];
    gReal   = [real copy];
    gVessel = [[VSPaths vesselRoot].stringByStandardizingPath copy];
    gRootC   = [VSCanon(gRoot) copy];
    gRealC   = [VSCanon(gReal) copy];
    gVesselC = [VSCanon(gVessel) copy];

    // 1. Environment first. CoreFoundation resolves its home through
    //    CFFIXED_USER_HOME (it is not cached, and issetugid() is false for a
    //    normal app), so the paths we cannot reach individually follow from here.
    setenv("CFFIXED_USER_HOME", gRoot.fileSystemRepresentation, 1);
    setenv("HOME", gRoot.fileSystemRepresentation, 1);
    setenv("TMPDIR", [gRoot stringByAppendingPathComponent:@"tmp"].fileSystemRepresentation, 1);

    // 2. The three C entry points, for anything that resolved before us. The
    //    originals are looked up first: fishhook only fills in `replaced` for
    //    symbols some image actually references, and a replacement that then
    //    called a NULL original would be a crash instead of a redirect.
    orig_NSHomeDirectory      = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory");
    orig_NSTemporaryDirectory = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "NSTemporaryDirectory");
    orig_NSSearchPath         = (NSArray<NSString *> *(*)(NSSearchPathDirectory,
                                                          NSSearchPathDomainMask, BOOL))
                                dlsym(RTLD_DEFAULT, "NSSearchPathForDirectoriesInDomains");
    if (!orig_NSHomeDirectory || !orig_NSTemporaryDirectory || !orig_NSSearchPath) {
        VSLogE(@"home", @"refusing to install: dlsym miss (home=%p tmp=%p search=%p)",
               orig_NSHomeDirectory, orig_NSTemporaryDirectory, orig_NSSearchPath);
        gRoot = gReal = gVessel = gRootC = gRealC = gVesselC = nil;
        return NO;
    }
    struct rebinding rb[] = {
        { "NSHomeDirectory",                     (void *)vs_NSHomeDirectory,
          (void **)&orig_NSHomeDirectory },
        { "NSTemporaryDirectory",                (void *)vs_NSTemporaryDirectory,
          (void **)&orig_NSTemporaryDirectory },
        { "NSSearchPathForDirectoriesInDomains", (void *)vs_NSSearchPath,
          (void **)&orig_NSSearchPath },
    };
    int rc = rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
    if (rc != 0) VSLogW(@"home", @"rebind_symbols returned %d", rc);

    // 3. The two ObjC entry points app code actually calls.
    BOOL s1 = VSSwizzle(NSFileManager.class, @selector(URLsForDirectory:inDomains:),
                        (void *)vs_URLsForDirectory, (void **)&orig_URLsForDirectory);
    BOOL s2 = VSSwizzle(NSFileManager.class,
                        @selector(containerURLForSecurityApplicationGroupIdentifier:),
                        (void *)vs_containerURL, (void **)&orig_containerURL);
    if (!s1 || !s2) VSLogW(@"home", @"swizzle miss: URLsForDirectory=%d containerURL=%d", s1, s2);

    gInstalled = YES;
    VSLogI(@"home", @"HOME -> %@", gRoot);
    VSLogI(@"home", @"NSHomeDirectory() now reports %@", NSHomeDirectory());
    return YES;
}

#pragma mark - Verification

/// Canonical-aware: a path the OS hands back as /var/... must still count as
/// inside a container rooted at /private/var/... (and vice versa), or the
/// self-test would report a leak that isn't one.
static BOOL VSInside(NSString *p) {
    return p.length > 0 && VSHasDirPrefix(VSCanon(p), gRootC);
}

+ (NSString *)firstLeak {
    if (!gInstalled) return @"layer 1 not installed";

    NSString *home = NSHomeDirectory();
    if (![home isEqualToString:gRoot])
        return [NSString stringWithFormat:@"NSHomeDirectory() = %@", home];
    if (!VSInside(NSTemporaryDirectory()))
        return [NSString stringWithFormat:@"NSTemporaryDirectory() = %@", NSTemporaryDirectory()];

    NSDictionary<NSNumber *, NSString *> *dirs = @{
        @(NSDocumentDirectory):         @"Documents",
        @(NSLibraryDirectory):          @"Library",
        @(NSCachesDirectory):           @"Caches",
        @(NSApplicationSupportDirectory): @"Application Support",
    };
    for (NSNumber *k in dirs) {
        NSString *p = NSSearchPathForDirectoriesInDomains(
            (NSSearchPathDirectory)k.unsignedIntegerValue, NSUserDomainMask, YES).firstObject;
        if (!VSInside(p)) return [NSString stringWithFormat:@"%@ resolves to %@", dirs[k], p];
    }

    NSString *u = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                      inDomains:NSUserDomainMask].firstObject.path;
    if (!VSInside(u)) return [NSString stringWithFormat:@"URLsForDirectory: gives %@", u];

    // Physical proof rather than string comparison: write through the resolved
    // path, then look for the bytes at the container path computed independently.
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    NSString *probe = [docs stringByAppendingPathComponent:@".vessel-probe"];
    NSString *token = NSUUID.UUID.UUIDString;
    if (![token writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        return [NSString stringWithFormat:@"cannot write %@", probe];
    NSString *expect = [gRoot stringByAppendingPathComponent:@"Documents/.vessel-probe"];
    NSString *back = [NSString stringWithContentsOfFile:expect
                                              encoding:NSUTF8StringEncoding error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:probe error:NULL];
    if (![back isEqualToString:token])
        return [NSString stringWithFormat:@"probe did not land at %@", expect];

    return nil;
}

@end
