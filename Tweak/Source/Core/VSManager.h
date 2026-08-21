//  VSManager.h — owns the container list, the active selection, and the reset.
//
//  Load order matters: -bootstrapBeforeHooks must run before any hook is
//  installed, because every hook needs to know which container is active and
//  which identity to report. Nothing may create or switch a container during
//  that window.
//
//  Switching container does NOT try to re-point a running Instagram. Half the
//  app would keep the old container's caches, cookies and in-memory account
//  state, which is exactly how "the screen is frozen" and "my account vanished"
//  happen. A switch records the choice, flushes, and asks the user to relaunch.

#import <Foundation/Foundation.h>
#import "VSContainer.h"

/// Posted after the list changes, so open UI can refresh.
extern NSString *const VSContainersDidChangeNotification;

@interface VSManager : NSObject

@property (class, readonly) VSManager *shared;

/// Called from VSBootstrap, before hooks. Loads state, guarantees a default
/// container exists, resolves the active one and prepares its tree.
- (void)bootstrapBeforeHooks;

/// The container every hook must report. Never nil after bootstrap.
@property (nonatomic, readonly, strong) VSContainer *active;
/// Newest-first for display; the default container is always first.
@property (nonatomic, readonly, copy) NSArray<VSContainer *> *containers;

/// How many times Instagram has launched with Vessel installed. Incremented by
/// -bootstrapBeforeHooks and shown in Diagnostics; the value is what tells a
/// "crashes only on the first launch" bug apart from a "crashes every launch"
/// one when the only evidence is a log file.
@property (nonatomic, readonly) NSInteger bootCount;

- (VSContainer *)containerWithID:(NSString *)cid;

#pragma mark - Mutations

/// Generates an identity, creates the tree and persists — all before returning,
/// so a crash immediately after cannot leave a half-made container.
/// @param pxSize  native screen pixel size, for the model pool.
- (VSContainer *)createContainerNamed:(NSString *)name
                     screenPixelSize:(CGSize)pxSize
                               scale:(CGFloat)scale
                               error:(NSError **)err;

- (BOOL)renameContainer:(NSString *)cid to:(NSString *)name;

/// Persists a container's mutated fields (location, note, …).
- (BOOL)saveContainer:(VSContainer *)c;

/// Deletes the tree and the entry. Refuses on the default container and on the
/// container currently in use (switch away first, which needs a relaunch).
- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)err;

/// Records the choice for the next launch. Returns NO if cid is unknown.
- (BOOL)selectContainerForNextLaunch:(NSString *)cid;
/// cid chosen for the next launch, or nil when it equals the active one.
- (NSString *)pendingContainerID;

/// Wipes every container, the list, and the active selection, then recreates an
/// empty default container. Diagnostics logs are deliberately kept: they live
/// outside the containers and are what makes a post-mortem possible.
- (BOOL)resetEverythingWithError:(NSError **)err;

/// Every identifier already in use, for collision-free generation.
- (NSSet<NSString *> *)takenIdentifierValues;

@end
