//  VSManager.m

#import "VSManager.h"
#import "VSPaths.h"
#import "VSStore.h"
#import "VSLog.h"

NSString *const VSContainersDidChangeNotification = @"VSContainersDidChange";

static NSString *const kActiveKey  = @"activeContainer";
static NSString *const kPendingKey = @"pendingContainer";
static NSString *const kListKey    = @"containers";
static NSString *const kSchemaKey  = @"schema";
static NSString *const kBootsKey   = @"bootCount";
static NSString *const kSchemaNow  = @"1";

@interface VSManager () {
    VSStore *_state;       // <vesselRoot>/state.plist   — active + pending
    VSStore *_list;        // <vesselRoot>/containers.plist
    NSMutableArray<VSContainer *> *_containers;
    VSContainer *_active;
    BOOL _booted;
}
@end

@implementation VSManager

+ (VSManager *)shared {
    static VSManager *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[VSManager alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _containers = [NSMutableArray array];
    return self;
}

- (VSContainer *)active     { return _active; }
- (NSArray<VSContainer *> *)containers { return [_containers copy]; }

#pragma mark - Bootstrap

- (void)bootstrapBeforeHooks {
    if (_booted) return;
    _booted = YES;

    _state = [[VSStore alloc] initWithPath:[VSPaths statePath] label:@"state"];
    _list  = [[VSStore alloc] initWithPath:[VSPaths listPath]  label:@"list"];
    [_state attachLifecycleFlush];
    [_list  attachLifecycleFlush];
    [_state setObject:kSchemaNow forKey:kSchemaKey];

    // state.plist has exactly one owner (this class) so two VSStore instances can
    // never race over the same file.
    _bootCount = [[_state objectForKey:kBootsKey] integerValue] + 1;
    [_state setObject:@(_bootCount) forKey:kBootsKey];

    [self loadList];
    [self ensureDefaultContainer];
    [self repairMissingIdentities];
    [self resolveActive];

    // Prepare the tree now: the path hooks are about to redirect HOME into it,
    // and Instagram will start touching Library/Caches before any of our UI runs.
    if (![_active prepareStorage]) {
        VSLogE(@"manager", @"active container tree unusable — hooks must stay off");
    }
    [_state flushNow];
    [_list flushNow];
    VSLogI(@"manager", @"boot #%ld — active=%@ (%@), %lu container(s)",
           (long)_bootCount, _active.name, _active.cid,
           (unsigned long)_containers.count);
}


- (void)loadList {
    [_containers removeAllObjects];
    id raw = [_list objectForKey:kListKey];
    if (![raw isKindOfClass:NSArray.class]) {
        if (raw) VSLogE(@"manager", @"container list is not an array, ignored");
        return;
    }
    for (id entry in (NSArray *)raw) {
        VSContainer *c = [VSContainer containerWithDictionary:entry];
        if (c) [_containers addObject:c];
    }
    VSLogI(@"manager", @"loaded %lu container(s)", (unsigned long)_containers.count);
}

- (BOOL)persistList {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_containers.count];
    for (VSContainer *c in _containers) [out addObject:c.dictionaryRepresentation];
    [_list setObject:out forKey:kListKey];
    // Synchronous: the caller has just created or deleted something the user can
    // see, and a crash before the coalesced flush would silently undo it.
    BOOL ok = [_list flushNow];
    if (!ok) VSLogE(@"manager", @"container list flush FAILED");
    [self sortContainers];
    return ok;
}

- (void)sortContainers {
    [_containers sortUsingComparator:^NSComparisonResult(VSContainer *a, VSContainer *b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? NSOrderedAscending
                                                           : NSOrderedDescending;
        return [b.createdAt compare:a.createdAt];   // newest first
    }];
}

- (void)ensureDefaultContainer {
    for (VSContainer *c in _containers) if (c.isDefault) return;

    VSLogI(@"manager", @"no default container — creating it");
    VSContainer *c = [VSContainer containerWithID:nil name:@"Principal"];
    c.isDefault = YES;
    c.identity  = [self freshIdentity];
    [c prepareStorage];
    [_containers addObject:c];
    [self persistList];
}

/// The screen geometry comes from the model table keyed on the real hw.machine,
/// not from UIScreen: this runs from the bootstrap constructor, where UIScreen is
/// not dependable, and the device hooks that follow need a complete identity
/// immediately. An identity filled in later would mean the first launch reports
/// the real phone and later launches report a different one — a change over time
/// is a worse signal than any single odd value.
- (VSIdentity *)freshIdentity {
    NSString *loc = NSLocale.currentLocale.localeIdentifier ?: @"fr_FR";
    NSString *tz  = NSTimeZone.systemTimeZone.name ?: @"Europe/Paris";
    return [VSIdentity generateForRealDeviceWithLocale:loc
                                             timeZone:tz
                                                taken:[self takenIdentifierValues]];
}

- (NSSet<NSString *> *)takenIdentifierValues {
    NSMutableSet *s = [NSMutableSet set];
    for (VSContainer *c in _containers) {
        if (c.identity) [s unionSet:c.identity.uniqueValues];
    }
    return s;
}

/// Backfills identities for entries written by an older build, or for any entry
/// whose stored identity failed validation.
- (void)repairMissingIdentities {
    BOOL changed = NO;
    for (VSContainer *c in _containers) {
        if (c.identity) continue;
        VSLogW(@"manager", @"%@ (%@) has no usable identity — generating one", c.name, c.cid);
        c.identity = [self freshIdentity];
        changed = YES;
    }
    if (changed) [self persistList];
}

/// Applies any pending choice, then falls back through: pending -> stored active
/// -> default -> first entry. The pending key is consumed here and only here, so
/// a switch takes effect on exactly one launch.
- (void)resolveActive {
    NSString *pending = [_state objectForKey:kPendingKey];
    if ([pending isKindOfClass:NSString.class] && pending.length &&
        [self containerWithID:pending]) {
        [_state setObject:pending forKey:kActiveKey];
        [_state removeObjectForKey:kPendingKey];
        VSLogI(@"manager", @"applying pending switch to %@", pending);
    }

    NSString *wanted = [_state objectForKey:kActiveKey];
    _active = [wanted isKindOfClass:NSString.class] ? [self containerWithID:wanted] : nil;

    if (!_active) {
        for (VSContainer *c in _containers) if (c.isDefault) { _active = c; break; }
    }
    if (!_active) _active = _containers.firstObject;

    if (!_active) {
        // ensureDefaultContainer guarantees this cannot happen; if it somehow
        // does, an in-memory container is better than a nil deref inside every
        // hook that is about to be installed.
        VSLogE(@"manager", @"container list empty after bootstrap — using a transient default");
        _active = [VSContainer containerWithID:nil name:@"Principal"];
        _active.isDefault = YES;
        _active.identity = [self freshIdentity];
        [_containers addObject:_active];
        [self persistList];
    }

    if (![_active.cid isEqualToString:wanted]) [_state setObject:_active.cid forKey:kActiveKey];
    _active.lastUsedAt = [NSDate date];
}

- (VSContainer *)containerWithID:(NSString *)cid {
    if (cid.length == 0) return nil;
    for (VSContainer *c in _containers) if ([c.cid isEqualToString:cid]) return c;
    return nil;
}

- (NSString *)pendingContainerID {
    id p = [_state objectForKey:kPendingKey];
    return [p isKindOfClass:NSString.class] ? p : nil;
}

#pragma mark - Mutations

static NSError *VSErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"Vessel" code:code
                          userInfo:@{ NSLocalizedDescriptionKey: msg ?: @"" }];
}

- (VSContainer *)createContainerNamed:(NSString *)name
                     screenPixelSize:(CGSize)pxSize
                               scale:(CGFloat)scale
                               error:(NSError **)err {
    NSString *trimmed = [(name ?: @"") stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) trimmed = [NSString stringWithFormat:@"Container %lu",
                                        (unsigned long)_containers.count + 1];
    if (trimmed.length > 40) trimmed = [trimmed substringToIndex:40];

    VSContainer *c = [VSContainer containerWithID:nil name:trimmed];
    c.identity = (pxSize.width > 0 && scale > 0)
        ? [VSIdentity generateForScreenPixelSize:pxSize
                                          scale:scale
                                      osVersion:[VSIdentity realOSVersion]
                                        osBuild:[VSIdentity realOSBuild]
                                         locale:(NSLocale.currentLocale.localeIdentifier ?: @"fr_FR")
                                       timeZone:(NSTimeZone.systemTimeZone.name ?: @"Europe/Paris")
                                          taken:[self takenIdentifierValues]]
        : [self freshIdentity];

    // Tree first: an entry in the list pointing at a directory that does not
    // exist would make the next launch redirect HOME into nothing.
    if (![c prepareStorage]) {
        if (err) *err = VSErr(1, @"Impossible de créer le dossier du container.");
        return nil;
    }
    [_containers addObject:c];
    if (![self persistList]) {
        if (err) *err = VSErr(2, @"Le container n'a pas pu être enregistré.");
        [_containers removeObject:c];
        return nil;
    }
    VSLogI(@"manager", @"created %@ (%@) %@", c.name, c.cid, c.identity.shortDescription);
    [NSNotificationCenter.defaultCenter postNotificationName:VSContainersDidChangeNotification
                                                     object:nil];
    return c;
}

- (BOOL)renameContainer:(NSString *)cid to:(NSString *)name {
    VSContainer *c = [self containerWithID:cid];
    NSString *trimmed = [(name ?: @"") stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!c || trimmed.length == 0) return NO;
    c.name = trimmed.length > 40 ? [trimmed substringToIndex:40] : trimmed;
    BOOL ok = [self persistList];
    if (ok) [NSNotificationCenter.defaultCenter
             postNotificationName:VSContainersDidChangeNotification object:nil];
    return ok;
}

- (BOOL)saveContainer:(VSContainer *)c {
    if (!c || ![self containerWithID:c.cid]) return NO;
    BOOL ok = [self persistList];
    if (ok) [NSNotificationCenter.defaultCenter
             postNotificationName:VSContainersDidChangeNotification object:nil];
    return ok;
}

- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)err {
    VSContainer *c = [self containerWithID:cid];
    if (!c) { if (err) *err = VSErr(3, @"Container introuvable."); return NO; }
    if (c.isDefault) {
        if (err) *err = VSErr(4, @"Le container par défaut ne peut pas être supprimé.");
        return NO;
    }
    if ([c.cid isEqualToString:_active.cid]) {
        // Instagram's caches, cookies and in-memory account state all live in
        // this tree right now. Deleting it underneath a running app is how the
        // UI ends up frozen on a half-dead session.
        if (err) *err = VSErr(5, @"Ce container est en cours d'utilisation. "
                                 @"Basculez sur un autre container, relancez, puis supprimez-le.");
        return NO;
    }

    NSError *fe = nil;
    NSString *root = c.rootPath;
    if (root.length && [NSFileManager.defaultManager fileExistsAtPath:root] &&
        ![NSFileManager.defaultManager removeItemAtPath:root error:&fe]) {
        VSLogE(@"manager", @"delete %@: %@", cid, fe.localizedDescription);
        if (err) *err = fe;
        return NO;
    }
    [_containers removeObject:c];
    BOOL ok = [self persistList];
    VSLogI(@"manager", @"deleted %@ (%@)", c.name, cid);
    if (ok) [NSNotificationCenter.defaultCenter
             postNotificationName:VSContainersDidChangeNotification object:nil];
    return ok;
}

#pragma mark - Switching

/// Records the choice and flushes immediately. Deliberately does NOT touch the
/// live app: see the header. Selecting the container that is already active
/// cancels a previously pending switch instead of queueing a no-op.
- (BOOL)selectContainerForNextLaunch:(NSString *)cid {
    VSContainer *c = [self containerWithID:cid];
    if (!c) { VSLogE(@"manager", @"switch to unknown container %@ refused", cid); return NO; }

    if ([c.cid isEqualToString:_active.cid]) {
        [_state removeObjectForKey:kPendingKey];
        [_state flushNow];
        VSLogI(@"manager", @"pending switch cleared (%@ is already active)", c.name);
    } else {
        [_state setObject:c.cid forKey:kPendingKey];
        [_state flushNow];
        VSLogI(@"manager", @"switch to %@ (%@) armed for next launch", c.name, c.cid);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VSContainersDidChangeNotification
                                                     object:nil];
    return YES;
}

#pragma mark - Reset

- (BOOL)resetEverythingWithError:(NSError **)err {
    VSLogW(@"manager", @"FULL RESET requested — wiping %lu container(s)",
           (unsigned long)_containers.count);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *first = nil;

    // Remove every container tree we know about, then sweep the containers root
    // for orphans a failed create could have left behind. Keep going after a
    // failure: a partial wipe that reports the error beats stopping halfway and
    // leaving the list pointing at trees that are already gone.
    for (VSContainer *c in [_containers copy]) {
        NSString *root = c.rootPath;
        NSError *fe = nil;
        if (root.length && [fm fileExistsAtPath:root] &&
            ![fm removeItemAtPath:root error:&fe]) {
            VSLogE(@"manager", @"reset: %@ (%@): %@", c.name, c.cid, fe.localizedDescription);
            if (!first) first = fe;
        }
    }

    NSString *croot = [VSPaths containersRoot];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:croot error:NULL] ?: @[]) {
        NSString *p = [croot stringByAppendingPathComponent:entry];
        NSError *fe = nil;
        if (![fm removeItemAtPath:p error:&fe]) {
            VSLogE(@"manager", @"reset: orphan %@: %@", entry, fe.localizedDescription);
            if (!first) first = fe;
        }
    }

    // The list and the active/pending selection go too. The diagnostics
    // directory is deliberately untouched: it sits outside the containers and is
    // the only thing that makes a post-mortem of this reset possible.
    [_containers removeAllObjects];
    [_list replaceAllValues:@{}];
    [_list flushNow];
    [_state removeObjectForKey:kActiveKey];
    [_state removeObjectForKey:kPendingKey];
    [_state flushNow];
    _active = nil;

    // Rebuild from scratch, exactly as a first launch would.
    [self ensureDefaultContainer];
    [self resolveActive];
    if (![_active prepareStorage]) {
        VSLogE(@"manager", @"reset: fresh default tree unusable");
        if (!first) first = VSErr(6, @"Le dossier du nouveau container par défaut "
                                     @"n'a pas pu être créé.");
    }
    [_state flushNow];
    [_list flushNow];

    VSLogI(@"manager", @"reset done — active=%@ (%@)", _active.name, _active.cid);
    [NSNotificationCenter.defaultCenter postNotificationName:VSContainersDidChangeNotification
                                                     object:nil];

    if (first) { if (err) *err = first; return NO; }
    return YES;
}

@end
