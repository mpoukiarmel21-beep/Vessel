//  VSHookKeychain.m

#import "VSHookKeychain.h"
#import "../Core/VSLog.h"
#import "../Core/VSWatchdog.h"
#import "../vendor/fishhook/fishhook.h"
#import <Security/Security.h>
#import <dlfcn.h>

static NSString  *gPrefix = nil;     // "vsl" + cid + ":"  — fixed length
static NSUInteger gPrefixLen = 0;
static BOOL       gInstalled = NO;

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef) = NULL;

#pragma mark - Namespaced attributes

/// The attributes that make up a keychain item's identity. Prefixing these — and
/// only these — is what puts each container on its own rows: two containers can
/// hold "the same" service+account and never collide, and a query built from the
/// same attributes only ever resolves to the container that wrote them. Value is
/// a string for all but the key tag, which is data.
static NSArray<NSString *> *VSStringAttrs(void) {
    static NSArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ (__bridge NSString *)kSecAttrService,
               (__bridge NSString *)kSecAttrAccount,
               (__bridge NSString *)kSecAttrServer,
               (__bridge NSString *)kSecAttrLabel ];
    });
    return a;
}

static NSData *VSPrefixData(void) {
    return [gPrefix dataUsingEncoding:NSUTF8StringEncoding];
}

/// Returns a copy of `in` with the namespace applied to every identity attribute
/// present. *outFound reports whether at least one was — i.e. whether the dict is
/// now scoped to this container, or whether the caller named no identity at all
/// (a broad query, handled separately).
static NSDictionary *VSApply(NSDictionary *in, BOOL *outFound) {
    if (![in isKindOfClass:NSDictionary.class]) { if (outFound) *outFound = NO; return in; }
    NSMutableDictionary *d = [in mutableCopy];
    BOOL found = NO;
    for (NSString *k in VSStringAttrs()) {
        id v = d[k];
        if ([v isKindOfClass:NSString.class]) { d[k] = [gPrefix stringByAppendingString:v]; found = YES; }
    }
    id tag = d[(__bridge NSString *)kSecAttrApplicationTag];
    if ([tag isKindOfClass:NSData.class]) {
        NSMutableData *m = [VSPrefixData() mutableCopy];
        [m appendData:tag];
        d[(__bridge NSString *)kSecAttrApplicationTag] = m;
        found = YES;
    }
    if (outFound) *outFound = found;
    return d;
}

/// Inverse of VSApply for a single returned attribute dictionary: strips the
/// namespace so the caller sees exactly the value it stored.
static NSDictionary *VSStripDict(id in) {
    if (![in isKindOfClass:NSDictionary.class]) return in;
    NSMutableDictionary *d = [(NSDictionary *)in mutableCopy];
    for (NSString *k in VSStringAttrs()) {
        id v = d[k];
        if ([v isKindOfClass:NSString.class] && [(NSString *)v hasPrefix:gPrefix])
            d[k] = [(NSString *)v substringFromIndex:gPrefixLen];
    }
    id tag = d[(__bridge NSString *)kSecAttrApplicationTag];
    NSData *pfx = VSPrefixData();
    if ([tag isKindOfClass:NSData.class] && [(NSData *)tag length] >= pfx.length &&
        [[(NSData *)tag subdataWithRange:NSMakeRange(0, pfx.length)] isEqualToData:pfx]) {
        d[(__bridge NSString *)kSecAttrApplicationTag] =
            [(NSData *)tag subdataWithRange:NSMakeRange(pfx.length, [(NSData *)tag length] - pfx.length)];
    }
    return d;
}

/// True if a returned item carries this container's namespace on any identity
/// attribute. Used to filter a broad enumeration down to our own rows.
static BOOL VSBelongs(NSDictionary *attrs) {
    if (![attrs isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *k in VSStringAttrs()) {
        id v = attrs[k];
        if ([v isKindOfClass:NSString.class] && [(NSString *)v hasPrefix:gPrefix]) return YES;
    }
    id tag = attrs[(__bridge NSString *)kSecAttrApplicationTag];
    NSData *pfx = VSPrefixData();
    if ([tag isKindOfClass:NSData.class] && [(NSData *)tag length] >= pfx.length &&
        [[(NSData *)tag subdataWithRange:NSMakeRange(0, pfx.length)] isEqualToData:pfx]) return YES;
    return NO;
}

/// Strips the namespace from a CopyMatching result in place, whatever its shape
/// (a single attribute dict, or an array of them for a match-all). Data and ref
/// results carry no attributes and are left untouched. Balances ownership: the
/// caller's +1 result is released and replaced with a +1 stripped copy.
static void VSStripInPlace(CFTypeRef *result) {
    if (!result || !*result) return;
    id obj = (__bridge id)*result;
    id out = nil;
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:((NSArray *)obj).count];
        for (id e in (NSArray *)obj) [a addObject:VSStripDict(e)];
        out = a;
    } else if ([obj isKindOfClass:NSDictionary.class]) {
        out = VSStripDict(obj);
    } else {
        return;   // NSData / SecKeychainItemRef / persistent ref: nothing to strip
    }
    CFRelease(*result);
    *result = CFBridgingRetain(out);
}

#pragma mark - Broad queries (no identity attribute named)

/// Mirror the caller's kSecAttrSynchronizable intent into a derived query, instead
/// of forcing kSecAttrSynchronizableAny. Forcing "Any" escalated EVERY broad query
/// onto the iCloud-Keychain (synchronizable) path: during account signup the
/// syncing keybag is itself mid-write, and a match over synchronizable items can
/// then block in securityd for a long time — on a background thread the main-thread
/// watchdog never sees. That is the freeze at Instagram's "nom complet" step.
/// Mirroring keeps our reads/writes on exactly the store the un-hooked app intended,
/// so isolation stays faithful with no stall the app never asked for. A nil intent
/// means the caller named none — Apple's default, i.e. local (non-synchronizable).
static void VSMirrorSyncIntent(NSMutableDictionary *dst, NSDictionary *caller) {
    id sync = caller[(__bridge id)kSecAttrSynchronizable];
    if (sync) dst[(__bridge id)kSecAttrSynchronizable] = sync;
    else      [dst removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
}

/// A query that names no identity attribute cannot be scoped by prefixing — left
/// alone it would touch every container's rows. We enumerate all rows the query
/// matches, keep only the ones carrying our namespace, and hand back their
/// persistent refs; the broad paths below then address those rows one at a time,
/// so another container's rows are never read, updated, or deleted.
///
/// *outStatus carries securityd's verdict on the enumeration itself, which the
/// callers need in order NOT to invent one. See VSBroadStatus.
static NSArray *VSMatchingPersistentRefs(NSDictionary *query, OSStatus *outStatus) {
    if (outStatus) *outStatus = errSecSuccess;
    NSMutableDictionary *e = [query mutableCopy];
    [e removeObjectForKey:(__bridge id)kSecReturnData];
    [e removeObjectForKey:(__bridge id)kSecReturnRef];
    e[(__bridge id)kSecReturnAttributes]    = @YES;
    e[(__bridge id)kSecReturnPersistentRef] = @YES;
    e[(__bridge id)kSecMatchLimit]          = (__bridge id)kSecMatchLimitAll;
    VSMirrorSyncIntent(e, query);   // mirror the caller — never force Any (see helper)

    CFTypeRef out = NULL;
    OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)e, &out);
    NSArray *items = (__bridge_transfer NSArray *)out;
    if (outStatus) *outStatus = st;
    if (st != errSecSuccess || ![items isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *refs = [NSMutableArray array];
    for (id d in items) {
        if (!VSBelongs(d)) continue;
        id pref = ((NSDictionary *)d)[(__bridge id)kSecValuePersistentRef];
        if ([pref isKindOfClass:NSData.class]) [refs addObject:pref];
    }
    return refs;
}

/// Fetches exactly one item, addressed by its persistent ref, in whatever shape
/// the caller's original query asked for (bare data/ref, or an attribute dict).
/// A persistent ref names a single row, so this can never reach another
/// container's item — which is why the broad paths below never fall back to the
/// caller's unscoped query.
static OSStatus VSFetchOne(NSData *ref, NSDictionary *callerQuery, CFTypeRef *out) {
    NSMutableDictionary *q = [callerQuery mutableCopy];
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    q[(__bridge id)kSecValuePersistentRef] = ref;
    VSMirrorSyncIntent(q, callerQuery);   // same intent used to enumerate the ref
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, out);
}

#pragma mark - Refusal observation (log-only, codes only)

// Present in every current SDK, defined defensively so an older one still builds:
// -34018 is the code securityd returns when the caller's signature does not carry
// the keychain access group named by the query.
#ifndef errSecMissingEntitlement
#define errSecMissingEntitlement ((OSStatus)-34018)
#endif

static id VSKcLock(void) {
    static id o; static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [NSObject new]; });
    return o;
}

static NSUInteger gRefusals    = 0;   // broad queries securityd refused outright
static NSUInteger gMissingEnt  = 0;   // ...of which errSecMissingEntitlement (-34018)
static OSStatus   gLastRefusal = 0;
static NSUInteger gRefusalLogged = 0;
static const NSUInteger kMaxRefusalLines = 8;

/// Counts what securityd refused, so "the shared credential store is unreachable"
/// becomes a number on the Diagnostics screen instead of a hypothesis. OSStatus
/// codes only — never an attribute value, never an item.
static void VSNoteRefusal(OSStatus st) {
    BOOL log = NO;
    @synchronized (VSKcLock()) {
        gRefusals++;
        if (st == errSecMissingEntitlement) gMissingEnt++;
        gLastRefusal = st;
        if (gRefusalLogged < kMaxRefusalLines) { gRefusalLogged++; log = YES; }
    }
    if (log) VSLogI(@"keychain", @"keys: securityd refused a broad query (%d) — "
                    @"passed through unchanged", (int)st);
}

/// Turning "securityd refused this query" into "there is no such item" is a lie a
/// caller can hang on, and it is the one lie the broad paths used to tell. When a
/// query names no identity attribute we answer it by enumerating rows first, so
/// EVERY failure of that enumeration used to collapse into errSecItemNotFound.
///
/// This matters here, not in theory. Analysing the base IPA shows Instagram 443
/// reaches Meta's cross-app credential store (FXAccessLibrary,
/// IGAuthHeaderStore::SaveAuthHeaderInAccessLibrary) through shared keychain access
/// groups, and the original entitlements declare exactly two —
/// MH9GU9K5PX.platformFamily and MH9GU9K5PX.shared — under Instagram's own team
/// prefix. A re-signed sideload is signed by ANOTHER team, so those groups cannot
/// be carried over and securityd answers errSecMissingEntitlement (-34018) instead.
/// The binary carries a `missingAccessGroup` path, i.e. the app knows how to give
/// up when the store is unreachable; it has no reason to give up on "the store is
/// reachable and simply empty", which is what -25300 says. Reporting the real code
/// costs nothing and removes a whole class of silent wait.
static OSStatus VSBroadStatus(OSStatus enumStatus) {
    // No rows of ours matched. If the enumeration itself succeeded (or genuinely
    // found nothing) that is a true "not found"; anything else is securityd's own
    // verdict and belongs to the caller unmodified.
    if (enumStatus == errSecSuccess || enumStatus == errSecItemNotFound)
        return errSecItemNotFound;
    VSNoteRefusal(enumStatus);
    return enumStatus;
}

/// Match-all / single reads that named no identity attribute: fetch each of our
/// own rows by its persistent ref, so another container's rows can never appear
/// in the result. Each per-ref fetch returns the caller's exact shape, so the
/// assembled array is byte-for-byte what a real match-all would have produced.
static OSStatus VSBroadCopy(NSDictionary *query, CFTypeRef *result) {
    OSStatus es = errSecSuccess;
    NSArray *refs = VSMatchingPersistentRefs(query, &es);
    if (refs.count == 0) { if (result) *result = NULL; return VSBroadStatus(es); }

    BOOL all = [query[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll];
    if (!all) {
        OSStatus st = VSFetchOne(refs.firstObject, query, result);
        if (st == errSecSuccess) VSStripInPlace(result);
        return st;
    }
    NSMutableArray *acc = [NSMutableArray array];
    for (NSData *ref in refs) {
        CFTypeRef one = NULL;
        if (VSFetchOne(ref, query, &one) == errSecSuccess && one)
            [acc addObject:VSStripDict((__bridge_transfer id)one)];
    }
    if (acc.count == 0) { if (result) *result = NULL; return errSecItemNotFound; }
    if (result) *result = CFBridgingRetain(acc);
    return errSecSuccess;
}

/// Deletes / updates only our own rows, one persistent ref at a time. Never
/// re-issues the caller's unscoped query, so a "delete every generic password"
/// logout in one container cannot touch another's. errSecItemNotFound on an
/// individual row is not an error — the aim was to clear it and it is gone.
static OSStatus VSBroadDelete(NSDictionary *query) {
    OSStatus es = errSecSuccess;
    NSArray *refs = VSMatchingPersistentRefs(query, &es);
    if (refs.count == 0) return VSBroadStatus(es);
    OSStatus last = errSecSuccess;
    for (NSData *ref in refs) {
        NSMutableDictionary *one =
            [@{ (__bridge id)kSecValuePersistentRef: ref } mutableCopy];
        VSMirrorSyncIntent(one, query);
        OSStatus st = orig_SecItemDelete((__bridge CFDictionaryRef)one);
        if (st != errSecSuccess && st != errSecItemNotFound) last = st;
    }
    return last;
}

static OSStatus VSBroadUpdate(NSDictionary *query, NSDictionary *prefixedUpdate) {
    OSStatus es = errSecSuccess;
    NSArray *refs = VSMatchingPersistentRefs(query, &es);
    if (refs.count == 0) return VSBroadStatus(es);
    OSStatus last = errSecSuccess;
    for (NSData *ref in refs) {
        NSMutableDictionary *one =
            [@{ (__bridge id)kSecValuePersistentRef: ref } mutableCopy];
        VSMirrorSyncIntent(one, query);
        OSStatus st = orig_SecItemUpdate((__bridge CFDictionaryRef)one,
                                         (__bridge CFDictionaryRef)prefixedUpdate);
        if (st != errSecSuccess && st != errSecItemNotFound) last = st;
    }
    return last;
}

#pragma mark - fishhook replacements

static OSStatus vs_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!gInstalled || !attributes) return orig_SecItemAdd(attributes, result);
    @autoreleasepool {
        // If the item carries no identity attribute at all (no service/account/
        // server/label/tag) VSApply is a no-op and the row is shared — but such an
        // item has an empty primary key and Instagram never stores its session
        // that way, so the realistic paths are always namespaced.
        NSDictionary *scoped = VSApply((__bridge NSDictionary *)attributes, NULL);
        VSMark("keychain:add");
        OSStatus st = orig_SecItemAdd((__bridge CFDictionaryRef)scoped, result);
        VSMark("keychain:add.done");
        if (st == errSecSuccess) VSStripInPlace(result);   // caller never sees the tag
        return st;
    }
}

static OSStatus vs_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!gInstalled || !query) return orig_SecItemCopyMatching(query, result);
    @autoreleasepool {
        BOOL found = NO;
        NSDictionary *q = VSApply((__bridge NSDictionary *)query, &found);
        if (found) {
            VSMark("keychain:copy");
            OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, result);
            VSMark("keychain:copy.done");
            if (st == errSecSuccess) VSStripInPlace(result);
            return st;
        }
        VSMark("keychain:broad-copy");   // N+1 securityd round-trips — prime hang suspect
        OSStatus st = VSBroadCopy((__bridge NSDictionary *)query, result);
        VSMark("keychain:broad-copy.done");
        return st;
    }
}

static OSStatus vs_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!gInstalled || !query) return orig_SecItemUpdate(query, attributesToUpdate);
    @autoreleasepool {
        BOOL found = NO;
        NSDictionary *q = VSApply((__bridge NSDictionary *)query, &found);
        // A rename that touches an identity attribute must stay in our namespace,
        // so the update dict is prefixed too.
        NSDictionary *upd = VSApply((__bridge NSDictionary *)attributesToUpdate, NULL);
        if (found) return orig_SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)upd);
        VSMark("keychain:broad-update");
        OSStatus st = VSBroadUpdate((__bridge NSDictionary *)query, upd);
        VSMark("keychain:broad-update.done");
        return st;
    }
}

static OSStatus vs_SecItemDelete(CFDictionaryRef query) {
    if (!gInstalled || !query) return orig_SecItemDelete(query);
    @autoreleasepool {
        BOOL found = NO;
        NSDictionary *q = VSApply((__bridge NSDictionary *)query, &found);
        if (found) return orig_SecItemDelete((__bridge CFDictionaryRef)q);
        VSMark("keychain:broad-delete");
        OSStatus st = VSBroadDelete((__bridge NSDictionary *)query);
        VSMark("keychain:broad-delete.done");
        return st;
    }
}

#pragma mark - Install

@implementation VSHookKeychain

+ (BOOL)isInstalled { return gInstalled; }
+ (NSString *)namespacePrefix { return gPrefix; }

+ (BOOL)installForContainerID:(NSString *)cid {
    if (gInstalled) return YES;
    if (cid.length == 0) { VSLogE(@"keychain", @"refusing to install: empty cid"); return NO; }

    gPrefix    = [[NSString stringWithFormat:@"vsl%@:", cid] copy];
    gPrefixLen = gPrefix.length;

    // Originals first: fishhook only fills `replaced` for referenced symbols, and
    // a replacement that then called a NULL original would crash securityd's
    // client rather than isolate it. If any is missing we install nothing and
    // Instagram keeps the shared keychain — worse for isolation, but not a crash.
    orig_SecItemAdd          = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
    orig_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    orig_SecItemUpdate       = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
    orig_SecItemDelete       = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (!orig_SecItemAdd || !orig_SecItemCopyMatching || !orig_SecItemUpdate || !orig_SecItemDelete) {
        VSLogE(@"keychain", @"refusing to install: dlsym miss add=%p copy=%p upd=%p del=%p",
               orig_SecItemAdd, orig_SecItemCopyMatching, orig_SecItemUpdate, orig_SecItemDelete);
        gPrefix = nil; gPrefixLen = 0;
        return NO;
    }
    struct rebinding rb[] = {
        { "SecItemAdd",          (void *)vs_SecItemAdd,          (void **)&orig_SecItemAdd },
        { "SecItemCopyMatching", (void *)vs_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching },
        { "SecItemUpdate",       (void *)vs_SecItemUpdate,       (void **)&orig_SecItemUpdate },
        { "SecItemDelete",       (void *)vs_SecItemDelete,       (void **)&orig_SecItemDelete },
    };
    int rc = rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
    if (rc != 0) VSLogW(@"keychain", @"rebind_symbols returned %d", rc);

    gInstalled = YES;
    VSLogI(@"keychain", @"namespace -> %@", gPrefix);
    return YES;
}

#pragma mark - Verification

/// Physical proof, not a string comparison: query securityd directly through the
/// UN-hooked function. The row must be invisible under the bare service the app
/// asked for and present under the namespaced one — i.e. the isolation is real at
/// the store, not just in our own bookkeeping. Returns nil when both hold.
+ (NSString *)physicalProofForService:(NSString *)service {
    CFTypeRef tmp = NULL;
    NSDictionary *bare = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: service,
                            (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne };
    OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)bare, &tmp);
    if (tmp) { CFRelease(tmp); tmp = NULL; }
    if (st != errSecItemNotFound)
        return @"raw query with the un-prefixed service still found the item";

    NSDictionary *pfx = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecAttrService: [gPrefix stringByAppendingString:service],
                           (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne };
    st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)pfx, &tmp);
    if (tmp) { CFRelease(tmp); tmp = NULL; }
    if (st != errSecSuccess)
        return @"item is not stored under the namespaced service";
    return nil;
}

+ (NSString *)firstLeak {
    if (!gInstalled) return @"layer 2 not installed";

    NSString *service = [@"com.vessel.selftest." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSData   *secret  = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *del = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecAttrService: service };

    // Start from a clean slate, then store through the public (hooked) API.
    SecItemDelete((__bridge CFDictionaryRef)del);
    NSDictionary *add = @{ (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecAttrService: service,
                           (__bridge id)kSecAttrAccount: @"probe",
                           (__bridge id)kSecValueData:   secret };
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st != errSecSuccess)
        return [NSString stringWithFormat:@"SecItemAdd failed (%d)", (int)st];

    // Read it back the same way: the container must see its own value, and the
    // attributes must come back WITHOUT the namespace (proves stripping).
    NSDictionary *q = @{ (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService:      service,
                         (__bridge id)kSecReturnData:       @YES,
                         (__bridge id)kSecReturnAttributes: @YES };
    CFTypeRef out = NULL;
    st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    NSDictionary *got = (__bridge_transfer NSDictionary *)out;
    if (st != errSecSuccess || ![got isKindOfClass:NSDictionary.class]) {
        SecItemDelete((__bridge CFDictionaryRef)del);
        return [NSString stringWithFormat:@"read-back failed (%d)", (int)st];
    }
    if (![got[(__bridge id)kSecValueData] isEqualToData:secret]) {
        SecItemDelete((__bridge CFDictionaryRef)del);
        return @"read-back returned the wrong bytes";
    }
    if (![got[(__bridge id)kSecAttrService] isEqualToString:service]) {
        SecItemDelete((__bridge CFDictionaryRef)del);
        return [NSString stringWithFormat:@"service came back namespaced: %@",
                got[(__bridge id)kSecAttrService]];
    }

    NSString *phys = [self physicalProofForService:service];
    SecItemDelete((__bridge CFDictionaryRef)del);   // cleanup regardless
    return phys;
}

#pragma mark - Shared-credential-store reachability

/// The two keychain access groups the base IPA's own entitlements declare, read out
/// of its code signature: <plist> keychain-access-groups = MH9GU9K5PX.platformFamily,
/// MH9GU9K5PX.shared. They are prefixed with Instagram's team id, so no re-signature
/// by another team can carry them; this is the surface FXAccessLibrary /
/// IGAuthHeaderStore use to share credentials with the other Meta apps.
static NSArray<NSString *> *VSDeclaredGroups(void) {
    return @[ @"MH9GU9K5PX.platformFamily", @"MH9GU9K5PX.shared" ];
}

/// Asks securityd, for each declared group, "would you even look?" — a read with
/// kSecMatchLimitOne that returns nothing. -34018 (errSecMissingEntitlement) means
/// the group is out of reach for this signature; -25300 means reachable and empty.
/// Uses the ORIGINAL SecItemCopyMatching so the answer describes the app's
/// entitlements and not our own bookkeeping. Nothing is read, added or deleted, and
/// only the status code is reported.
+ (NSString *)accessGroupsDescription {
    // Falls back to the public symbol when the layer is not installed: the question
    // is about the app's entitlements, and it is worth answering either way. Our own
    // replacement never rewrites kSecAttrAccessGroup, so both routes agree.
    OSStatus (*copy)(CFDictionaryRef, CFTypeRef *) = orig_SecItemCopyMatching;
    if (!copy) copy = &SecItemCopyMatching;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *g in VSDeclaredGroups()) {
        NSDictionary *q = @{ (__bridge id)kSecClass:          (__bridge id)kSecClassGenericPassword,
                             (__bridge id)kSecAttrAccessGroup: g,
                             (__bridge id)kSecMatchLimit:      (__bridge id)kSecMatchLimitOne };
        CFTypeRef r = NULL;
        OSStatus st = copy((__bridge CFDictionaryRef)q, &r);
        if (r) CFRelease(r);
        NSString *verdict;
        if (st == errSecMissingEntitlement) verdict = @"HORS D'ATTEINTE (-34018)";
        else if (st == errSecItemNotFound)  verdict = @"accessible, vide";
        else if (st == errSecSuccess)       verdict = @"accessible, non vide";
        else verdict = [NSString stringWithFormat:@"code %d", (int)st];
        [out addObject:[NSString stringWithFormat:@"%@ : %@", g, verdict]];
    }
    return [out componentsJoinedByString:@" | "];
}

+ (NSString *)refusalsDescription {
    NSUInteger all, ent; OSStatus last;
    @synchronized (VSKcLock()) { all = gRefusals; ent = gMissingEnt; last = gLastRefusal; }
    if (all == 0) return @"0 refus de securityd";
    return [NSString stringWithFormat:@"%lu refus dont %lu sans droit d'accès "
            @"(-34018) — dernier code %d", (unsigned long)all, (unsigned long)ent, (int)last];
}

@end





