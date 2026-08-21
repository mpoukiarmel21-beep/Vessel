//  VSPaths.m

#import "VSPaths.h"
#import "VSLog.h"

static NSString *gRealHome = nil;

@implementation VSPaths

+ (void)snapshotRealHome {
    if (gRealHome.length) return;
    // NSHomeDirectory() is still genuine here: VSHookHome has not been installed
    // yet (enforced by VSBootstrap's ordering).
    NSString *h = NSHomeDirectory();
    if (h.length == 0) {
        // Last-resort derivation: Documents is always <home>/Documents.
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        h = docs.length ? docs.stringByDeletingLastPathComponent : NSTemporaryDirectory();
    }
    gRealHome = [h copy];
}

+ (NSString *)realHome { return gRealHome ?: @""; }

+ (NSString *)vesselRoot {
    return [[self realHome] stringByAppendingPathComponent:
            @"Library/Application Support/Vessel"];
}

+ (NSString *)containersRoot {
    return [[self vesselRoot] stringByAppendingPathComponent:@"containers"];
}

+ (NSString *)rootForContainerID:(NSString *)cid {
    if (cid.length == 0) return @"";
    return [[self containersRoot] stringByAppendingPathComponent:cid];
}

+ (NSString *)privateDirForContainerID:(NSString *)cid {
    if (cid.length == 0) return @"";
    // OUTSIDE the container root, under vesselRoot — which VSHookHome's VSMapPath
    // deliberately excludes from redirection. Two reasons it must not live inside
    // the container: (1) the container root becomes Instagram's HOME, and a folder
    // full of our aux stores (cookies.plist, defaults.plist) sitting in the app's
    // home is a plain "this app is modified" tell; (2) keeping it out means our
    // stores are never handed to Instagram through any redirected path. It is wiped
    // explicitly on container delete / reset (see VSManager), not by removing the
    // container tree.
    return [[[self vesselRoot] stringByAppendingPathComponent:@"private"]
            stringByAppendingPathComponent:cid];
}

/// <vesselRoot>/private — parent of every container's private store. One directory
/// to remove on a full reset.
+ (NSString *)privateRoot {
    return [[self vesselRoot] stringByAppendingPathComponent:@"private"];
}

+ (NSString *)statePath {
    return [[self vesselRoot] stringByAppendingPathComponent:@"state.plist"];
}

+ (NSString *)listPath {
    return [[self vesselRoot] stringByAppendingPathComponent:@"containers.plist"];
}

+ (BOOL)prepareTreeForContainerID:(NSString *)cid error:(NSError **)err {
    NSString *root = [self rootForContainerID:cid];
    if (root.length == 0) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;

    // Mirrors the real iOS data container layout. Instagram (and CFNetwork,
    // and NSURLCache) assume several of these exist.
    NSArray *subs = @[ @"Documents",
                       @"Library",
                       @"Library/Caches",
                       @"Library/Preferences",
                       @"Library/Cookies",
                       @"Library/Application Support",
                       @"Library/SplashBoard",
                       @"Library/WebKit",
                       @"SystemData",
                       @"tmp" ];
    for (NSString *s in subs) {
        NSString *p = [root stringByAppendingPathComponent:s];
        NSError *e = nil;
        if (![fm createDirectoryAtPath:p withIntermediateDirectories:YES
                           attributes:nil error:&e] && e) {
            VSLogE(@"paths", @"mkdir failed %@: %@", s, e.localizedDescription);
            if (err) *err = e;
            return NO;
        }
    }
    // Keep container payload out of iCloud/iTunes backups: it is disposable
    // app state, and backing up N copies of Instagram's cache is pointless.
    NSURL *u = [NSURL fileURLWithPath:root];
    [u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

+ (unsigned long long)diskUsageForContainerID:(NSString *)cid {
    NSString *root = [self rootForContainerID:cid];
    if (root.length == 0) return 0;
    unsigned long long total = 0;
    NSDirectoryEnumerator *it = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in it) {
        NSDictionary *a = it.fileAttributes;
        if ([a.fileType isEqualToString:NSFileTypeRegular]) total += a.fileSize;
    }
    return total;
}

+ (BOOL)path:(NSString *)path isInsideContainerID:(NSString *)cid {
    NSString *root = [[self rootForContainerID:cid] stringByStandardizingPath];
    NSString *p = path.stringByStandardizingPath;
    if (root.length == 0 || p.length == 0) return NO;
    return [p isEqualToString:root] ||
           [p hasPrefix:[root stringByAppendingString:@"/"]];
}

@end
