//  VSHookCookies.m

#import "VSHookCookies.h"
#import "VSHookHome.h"
#import "../Core/VSStore.h"
#import "../Core/VSPaths.h"
#import "../Core/VSLog.h"
#import "../Core/VSWatchdog.h"
#import <objc/runtime.h>

static VSStore                                   *gStore     = nil;  // this container's cookie jar on disk
static NSMutableArray<NSHTTPCookie *>            *gJar       = nil;  // authoritative live jar, in memory
static NSMutableDictionary<NSString *, NSDate *> *gBorn      = nil;  // identity -> when we last stored it
static id                                         gShared    = nil;  // the one shared storage we intercept
static BOOL                                       gInstalled = NO;

static NSString *const kJarKey = @"jar";

/// One process-wide lock guarding gJar/gBorn. @synchronized is recursive per
/// thread, so a change-notification observer that re-enters -cookies on the same
/// thread cannot deadlock; we still post notifications OUTSIDE the lock so a
/// cross-thread observer never blocks on us mid-mutation.
static id VSJarLock(void) {
    static id t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSObject new]; });
    return t;
}

#pragma mark - Cookie identity & matching

/// A cookie's identity for replace/delete is the RFC triple name+domain+path —
/// setting "the same" cookie replaces in place, exactly as a real jar does.
static NSString *VSCookieKey(NSHTTPCookie *c) {
    return [NSString stringWithFormat:@"%@\n%@\n%@",
            c.name ?: @"", (c.domain ?: @"").lowercaseString, c.path.length ? c.path : @"/"];
}

static BOOL VSCookieExpired(NSHTTPCookie *c) {
    NSDate *exp = c.expiresDate;             // session cookies have none and never expire here
    return exp != nil && exp.timeIntervalSinceNow < 0;
}

/// Host matches either the exact domain (leading dot ignored) or any subdomain of
/// it — the standard cookie domain rule.
static BOOL VSCookieDomainMatches(NSString *cookieDomain, NSString *host) {
    if (cookieDomain.length == 0 || host.length == 0) return NO;
    cookieDomain = cookieDomain.lowercaseString;
    NSString *base = [cookieDomain hasPrefix:@"."] ? [cookieDomain substringFromIndex:1] : cookieDomain;
    if (base.length == 0) return NO;
    if ([host isEqualToString:base]) return YES;
    return [host hasSuffix:[@"." stringByAppendingString:base]];
}

/// url path is "under" the cookie path (with a segment boundary, so /foo does not
/// match /foobar). Empty cookie path defaults to "/".
static BOOL VSCookiePathMatches(NSString *cookiePath, NSString *urlPath) {
    if (cookiePath.length == 0) cookiePath = @"/";
    if (urlPath.length == 0)    urlPath    = @"/";
    if ([urlPath isEqualToString:cookiePath]) return YES;
    if (![urlPath hasPrefix:cookiePath]) return NO;
    if ([cookiePath hasSuffix:@"/"]) return YES;
    return [[urlPath substringFromIndex:cookiePath.length] hasPrefix:@"/"];
}

#pragma mark - Jar persistence (call under VSJarLock)

/// -[NSHTTPCookie properties] can carry an NSURL (NSHTTPCookieOriginURL), which is
/// NOT a property-list type — a single such value would make the whole jar array
/// fail to serialize and persist NOTHING, resurrecting "the session disappeared"
/// for cookies. So coerce NSURLs to strings and drop anything still non-plist; the
/// dropped keys are never identity-critical (name/value/domain/path/expiry all
/// serialize cleanly), and cookieWithProperties: accepts a string origin URL.
static NSDictionary *VSPlistSafeProps(NSDictionary *props) {
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:props.count];
    [props enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        if (![k isKindOfClass:NSString.class]) return;
        if ([v isKindOfClass:NSURL.class]) v = ((NSURL *)v).absoluteString;
        if (v && [NSPropertyListSerialization propertyList:v
                                          isValidForFormat:NSPropertyListBinaryFormat_v1_0])
            m[k] = v;
    }];
    return m;
}

/// Snapshot the live jar to disk as an array of { props, born } dictionaries. A
/// cookie's -properties is (once made plist-safe) a pure property-list, so VSStore
/// persists it as-is and rebuilds the exact cookie next launch — this is what
/// carries a container's session across a full app kill.
static void VSPersistLocked(void) {
    if (!gStore) return;
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:gJar.count];
    for (NSHTTPCookie *c in gJar) {
        NSDictionary *props = c.properties;
        if (![props isKindOfClass:NSDictionary.class]) continue;
        NSDate *born = gBorn[VSCookieKey(c)] ?: [NSDate date];
        [arr addObject:@{ @"props": VSPlistSafeProps(props),
                          @"born":  @(born.timeIntervalSince1970) }];
    }
    [gStore setObject:arr forKey:kJarKey];
}

static void VSLoadLocked(void) {
    id raw = [gStore objectForKey:kJarKey];
    if (![raw isKindOfClass:NSArray.class]) return;
    for (id e in (NSArray *)raw) {
        if (![e isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *props = ((NSDictionary *)e)[@"props"];
        if (![props isKindOfClass:NSDictionary.class]) continue;
        NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:props];
        if (!c || VSCookieExpired(c)) continue;
        NSString *key = VSCookieKey(c);
        [gJar addObject:c];
        id b = ((NSDictionary *)e)[@"born"];
        gBorn[key] = [b isKindOfClass:NSNumber.class]
                   ? [NSDate dateWithTimeIntervalSince1970:((NSNumber *)b).doubleValue]
                   : [NSDate date];
    }
}

#pragma mark - Jar mutation (call under VSJarLock)

static void VSRemoveKeyLocked(NSString *key) {
    NSMutableArray *dead = nil;
    for (NSHTTPCookie *c in gJar)
        if ([VSCookieKey(c) isEqualToString:key]) {
            if (!dead) dead = [NSMutableArray array];
            [dead addObject:c];
        }
    if (dead) [gJar removeObjectsInArray:dead];
    [gBorn removeObjectForKey:key];
}

static void VSAddCookieLocked(NSHTTPCookie *cookie) {
    NSString *key = VSCookieKey(cookie);
    VSRemoveKeyLocked(key);                 // replace-or-add by identity
    if (VSCookieExpired(cookie)) return;    // setting an already-expired cookie IS a delete
    [gJar addObject:cookie];
    gBorn[key] = [NSDate date];
}

/// Prune expired cookies lazily on read, persisting if anything was dropped, so a
/// stale sessionid never leaks back to Instagram after its own expiry.
static NSArray<NSHTTPCookie *> *VSLiveCookiesLocked(void) {
    NSMutableArray *dead = nil;
    for (NSHTTPCookie *c in gJar)
        if (VSCookieExpired(c)) { if (!dead) dead = [NSMutableArray array]; [dead addObject:c]; }
    if (dead) {
        for (NSHTTPCookie *c in dead) VSRemoveKeyLocked(VSCookieKey(c));
        VSPersistLocked();
    }
    return gJar;
}

static void VSPostChanged(void) {
    [NSNotificationCenter.defaultCenter
        postNotificationName:NSHTTPCookieManagerCookiesChangedNotification object:gShared];
}

#pragma mark - Swizzled replacements (only ever fire for gShared)

static NSArray *(*orig_cookies)(id, SEL)                                 = NULL;
static NSArray *(*orig_cookiesForURL)(id, SEL, NSURL *)                  = NULL;
static void     (*orig_setCookie)(id, SEL, NSHTTPCookie *)               = NULL;
static void     (*orig_setCookies)(id, SEL, NSArray *, NSURL *, NSURL *) = NULL;
static void     (*orig_deleteCookie)(id, SEL, NSHTTPCookie *)            = NULL;
static void     (*orig_removeSince)(id, SEL, NSDate *)                   = NULL;
static NSArray *(*orig_sortedCookies)(id, SEL, NSArray *)                = NULL;

#pragma mark - Coherence with the network stack (the CF-level store)

/// THE bug this layer had, and the reason a signup step could hang forever.
///
/// Instagram reads cookies through the ObjC NSHTTPCookieStorage API — which is
/// what the swizzles below intercept. CFNetwork does NOT: it absorbs Set-Cookie
/// and builds the outgoing Cookie: header through the CF-level storage underneath
/// NSHTTPCookieStorage, and never calls -setCookies:forURL:mainDocumentURL:. So a
/// jar that only shadows the ObjC surface produces two disjoint views of the same
/// session:
///
///   * the server's csrftoken (set by /api/v1/si/fetch_headers/ at launch) lands
///     in the CF store, where the app cannot see it;
///   * the app reads -cookies / -cookiesForURL:, gets OUR jar, finds no csrftoken,
///     and sends the next signed POST with an empty X-CSRFToken;
///   * Instagram refuses that POST. The full-name step's "Suivant" calls
///     /api/v1/accounts/username_suggestions/, gets a 403, and the coordinator
///     simply does not advance — responsive UI, no error, no crash, forever.
///
/// It also explains why the on-device self-test kept passing 26/26: +firstLeak
/// wrote with -setCookie: and read with -cookies, i.e. it round-tripped entirely
/// inside the shadow jar and never once involved CFNetwork.
///
/// The jar is therefore no longer a shadow. It is a persistent overlay kept
/// coherent with the real store in BOTH directions: reads absorb whatever the
/// network stack has written since the last read, writes are mirrored down so the
/// network stack actually sends them. Isolation is unaffected — the real store is
/// wiped and re-seeded from this container's jar at install (see below), and its
/// own backing file already lives inside the redirected HOME.
static NSArray<NSHTTPCookie *> *VSRealCookies(void) {
    if (!orig_cookies || !gShared) return @[];
    NSArray *a = orig_cookies(gShared, @selector(cookies));
    return [a isKindOfClass:NSArray.class] ? a : @[];
}

static void VSRealSet(NSHTTPCookie *c) {
    if (orig_setCookie && gShared && [c isKindOfClass:NSHTTPCookie.class])
        orig_setCookie(gShared, @selector(setCookie:), c);
}

static void VSRealDelete(NSHTTPCookie *c) {
    if (orig_deleteCookie && gShared && [c isKindOfClass:NSHTTPCookie.class])
        orig_deleteCookie(gShared, @selector(deleteCookie:), c);
}

/// Pull in anything the network stack stored that the jar does not have, or holds
/// with a stale value. Returns the NAMES of what was taken so the journal can show
/// it: a cookie name is a key name, never a credential, and it is the one piece of
/// information that makes this whole failure mode visible at all. Call under lock.
///
/// Indexed by key rather than a nested scan: this now runs on every -cookies /
/// -cookiesForURL: call, and Instagram issues those per request, so an O(jar × real)
/// walk that rebuilds a format string per comparison would turn a hot read path into
/// a measurable stall of its own — trading one hang for another.
static NSArray<NSString *> *VSAbsorbLocked(void) {
    NSArray<NSHTTPCookie *> *real = VSRealCookies();
    if (real.count == 0) return @[];

    NSMutableDictionary<NSString *, NSHTTPCookie *> *mine =
        [NSMutableDictionary dictionaryWithCapacity:gJar.count];
    for (NSHTTPCookie *c in gJar) mine[VSCookieKey(c)] = c;

    NSMutableArray<NSString *> *took = nil;
    for (NSHTTPCookie *r in real) {
        if (![r isKindOfClass:NSHTTPCookie.class] || VSCookieExpired(r)) continue;
        NSHTTPCookie *have = mine[VSCookieKey(r)];
        if (have && [(have.value ?: @"") isEqualToString:(r.value ?: @"")]) continue;
        VSAddCookieLocked(r);
        if (!took) took = [NSMutableArray array];
        [took addObject:r.name ?: @"?"];
    }
    if (took) VSPersistLocked();
    return took ?: @[];
}

/// Absorb, then log outside the lock so no observer can block us mid-mutation.
/// Silent when nothing changed, so the read path stays quiet in steady state.
static void VSSyncFromReal(void) {
    if (!gInstalled) return;
    NSArray<NSString *> *took;
    @synchronized (VSJarLock()) { took = VSAbsorbLocked(); }
    if (took.count)
        VSLogI(@"cookies", @"keys: absorbed %lu from the network stack — %@",
               (unsigned long)took.count, [took componentsJoinedByString:@", "]);
}

static NSArray *vs_cookies(id self_, SEL _cmd) {
    if (!gInstalled || self_ != gShared) return orig_cookies(self_, _cmd);
    VSSyncFromReal();
    NSArray *snapshot;
    @synchronized (VSJarLock()) { snapshot = [VSLiveCookiesLocked() copy]; }
    return snapshot;
}

static NSArray *vs_cookiesForURL(id self_, SEL _cmd, NSURL *url) {
    if (!gInstalled || self_ != gShared) return orig_cookiesForURL(self_, _cmd, url);
    if (![url isKindOfClass:NSURL.class]) return @[];
    VSSyncFromReal();
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path.length ? url.path : @"/";
    BOOL https = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSMutableArray *match = [NSMutableArray array];
    @synchronized (VSJarLock()) {
        for (NSHTTPCookie *c in VSLiveCookiesLocked()) {
            if (c.isSecure && !https) continue;
            if (!VSCookieDomainMatches(c.domain, host)) continue;
            if (!VSCookiePathMatches(c.path, path)) continue;
            [match addObject:c];
        }
    }
    [match sortUsingComparator:^NSComparisonResult(NSHTTPCookie *a, NSHTTPCookie *b) {
        return [@(b.path.length) compare:@(a.path.length)];   // more specific paths first
    }];
    return match;
}

// cookieAcceptPolicy is intentionally not consulted for the jar: the jar is private
// to this container, so there is no third party to protect against, and Instagram's
// API simply needs its own Set-Cookie to take effect. The mirror down to the real
// store is what lets CFNetwork put the cookie on the wire.
static void vs_setCookie(id self_, SEL _cmd, NSHTTPCookie *cookie) {
    if (!gInstalled || self_ != gShared) { orig_setCookie(self_, _cmd, cookie); return; }
    if (![cookie isKindOfClass:NSHTTPCookie.class]) return;
    VSMark("cookie:set");
    @synchronized (VSJarLock()) { VSAddCookieLocked(cookie); VSPersistLocked(); }
    VSRealSet(cookie);
    VSPostChanged();
    VSMark("cookie:set.done");
}

static void vs_setCookies(id self_, SEL _cmd, NSArray *cookies, NSURL *url, NSURL *mainDoc) {
    if (!gInstalled || self_ != gShared) { orig_setCookies(self_, _cmd, cookies, url, mainDoc); return; }
    if (![cookies isKindOfClass:NSArray.class]) return;
    VSMark("cookie:setMany");
    @synchronized (VSJarLock()) {
        for (NSHTTPCookie *c in cookies)
            if ([c isKindOfClass:NSHTTPCookie.class]) VSAddCookieLocked(c);
        VSPersistLocked();
    }
    for (NSHTTPCookie *c in cookies) VSRealSet(c);
    VSPostChanged();
    VSMark("cookie:setMany.done");
}

static void vs_deleteCookie(id self_, SEL _cmd, NSHTTPCookie *cookie) {
    if (!gInstalled || self_ != gShared) { orig_deleteCookie(self_, _cmd, cookie); return; }
    if (![cookie isKindOfClass:NSHTTPCookie.class]) return;
    @synchronized (VSJarLock()) { VSRemoveKeyLocked(VSCookieKey(cookie)); VSPersistLocked(); }
    VSRealDelete(cookie);
    VSPostChanged();
}

/// removeCookiesSinceDate: has no public per-cookie creation time, so we track our
/// own "born" stamp and drop everything stored at or after `date`. A nil/invalid
/// date, and the usual distantPast, clear the whole jar — the logout path. The same
/// cookies are removed from the real store, or the network stack would keep sending
/// a session the app believes it has just destroyed.
static void vs_removeSince(id self_, SEL _cmd, NSDate *date) {
    if (!gInstalled || self_ != gShared) { orig_removeSince(self_, _cmd, date); return; }
    if (![date isKindOfClass:NSDate.class]) date = NSDate.distantPast;
    NSMutableArray<NSHTTPCookie *> *dead = [NSMutableArray array];
    @synchronized (VSJarLock()) {
        for (NSHTTPCookie *c in gJar) {
            NSDate *born = gBorn[VSCookieKey(c)] ?: NSDate.distantPast;
            if ([born compare:date] != NSOrderedAscending) [dead addObject:c];   // born >= date
        }
        for (NSHTTPCookie *c in dead) VSRemoveKeyLocked(VSCookieKey(c));
        VSPersistLocked();
    }
    for (NSHTTPCookie *c in dead) VSRealDelete(c);
    VSPostChanged();
}

static NSArray *vs_sortedCookies(id self_, SEL _cmd, NSArray *descriptors) {
    if (!gInstalled || self_ != gShared) return orig_sortedCookies(self_, _cmd, descriptors);
    VSSyncFromReal();
    NSArray *live;
    @synchronized (VSJarLock()) { live = [VSLiveCookiesLocked() copy]; }
    return ([descriptors isKindOfClass:NSArray.class] && descriptors.count)
         ? [live sortedArrayUsingDescriptors:descriptors] : live;
}

#pragma mark - Install

static BOOL VSSwizzle(Class cls, SEL sel, void *repl, void **outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}

@implementation VSHookCookies

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installForContainerID:(NSString *)cid {
    if (gInstalled) return YES;
    if (cid.length == 0) { VSLogE(@"cookies", @"refusing to install: empty cid"); return NO; }

    // The shared storage is a singleton; grab it once and gate every replacement on
    // pointer identity, so ephemeral and custom storages keep their own behaviour.
    gShared = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    if (!gShared) { VSLogE(@"cookies", @"refusing to install: no shared cookie storage"); return NO; }

    NSString *path = [[VSPaths privateDirForContainerID:cid]
                      stringByAppendingPathComponent:@"cookies.plist"];
    gStore = [[VSStore alloc] initWithPath:path label:@"cookies"];
    gJar   = [NSMutableArray array];
    gBorn  = [NSMutableDictionary dictionary];
    @synchronized (VSJarLock()) { VSLoadLocked(); }

    // A fast kill must not drop the last Set-Cookie: flush on background/terminate.
    [gStore attachLifecycleFlush];

    Class cls = object_getClass(gShared);
    struct { SEL sel; void *repl; void **orig; const char *name; } sw[] = {
        { @selector(cookies),                            (void *)vs_cookies,       (void **)&orig_cookies,       "cookies" },
        { @selector(cookiesForURL:),                     (void *)vs_cookiesForURL, (void **)&orig_cookiesForURL, "cookiesForURL:" },
        { @selector(setCookie:),                         (void *)vs_setCookie,     (void **)&orig_setCookie,     "setCookie:" },
        { @selector(setCookies:forURL:mainDocumentURL:), (void *)vs_setCookies,    (void **)&orig_setCookies,    "setCookies:forURL:mainDocumentURL:" },
        { @selector(deleteCookie:),                      (void *)vs_deleteCookie,  (void **)&orig_deleteCookie,  "deleteCookie:" },
        { @selector(removeCookiesSinceDate:),            (void *)vs_removeSince,   (void **)&orig_removeSince,   "removeCookiesSinceDate:" },
        { @selector(sortedCookiesUsingDescriptors:),     (void *)vs_sortedCookies, (void **)&orig_sortedCookies, "sortedCookiesUsingDescriptors:" },
    };
    int miss = 0;
    for (size_t i = 0; i < sizeof(sw) / sizeof(sw[0]); i++)
        if (!VSSwizzle(cls, sw[i].sel, sw[i].repl, sw[i].orig)) {
            VSLogW(@"cookies", @"swizzle miss: -[%@ %s]", NSStringFromClass(cls), sw[i].name);
            miss++;
        }

    // The real store must accept what we mirror into it, or the network stack would
    // keep sending a session the app thinks it has. The shared storage defaults to
    // Always, but a previous run of the app can have changed it.
    if ([gShared respondsToSelector:@selector(setCookieAcceptPolicy:)])
        [(NSHTTPCookieStorage *)gShared setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];

    // Reconcile the two views ONCE, now, before Instagram issues its first request.
    // Absorb first and prune nothing: the real store's backing file lives at
    // <HOME>/Library/Cookies, i.e. already inside this container thanks to layer 1,
    // so what it holds is this container's own session from the previous run and
    // dropping it would be the "my session disappeared" bug all over again. That
    // placement is not assumed — +firstLeak proves it physically below, and reports
    // a failure if the file ever turns up outside the container.
    NSUInteger absorbed = 0, seeded = 0;
    @synchronized (VSJarLock()) {
        absorbed = VSAbsorbLocked().count;
        NSArray<NSHTTPCookie *> *real = VSRealCookies();
        NSMutableSet<NSString *> *have = [NSMutableSet setWithCapacity:real.count];
        for (NSHTTPCookie *c in real)
            if ([c isKindOfClass:NSHTTPCookie.class]) [have addObject:VSCookieKey(c)];
        for (NSHTTPCookie *c in gJar)
            if (![have containsObject:VSCookieKey(c)]) { VSRealSet(c); seeded++; }
    }

    gInstalled = YES;
    VSLogI(@"cookies", @"keys: isolated -> %@ (%lu loaded, %lu absorbed, %lu seeded, %d selector miss)",
           path, (unsigned long)gJar.count, (unsigned long)absorbed,
           (unsigned long)seeded, miss);
    return YES;
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"layer 4 not installed";

    NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    NSString *host  = @"selftest.vessel.local";
    NSString *name  = [@"vsSelfTest" stringByAppendingString:
                       [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSString *value = NSUUID.UUID.UUIDString;
    NSHTTPCookie *probe = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName:    name,
        NSHTTPCookieValue:   value,
        NSHTTPCookieDomain:  host,
        NSHTTPCookiePath:    @"/",
        NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:3600],
    }];
    if (!probe) return @"could not build probe cookie";

    [storage setCookie:probe];
    [gStore flushNow];

    // Visible through -cookies …
    BOOL seen = NO;
    for (NSHTTPCookie *c in storage.cookies)
        if ([c.name isEqualToString:name] && [c.value isEqualToString:value]) { seen = YES; break; }
    if (!seen) { [storage deleteCookie:probe]; return @"cookie not visible through -cookies after setCookie:"; }

    // … and routed to its domain through -cookiesForURL: …
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/", host]];
    seen = NO;
    for (NSHTTPCookie *c in [storage cookiesForURL:url])
        if ([c.name isEqualToString:name]) { seen = YES; break; }
    if (!seen) { [storage deleteCookie:probe]; return @"cookie not returned by -cookiesForURL: for its domain"; }

    // Physical proof: it is in THIS container's jar on disk, never the shared store.
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:gStore.path];
    NSArray *jar = [onDisk[kJarKey] isKindOfClass:NSArray.class] ? onDisk[kJarKey] : nil;
    BOOL landed = NO;
    for (id e in jar) {
        NSDictionary *props = [e isKindOfClass:NSDictionary.class] ? ((NSDictionary *)e)[@"props"] : nil;
        if ([props isKindOfClass:NSDictionary.class] && [props[NSHTTPCookieName] isEqual:name]) { landed = YES; break; }
    }
    if (!landed) {
        [storage deleteCookie:probe]; [gStore flushNow];
        return [NSString stringWithFormat:@"cookie did not land in the container jar at %@", gStore.path];
    }

    // A delete must actually clear it.
    [storage deleteCookie:probe];
    [gStore flushNow];
    for (NSHTTPCookie *c in storage.cookies)
        if ([c.name isEqualToString:name]) return @"cookie still present after deleteCookie:";

    return [self coherenceLeak];
}

/// The two checks the old self-test was missing, and the reason it could report
/// 26/26 while signup was broken: everything above writes AND reads through the
/// same ObjC surface, so it round-trips inside our own jar without ever involving
/// the store CFNetwork uses. These two cross the boundary in both directions.
+ (NSString *)coherenceLeak {
    if (!gInstalled) return @"layer 4 not installed";
    if (!orig_setCookie || !orig_cookies || !orig_deleteCookie)
        return @"cookie originals unavailable — cannot verify network-stack coherence";

    NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    NSString *host = @"selftest.vessel.local";

    // 1. app -> network stack. What Instagram sets through NSHTTPCookieStorage must
    //    reach the real store, or CFNetwork never puts it on the wire.
    NSString *downName = [@"vsDown" stringByAppendingString:
                          [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSHTTPCookie *down = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName: downName, NSHTTPCookieValue: @"1",
        NSHTTPCookieDomain: host,   NSHTTPCookiePath: @"/",
        NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:600] }];
    if (!down) return @"could not build the downward probe cookie";
    [storage setCookie:down];
    BOOL mirrored = NO;
    for (NSHTTPCookie *c in VSRealCookies())
        if ([c.name isEqualToString:downName]) { mirrored = YES; break; }
    [storage deleteCookie:down];
    if (!mirrored)
        return @"a cookie set by the app never reached the store CFNetwork sends from";

    // 2. network stack -> app. THE one that matters for signup: the server's
    //    csrftoken arrives this way (CFNetwork absorbs Set-Cookie without going
    //    through any ObjC method), and Instagram then reads it back through
    //    -cookies to build X-CSRFToken. If this direction is broken, every signed
    //    POST goes out unauthenticated and the step it belongs to never advances.
    NSString *upName = [@"vsUp" stringByAppendingString:
                        [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSHTTPCookie *up = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName: upName,  NSHTTPCookieValue: @"1",
        NSHTTPCookieDomain: host,  NSHTTPCookiePath: @"/",
        NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:600] }];
    if (!up) return @"could not build the upward probe cookie";
    VSRealSet(up);                                  // exactly what CFNetwork does
    BOOL visible = NO;
    for (NSHTTPCookie *c in storage.cookies)        // exactly what Instagram does
        if ([c.name isEqualToString:upName]) { visible = YES; break; }
    [storage deleteCookie:up];
    VSRealDelete(up);
    [gStore flushNow];
    if (!visible)
        return @"a cookie stored by the network stack is invisible to the app "
               @"(this is what breaks X-CSRFToken and stalls a signup step)";

    return nil;
}

/// Where each side of the cookie state actually lives, for the journal. Paths only —
/// no names, no values. Layer 1 should have put the CF store's own file inside the
/// container; if it turns up in the real home instead, cookies are shared between
/// containers even though the app-facing jar is not.
+ (NSString *)storagePlacementDescription {
    NSString *rel = @"Library/Cookies/Cookies.binarycookies";
    NSString *inContainer = [[VSHookHome containerRoot] stringByAppendingPathComponent:rel];
    NSString *inRealHome  = [[VSPaths realHome] stringByAppendingPathComponent:rel];
    NSFileManager *fm = NSFileManager.defaultManager;
    return [NSString stringWithFormat:@"CF cookie file: container=%@ realHome=%@",
            [fm fileExistsAtPath:inContainer] ? @"present" : @"absent",
            [fm fileExistsAtPath:inRealHome]  ? @"PRESENT (shared!)" : @"absent"];
}

@end
