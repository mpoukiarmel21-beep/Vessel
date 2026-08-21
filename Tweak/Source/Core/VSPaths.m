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
    return [[self rootForContainerID:cid] stringByAppendingPathComponent:@"_vessel"];
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
                       @"tmp",
                       @"_vessel" ];
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
