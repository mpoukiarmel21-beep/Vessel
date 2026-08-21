//  VSHookDefaults.m

#import "VSHookDefaults.h"
#import "../Core/VSStore.h"
#import "../Core/VSPaths.h"
#import "../Core/VSLog.h"
#import "../vendor/fishhook/fishhook.h"
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

static VSStore  *gStore     = nil;   // this container's private preferences
static NSString *gAppID     = nil;   // this process's bundle id, for CF scoping
static BOOL      gInstalled = NO;

#pragma mark - Tombstones & store policy

/// A removed key is stored as this sentinel rather than deleted, so a read finds
/// it, returns nil, and does NOT fall through to the shared plist — a remove that
/// silently un-did itself on the next launch would look like state resurrecting.
static NSDictionary *VSTomb(void) {
    static NSDictionary *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = @{ @"__vsTombstone__": @1 }; });
    return t;
}
static BOOL VSIsTomb(id v) {
    return [v isKindOfClass:NSDictionary.class] &&
           ((NSDictionary *)v)[@"__vsTombstone__"] != nil;
}

/// The read half of the policy. YES means the store answers `key` authoritatively
/// (a real value, or nil for a tombstone) and the caller must NOT consult the real
/// defaults; NO means fall back so registration/global-domain keys still resolve.
static BOOL VSStoreAnswer(NSString *key, id *out) {
    if (!gInstalled || key.length == 0) return NO;
    BOOL found = NO;
    id v = [gStore objectForKey:key found:&found];   // one queue hop, not two
    if (!found) return NO;
    *out = VSIsTomb(v) ? nil : v;
    return YES;
}

/// The write half: everything lands in this container's store and nowhere else.
/// A nil value becomes a tombstone, never a shared-plist delete.
static void VSStorePut(NSString *key, id value) {
    if (!gInstalled || key.length == 0) return;
    [gStore setObject:(value ?: (id)VSTomb()) forKey:key];
}

#pragma mark - NSUserDefaults replacements (reads)

static id       (*orig_objectForKey)(id, SEL, NSString *)      = NULL;
static NSString *(*orig_stringForKey)(id, SEL, NSString *)     = NULL;
static NSArray  *(*orig_arrayForKey)(id, SEL, NSString *)      = NULL;
static NSDictionary *(*orig_dictionaryForKey)(id, SEL, NSString *) = NULL;
static NSData   *(*orig_dataForKey)(id, SEL, NSString *)       = NULL;
static NSArray  *(*orig_stringArrayForKey)(id, SEL, NSString *) = NULL;
static NSInteger (*orig_integerForKey)(id, SEL, NSString *)    = NULL;
static float    (*orig_floatForKey)(id, SEL, NSString *)       = NULL;
static double   (*orig_doubleForKey)(id, SEL, NSString *)      = NULL;
static BOOL     (*orig_boolForKey)(id, SEL, NSString *)        = NULL;
static NSURL    *(*orig_URLForKey)(id, SEL, NSString *)        = NULL;

static id vs_objectForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) return v;
    return orig_objectForKey(s, c, key);
}
static NSString *vs_stringForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) {
        if ([v isKindOfClass:NSString.class]) return v;
        if ([v isKindOfClass:NSNumber.class]) return ((NSNumber *)v).stringValue;
        return nil;
    }
    return orig_stringForKey(s, c, key);
}
static NSArray *vs_arrayForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) return [v isKindOfClass:NSArray.class] ? v : nil;
    return orig_arrayForKey(s, c, key);
}
static NSDictionary *vs_dictionaryForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) return [v isKindOfClass:NSDictionary.class] ? v : nil;
    return orig_dictionaryForKey(s, c, key);
}
static NSData *vs_dataForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) return [v isKindOfClass:NSData.class] ? v : nil;
    return orig_dataForKey(s, c, key);
}
static NSArray *vs_stringArrayForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) {
        if (![v isKindOfClass:NSArray.class]) return nil;
        for (id e in (NSArray *)v) if (![e isKindOfClass:NSString.class]) return nil;
        return v;
    }
    return orig_stringArrayForKey(s, c, key);
}

static NSInteger vs_integerForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v))
        return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
    return orig_integerForKey(s, c, key);
}
static float vs_floatForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v))
        return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0;
    return orig_floatForKey(s, c, key);
}
static double vs_doubleForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v))
        return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
    return orig_doubleForKey(s, c, key);
}
static BOOL vs_boolForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v))
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
    return orig_boolForKey(s, c, key);
}

/// URLs are stored as a keyed archive, the same opaque shape Apple persists, so a
/// caller reading the key back as an object sees data either way.
static NSURL *vs_URLForKey(id s, SEL c, NSString *key) {
    id v; if (VSStoreAnswer(key, &v)) {
        if (![v isKindOfClass:NSData.class]) return nil;
        return [NSKeyedUnarchiver unarchivedObjectOfClass:NSURL.class fromData:v error:NULL];
    }
    return orig_URLForKey(s, c, key);
}

#pragma mark - NSUserDefaults replacements (writes)

static void (*orig_setObjectForKey)(id, SEL, id, NSString *)  = NULL;
static void (*orig_setInteger)(id, SEL, NSInteger, NSString *) = NULL;
static void (*orig_setFloat)(id, SEL, float, NSString *)      = NULL;
static void (*orig_setDouble)(id, SEL, double, NSString *)    = NULL;
static void (*orig_setBool)(id, SEL, BOOL, NSString *)        = NULL;
static void (*orig_setURL)(id, SEL, NSURL *, NSString *)      = NULL;
static void (*orig_removeObjectForKey)(id, SEL, NSString *)   = NULL;
static BOOL (*orig_synchronize)(id, SEL)                      = NULL;
static NSDictionary *(*orig_dictRep)(id, SEL)                 = NULL;

static void vs_setObjectForKey(id s, SEL c, id value, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setObjectForKey(s, c, value, key); return; }
    VSStorePut(key, value);
}
static void vs_setInteger(id s, SEL c, NSInteger val, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setInteger(s, c, val, key); return; }
    VSStorePut(key, @(val));
}

static void vs_setFloat(id s, SEL c, float val, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setFloat(s, c, val, key); return; }
    VSStorePut(key, @(val));
}
static void vs_setDouble(id s, SEL c, double val, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setDouble(s, c, val, key); return; }
    VSStorePut(key, @(val));
}
static void vs_setBool(id s, SEL c, BOOL val, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setBool(s, c, val, key); return; }
    VSStorePut(key, @(val));
}
static void vs_setURL(id s, SEL c, NSURL *url, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_setURL(s, c, url, key); return; }
    NSData *d = url ? [NSKeyedArchiver archivedDataWithRootObject:url
                                           requiringSecureCoding:YES error:NULL] : nil;
    VSStorePut(key, d);   // nil (archive failed or nil url) → tombstone
}
static void vs_removeObjectForKey(id s, SEL c, NSString *key) {
    if (!gInstalled || key.length == 0) { orig_removeObjectForKey(s, c, key); return; }
    VSStorePut(key, nil);   // tombstone
}
static BOOL vs_synchronize(id s, SEL c) {
    if (gInstalled) [gStore flushNow];
    return orig_synchronize(s, c);
}

/// The merged view must reflect our overrides or code that reads one key with
/// -objectForKey: and the rest with -dictionaryRepresentation would see two
/// different worlds. Tombstoned keys are subtracted.
static NSDictionary *vs_dictRep(id s, SEL c) {
    NSDictionary *base = orig_dictRep(s, c) ?: @{};
    if (!gInstalled) return base;
    NSMutableDictionary *m = [base mutableCopy];
    NSDictionary *ours = [gStore allValues];
    for (NSString *k in ours) {
        id v = ours[k];
        if (VSIsTomb(v)) [m removeObjectForKey:k]; else m[k] = v;
    }
    return m;
}

#pragma mark - CFPreferences replacements (direct C callers)

static CFPropertyListRef (*orig_CFPrefCopyAppValue)(CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPrefSetAppValue)(CFStringRef, CFPropertyListRef, CFStringRef) = NULL;
static Boolean (*orig_CFPrefAppSync)(CFStringRef) = NULL;
static CFPropertyListRef (*orig_CFPrefCopyValue)(CFStringRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPrefSetValue)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static CFArrayRef (*orig_CFPrefCopyKeyList)(CFStringRef, CFStringRef, CFStringRef) = NULL;
static Boolean (*orig_CFPrefSync)(CFStringRef, CFStringRef, CFStringRef) = NULL;

/// Only this app's own preferences are ours to isolate. kCFPreferencesCurrentApplication
/// and the literal bundle id both mean "us"; kCFPreferencesAnyApplication and any other
/// id name shared or system domains and are passed straight through.
static BOOL VSIsOurApp(CFStringRef applicationID) {
    if (applicationID == NULL) return NO;
    if (applicationID == kCFPreferencesCurrentApplication) return YES;
    NSString *a = (__bridge NSString *)applicationID;
    return gAppID.length > 0 && [a isEqualToString:gAppID];
}

static CFPropertyListRef vs_CFPrefCopyAppValue(CFStringRef key, CFStringRef appID) {
    if (gInstalled && key && VSIsOurApp(appID)) {
        id v; if (VSStoreAnswer((__bridge NSString *)key, &v))
            return v ? CFBridgingRetain(v) : NULL;   // Copy semantics: +1 or NULL
    }
    return orig_CFPrefCopyAppValue(key, appID);
}
static void vs_CFPrefSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef appID) {
    if (gInstalled && key && VSIsOurApp(appID)) {
        VSStorePut((__bridge NSString *)key, value ? (__bridge id)value : nil);
        return;
    }
    orig_CFPrefSetAppValue(key, value, appID);
}
static CFPropertyListRef vs_CFPrefCopyValue(CFStringRef key, CFStringRef appID,
                                            CFStringRef user, CFStringRef host) {
    if (gInstalled && key && VSIsOurApp(appID)) {
        id v; if (VSStoreAnswer((__bridge NSString *)key, &v))
            return v ? CFBridgingRetain(v) : NULL;
    }
    return orig_CFPrefCopyValue(key, appID, user, host);
}
static void vs_CFPrefSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef appID,
                              CFStringRef user, CFStringRef host) {
    if (gInstalled && key && VSIsOurApp(appID)) {
        VSStorePut((__bridge NSString *)key, value ? (__bridge id)value : nil);
        return;
    }
    orig_CFPrefSetValue(key, value, appID, user, host);
}

/// Merge our keys over the real key list rather than replacing it: a caller that
/// enumerates keys and then copies each value must still see the shared/registration
/// keys it never wrote, minus anything this container has tombstoned.
static CFArrayRef vs_CFPrefCopyKeyList(CFStringRef appID, CFStringRef user, CFStringRef host) {
    if (gInstalled && VSIsOurApp(appID)) {
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
        CFArrayRef base = orig_CFPrefCopyKeyList(appID, user, host);
        if (base) { [set addObjectsFromArray:(__bridge NSArray *)base]; CFRelease(base); }
        NSDictionary *ours = [gStore allValues];
        for (NSString *k in ours) {
            if (VSIsTomb(ours[k])) [set removeObject:k]; else [set addObject:k];
        }
        return CFBridgingRetain([set array]);
    }
    return orig_CFPrefCopyKeyList(appID, user, host);
}
static Boolean vs_CFPrefAppSync(CFStringRef appID) {
    if (gInstalled && VSIsOurApp(appID)) [gStore flushNow];
    return orig_CFPrefAppSync(appID);
}
static Boolean vs_CFPrefSync(CFStringRef appID, CFStringRef user, CFStringRef host) {
    if (gInstalled && VSIsOurApp(appID)) [gStore flushNow];
    return orig_CFPrefSync(appID, user, host);
}

#pragma mark - Install

/// method_setImplementation, like the other layers: swap the IMP in place, keep
/// the original callable through a function pointer, and add no selector Instagram
/// could enumerate. A missing selector is a warning, not a refusal — the rest of
/// the accessors still isolate.
static BOOL VSSwizzle(Class cls, SEL sel, void *repl, void **outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}

@implementation VSHookDefaults

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installForContainerID:(NSString *)cid {
    if (gInstalled) return YES;
    if (cid.length == 0) { VSLogE(@"defaults", @"refusing to install: empty cid"); return NO; }

    NSString *path = [[VSPaths privateDirForContainerID:cid]
                      stringByAppendingPathComponent:@"defaults.plist"];
    gStore = [[VSStore alloc] initWithPath:path label:@"defaults"];
    gAppID = [[NSBundle mainBundle].bundleIdentifier copy] ?: @"";

    // A fast kill must not lose the last write — this is the same failure the
    // keychain and the store fix, seen through the preferences plist.
    [gStore attachLifecycleFlush];

    // --- NSUserDefaults: the backbone. Independent per-selector; a miss warns. ---
    Class ud = NSUserDefaults.class;
    struct { SEL sel; void *repl; void **orig; const char *name; } sw[] = {
        { @selector(objectForKey:),        (void *)vs_objectForKey,      (void **)&orig_objectForKey,      "objectForKey:" },
        { @selector(stringForKey:),        (void *)vs_stringForKey,      (void **)&orig_stringForKey,      "stringForKey:" },
        { @selector(arrayForKey:),         (void *)vs_arrayForKey,       (void **)&orig_arrayForKey,       "arrayForKey:" },
        { @selector(dictionaryForKey:),    (void *)vs_dictionaryForKey,  (void **)&orig_dictionaryForKey,  "dictionaryForKey:" },
        { @selector(dataForKey:),          (void *)vs_dataForKey,        (void **)&orig_dataForKey,        "dataForKey:" },
        { @selector(stringArrayForKey:),   (void *)vs_stringArrayForKey, (void **)&orig_stringArrayForKey, "stringArrayForKey:" },
        { @selector(integerForKey:),       (void *)vs_integerForKey,     (void **)&orig_integerForKey,     "integerForKey:" },
        { @selector(floatForKey:),         (void *)vs_floatForKey,       (void **)&orig_floatForKey,       "floatForKey:" },
        { @selector(doubleForKey:),        (void *)vs_doubleForKey,      (void **)&orig_doubleForKey,      "doubleForKey:" },
        { @selector(boolForKey:),          (void *)vs_boolForKey,        (void **)&orig_boolForKey,        "boolForKey:" },
        { @selector(URLForKey:),           (void *)vs_URLForKey,         (void **)&orig_URLForKey,         "URLForKey:" },
        { @selector(setObject:forKey:),    (void *)vs_setObjectForKey,   (void **)&orig_setObjectForKey,   "setObject:forKey:" },
        { @selector(setInteger:forKey:),   (void *)vs_setInteger,        (void **)&orig_setInteger,        "setInteger:forKey:" },
        { @selector(setFloat:forKey:),     (void *)vs_setFloat,          (void **)&orig_setFloat,          "setFloat:forKey:" },
        { @selector(setDouble:forKey:),    (void *)vs_setDouble,         (void **)&orig_setDouble,         "setDouble:forKey:" },
        { @selector(setBool:forKey:),      (void *)vs_setBool,           (void **)&orig_setBool,           "setBool:forKey:" },
        { @selector(setURL:forKey:),       (void *)vs_setURL,            (void **)&orig_setURL,            "setURL:forKey:" },
        { @selector(removeObjectForKey:),  (void *)vs_removeObjectForKey,(void **)&orig_removeObjectForKey,"removeObjectForKey:" },
        { @selector(synchronize),          (void *)vs_synchronize,       (void **)&orig_synchronize,       "synchronize" },
        { @selector(dictionaryRepresentation), (void *)vs_dictRep,       (void **)&orig_dictRep,           "dictionaryRepresentation" },
    };
    int miss = 0;
    for (size_t i = 0; i < sizeof(sw) / sizeof(sw[0]); i++)
        if (!VSSwizzle(ud, sw[i].sel, sw[i].repl, sw[i].orig)) {
            VSLogW(@"defaults", @"swizzle miss: -[NSUserDefaults %s]", sw[i].name);
            miss++;
        }

    // --- CFPreferences: best-effort. Resolve every original first (a rebinding
    //     whose original stayed NULL would crash a direct C caller), and only
    //     rebind as a set. If any symbol is missing we skip the C family entirely
    //     and lean on the NSUserDefaults swizzles above, which already cover the
    //     paths Instagram actually uses. ---
    orig_CFPrefCopyAppValue = (CFPropertyListRef (*)(CFStringRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesCopyAppValue");
    orig_CFPrefSetAppValue  = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesSetAppValue");
    orig_CFPrefAppSync      = (Boolean (*)(CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesAppSynchronize");
    orig_CFPrefCopyValue    = (CFPropertyListRef (*)(CFStringRef, CFStringRef, CFStringRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesCopyValue");
    orig_CFPrefSetValue     = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesSetValue");
    orig_CFPrefCopyKeyList  = (CFArrayRef (*)(CFStringRef, CFStringRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesCopyKeyList");
    orig_CFPrefSync         = (Boolean (*)(CFStringRef, CFStringRef, CFStringRef))
        dlsym(RTLD_DEFAULT, "CFPreferencesSynchronize");

    if (orig_CFPrefCopyAppValue && orig_CFPrefSetAppValue && orig_CFPrefAppSync &&
        orig_CFPrefCopyValue && orig_CFPrefSetValue && orig_CFPrefCopyKeyList && orig_CFPrefSync) {
        struct rebinding rb[] = {
            { "CFPreferencesCopyAppValue",   (void *)vs_CFPrefCopyAppValue, (void **)&orig_CFPrefCopyAppValue },
            { "CFPreferencesSetAppValue",    (void *)vs_CFPrefSetAppValue,  (void **)&orig_CFPrefSetAppValue },
            { "CFPreferencesAppSynchronize", (void *)vs_CFPrefAppSync,      (void **)&orig_CFPrefAppSync },
            { "CFPreferencesCopyValue",      (void *)vs_CFPrefCopyValue,    (void **)&orig_CFPrefCopyValue },
            { "CFPreferencesSetValue",       (void *)vs_CFPrefSetValue,     (void **)&orig_CFPrefSetValue },
            { "CFPreferencesCopyKeyList",    (void *)vs_CFPrefCopyKeyList,  (void **)&orig_CFPrefCopyKeyList },
            { "CFPreferencesSynchronize",    (void *)vs_CFPrefSync,         (void **)&orig_CFPrefSync },
        };
        int rc = rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
        if (rc != 0) VSLogW(@"defaults", @"CFPreferences rebind_symbols returned %d", rc);
    } else {
        VSLogW(@"defaults", @"CFPreferences dlsym miss — C family not rebound, "
                            @"NSUserDefaults isolation still active");
    }

    gInstalled = YES;
    VSLogI(@"defaults", @"isolated -> %@ (%d selector miss, app=%@)", path, miss, gAppID);
    return YES;
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"layer 3 not installed";

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = [@"com.vessel.selftest." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *val = NSUUID.UUID.UUIDString;

    // Write through the public API, then prove it round-trips.
    [ud setObject:val forKey:key];
    [gStore flushNow];
    if (![[ud stringForKey:key] isEqualToString:val])
        return @"read-back through NSUserDefaults did not return the written value";

    // Physical proof: the value must be in THIS container's private store on disk
    // (read independently), which is precisely how we know it did NOT go to the
    // shared cfprefsd plist every container would otherwise share.
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:gStore.path];
    if (![onDisk[key] isEqual:val])
        return [NSString stringWithFormat:@"value did not land in the container store at %@",
                gStore.path];

    // A remove must stick against any shared baseline (tombstone), not read back.
    [ud removeObjectForKey:key];
    [gStore flushNow];
    if ([ud objectForKey:key] != nil)
        return @"key still readable after removeObjectForKey:";

    // Cleanup: hard-drop the probe key so the store never accumulates test rows.
    [gStore removeObjectForKey:key];
    [gStore flushNow];
    return nil;
}

@end


