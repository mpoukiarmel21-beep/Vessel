//  VSPaths.h — real vs. container filesystem roots.
//
//  Ordering contract: +snapshotRealHome must run before ANY path redirection is
//  installed. Everything else in the tweak resolves its paths through here, so
//  redirection can never make the tweak lose track of its own storage.

#import <Foundation/Foundation.h>

@interface VSPaths : NSObject

/// Captures the genuine data-container home. Idempotent; call first, from the
/// bootstrap constructor, before VSHookHome is installed.
+ (void)snapshotRealHome;

/// The app's genuine home (never redirected). Empty string only if snapshot
/// was skipped, which would be a bug.
+ (NSString *)realHome;

/// <realHome>/Library/Application Support/Vessel — tweak-owned, outside every
/// container, never purged by iOS (unlike Library/Caches).
+ (NSString *)vesselRoot;

/// <vesselRoot>/containers
+ (NSString *)containersRoot;

/// Root that becomes the fake HOME for a given container.
+ (NSString *)rootForContainerID:(NSString *)cid;

/// Tweak-private subdir inside a container (aux stores: defaults, cookies).
/// Lives inside the container so it is wiped together with it.
+ (NSString *)privateDirForContainerID:(NSString *)cid;

/// Creates the standard iOS data-container skeleton so Instagram never has to
/// mkdir a directory it assumes already exists.
+ (BOOL)prepareTreeForContainerID:(NSString *)cid error:(NSError **)err;

/// <vesselRoot>/state.plist — active container id + schema version. Read before
/// redirection, so it must live under the real home.
+ (NSString *)statePath;

/// <vesselRoot>/containers.plist — the container list.
+ (NSString *)listPath;

/// Directory holding a container's payload, for size reporting in the UI.
+ (unsigned long long)diskUsageForContainerID:(NSString *)cid;

/// YES if path is inside the given container root (leak detection in self-test).
+ (BOOL)path:(NSString *)path isInsideContainerID:(NSString *)cid;

@end
