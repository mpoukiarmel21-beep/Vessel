//  VSHookHome.h — isolation layer 1: the filesystem.
//
//  Instagram keeps its SQLite databases, media caches, Documents and most of
//  Library/ under the app's data-container home. Pointing that home at
//  <Vessel>/containers/<cid> gives each container its own copy of all of it.
//
//  Three mechanisms, deliberately overlapping, because a single leaked path
//  means Instagram writes outside the container and two accounts start sharing
//  state — which is silent, not a crash, and therefore only findable by looking:
//
//    1. setenv HOME / CFFIXED_USER_HOME / TMPDIR. CoreFoundation resolves the
//       home directory through CFFIXED_USER_HOME, so everything derived inside
//       CF and Foundation — including code we cannot hook — follows.
//    2. fishhook on NSHomeDirectory / NSTemporaryDirectory /
//       NSSearchPathForDirectoriesInDomains, for callers that resolved a path
//       before us or that bypass CF.
//    3. swizzle on -[NSFileManager URLsForDirectory:inDomains:] and
//       -containerURLForSecurityApplicationGroupIdentifier:, the two ObjC entry
//       points app code actually uses.
//
//  Mapping rule: a path under the real home is rewritten to the same relative
//  path under the container. Paths already inside the container, paths under
//  Vessel's own storage, and every absolute system path are left untouched —
//  so the tweak's state, logs and diagnostics never move into a container and
//  are never wiped with one.

#import <Foundation/Foundation.h>

@interface VSHookHome : NSObject

/// Installs all three mechanisms. `root` must exist (VSManager prepares the
/// tree before hooks are installed). Idempotent; returns NO and installs
/// nothing if the root is missing or unwritable, leaving Instagram on its real
/// home rather than on a home that half-works.
+ (BOOL)installForContainerRoot:(NSString *)root;

+ (BOOL)isInstalled;

/// The container root currently redirected to, or nil.
+ (NSString *)containerRoot;

/// Rewrites a real-home path into the container. Exposed for the other hooks
/// and for the self-test; a no-op for anything outside the real home.
+ (NSString *)mapPath:(NSString *)path;

/// Layer-1 verification for VSSelfTest: resolves the directories Instagram uses
/// through the same public APIs, writes and reads back a probe file, and returns
/// a description of the first thing that still points outside the container.
/// nil means the layer holds.
+ (NSString *)firstLeak;

@end
