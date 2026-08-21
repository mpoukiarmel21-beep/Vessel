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

/// A query that names no identity attribute cannot be scoped by prefixing — left
/// alone it would touch every container's rows. We enumerate all rows the query
/// matches, keep only the ones carrying our namespace, and hand back their
/// persistent refs; the broad paths below then address those rows one at a time,
/// so another container's rows are never read, updated, or deleted.
static NSArray *VSMatchingPersistentRefs(NSDictionary *query) {
    NSMutableDictionary *e = [query mutableCopy];
    [e removeObjectForKey:(__bridge id)kSecReturnData];
    [e removeObjectForKey:(__bridge id)kSecReturnRef];
    e[(__bridge id)kSecReturnAttributes]    = @YES;
    e[(__bridge id)kSecReturnPersistentRef] = @YES;
    e[(__bridge id)kSecMatchLimit]          = (__bridge id)kSecMatchLimitAll;
    // A match-all query defaults to non-synchronizable rows only. Instagram can
    // store a synchronizable (iCloud Keychain) session row; without this it would
    // be invisible to enumeration, so it could neither be scoped nor cleared and
    // would bleed across containers. "Any" covers both local and synchronizable.
    e[(__bridge id)kSecAttrSynchronizable]  = (__bridge id)kSecAttrSynchronizableAny;

    CFTypeRef out = NULL;
    OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)e, &out);
    NSArray *items = (__bridge_transfer NSArray *)out;
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
    // The ref may name a synchronizable row (see VSMatchingPersistentRefs); the
    // caller's query might not have opted into those, so make sure it can be read.
    q[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, out);
}

/// Match-all / single reads that named no identity attribute: fetch each of our
/// own rows by its persistent ref, so another container's rows can never appear
/// in the result. Each per-ref fetch returns the caller's exact shape, so the
/// assembled array is byte-for-byte what a real match-all would have produced.
static OSStatus VSBroadCopy(NSDictionary *query, CFTypeRef *result) {
    NSArray *refs = VSMatchingPersistentRefs(query);
    if (refs.count == 0) { if (result) *result = NULL; return errSecItemNotFound; }

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
    NSArray *refs = VSMatchingPersistentRefs(query);
    if (refs.count == 0) return errSecItemNotFound;
    OSStatus last = errSecSuccess;
    for (NSData *ref in refs) {
        OSStatus st = orig_SecItemDelete((__bridge CFDictionaryRef)
                        @{ (__bridge id)kSecValuePersistentRef: ref,
                           (__bridge id)kSecAttrSynchronizable:
                               (__bridge id)kSecAttrSynchronizableAny });
        if (st != errSecSuccess && st != errSecItemNotFound) last = st;
    }
    return last;
}

static OSStatus VSBroadUpdate(NSDictionary *query, NSDictionary *prefixedUpdate) {
    NSArray *refs = VSMatchingPersistentRefs(query);
    if (refs.count == 0) return errSecItemNotFound;
    OSStatus last = errSecSuccess;
    for (NSData *ref in refs) {
        OSStatus st = orig_SecItemUpdate((__bridge CFDictionaryRef)
                        @{ (__bridge id)kSecValuePersistentRef: ref,
                           (__bridge id)kSecAttrSynchronizable:
                               (__bridge id)kSecAttrSynchronizableAny },
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

@end





