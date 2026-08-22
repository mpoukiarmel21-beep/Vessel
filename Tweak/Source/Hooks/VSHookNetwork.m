//  VSHookNetwork.m — see the header. Log-only; every replacement calls the original.

#import "VSHookNetwork.h"
#import "../Core/VSLog.h"
#import <objc/runtime.h>

static BOOL gInstalled = NO;

/// seq -> @{ @"label": "METHOD path", @"at": NSDate }. A request with no entry has
/// already been closed, which is what makes double-closing (completion handler AND
/// delegate callback for the same task) harmless.
static NSMutableDictionary<NSNumber *, NSDictionary *> *gPending;
/// owner class name -> the IMP we displaced, so the app's own callback still runs.
static NSMutableDictionary<NSString *, NSValue *> *gOrigDone;
static NSInteger gSeq = 0;

static const void *kSeqKey = &kSeqKey;

static id VSNetLock(void) {
    static id t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSObject new]; });
    return t;
}

#pragma mark - What may be written down

/// "METHOD path" and nothing else: no host, no query string, no headers, no body.
/// The query string is dropped on purpose — Instagram signs some GETs with values
/// in it, and a path is enough to name the endpoint a step is waiting on.
static NSString *VSLabel(NSString *method, NSURL *url) {
    NSString *p = url.path.length ? url.path : @"/";
    return [NSString stringWithFormat:@"%@ %@", method.length ? method : @"GET", p];
}

static NSInteger VSStatus(NSURLResponse *r) {
    return [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : -1;
}

/// An API call is worth a line on its own; anything else (images, CDN) stays at
/// debug so the journal keeps its signal.
static BOOL VSInteresting(NSString *label) {
    return [label containsString:@"/api/"] || [label containsString:@"/accounts/"];
}

#pragma mark - Open / close

static NSNumber *VSOpen(NSString *label) {
    NSNumber *seq;
    @synchronized (VSNetLock()) {
        seq = @(++gSeq);
        gPending[seq] = @{ @"label": label ?: @"?", @"at": [NSDate date] };
    }
    if (VSInteresting(label))
        VSLogI(@"net", @"keys: -> #%@ %@", seq, label);
    else
        VSLogD(@"net", @"keys: -> #%@ %@", seq, label);
    return seq;
}

/// The remote diagnostics sink must never be probed. A push happens on a WARN line,
/// and closing a failed push emits a WARN of its own — which would push again, fail
/// again, and turn one unreachable sink into an unbounded request loop.
static BOOL VSSkipURL(NSURL *url) {
    NSString *h = url.host.lowercaseString;
    return h.length == 0 || [h containsString:@"ntfy.sh"];
}

/// nil (and therefore no tag, and no close) for anything we must not observe.
static NSNumber *VSBegin(NSString *method, NSURL *url) {
    if (VSSkipURL(url)) return nil;
    return VSOpen(VSLabel(method, url));
}

static void VSClose(NSNumber *seq, NSInteger status, NSError *err) {
    if (!seq) return;
    NSDictionary *info;
    @synchronized (VSNetLock()) {
        info = gPending[seq];
        if (!info) return;                       // already closed by the other path
        [gPending removeObjectForKey:seq];
    }
    NSString *label = info[@"label"];
    NSDate   *at    = info[@"at"];
    double dt = at ? -at.timeIntervalSinceNow : 0;

    if (err)
        VSLogW(@"net", @"keys: <- #%@ %@ FAILED %@/%ld after %.2fs",
               seq, label, err.domain, (long)err.code, dt);
    else if (status >= 400)
        VSLogW(@"net", @"keys: <- #%@ %@ REFUSED %ld after %.2fs",
               seq, label, (long)status, dt);
    else if (VSInteresting(label))
        VSLogI(@"net", @"keys: <- #%@ %@ %ld (%.2fs)", seq, label, (long)status, dt);
    else
        VSLogD(@"net", @"keys: <- #%@ %@ %ld (%.2fs)", seq, label, (long)status, dt);
}

/// Tag the task so a delegate-driven completion can close the same entry the
/// factory opened. Associated objects only — no ivars, nothing enumerable.
static void VSTag(id task, NSNumber *seq) {
    if (task && seq) objc_setAssociatedObject(task, kSeqKey, seq, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Task factories (where a request becomes observable)

typedef void (^VSDataCH)(NSData *, NSURLResponse *, NSError *);

static id (*orig_dtReq)(id, SEL, NSURLRequest *)                              = NULL;
static id (*orig_dtReqCH)(id, SEL, NSURLRequest *, VSDataCH)                  = NULL;
static id (*orig_dtURL)(id, SEL, NSURL *)                                     = NULL;
static id (*orig_dtURLCH)(id, SEL, NSURL *, VSDataCH)                         = NULL;
static id (*orig_utReq)(id, SEL, NSURLRequest *, NSData *)                    = NULL;
static id (*orig_utReqCH)(id, SEL, NSURLRequest *, NSData *, VSDataCH)        = NULL;

/// Wrap the app's handler so the response is seen, then hand it the untouched
/// arguments. The seq is captured by value, so the block never retains the task and
/// cannot keep it alive.
static VSDataCH VSWrap(VSDataCH ch, NSNumber *seq) {
    if (!ch) return nil;
    return ^(NSData *d, NSURLResponse *r, NSError *e) {
        VSClose(seq, VSStatus(r), e);
        ch(d, r, e);
    };
}

static id vs_dtReq(id s, SEL c, NSURLRequest *req) {
    id t = orig_dtReq(s, c, req);
    VSTag(t, VSBegin(req.HTTPMethod, req.URL));
    return t;
}
static id vs_dtReqCH(id s, SEL c, NSURLRequest *req, VSDataCH ch) {
    NSNumber *seq = VSBegin(req.HTTPMethod, req.URL);
    id t = orig_dtReqCH(s, c, req, (ch && seq) ? VSWrap(ch, seq) : ch);
    VSTag(t, seq);
    return t;
}
static id vs_dtURL(id s, SEL c, NSURL *url) {
    id t = orig_dtURL(s, c, url);
    VSTag(t, VSBegin(@"GET", url));
    return t;
}
static id vs_dtURLCH(id s, SEL c, NSURL *url, VSDataCH ch) {
    NSNumber *seq = VSBegin(@"GET", url);
    id t = orig_dtURLCH(s, c, url, (ch && seq) ? VSWrap(ch, seq) : ch);
    VSTag(t, seq);
    return t;
}
static id vs_utReq(id s, SEL c, NSURLRequest *req, NSData *body) {
    id t = orig_utReq(s, c, req, body);
    VSTag(t, VSBegin(req.HTTPMethod, req.URL));
    return t;
}
static id vs_utReqCH(id s, SEL c, NSURLRequest *req, NSData *body, VSDataCH ch) {
    NSNumber *seq = VSBegin(req.HTTPMethod, req.URL);
    id t = orig_utReqCH(s, c, req, body, (ch && seq) ? VSWrap(ch, seq) : ch);
    VSTag(t, seq);
    return t;
}

#pragma mark - Delegate completion (where a delegate-driven task reports back)

/// The class that actually implements `sel`, walking up from `cls`. Swizzling the
/// class Instagram hands us would otherwise silently patch a SUPERCLASS method and
/// leave us unable to find the original again from the object's own class.
static Class VSOwner(Class cls, SEL sel) {
    Class c = cls;
    while (c) {
        Class sup = class_getSuperclass(c);
        Method m  = class_getInstanceMethod(c, sel);
        Method sm = sup ? class_getInstanceMethod(sup, sel) : NULL;
        if (!m) return Nil;
        if (m != sm) return c;
        c = sup;
    }
    return Nil;
}

static IMP VSOrigDoneFor(Class cls) {
    @synchronized (VSNetLock()) {
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            NSValue *v = gOrigDone[NSStringFromClass(c)];
            if (v) return (IMP)v.pointerValue;
        }
    }
    return NULL;
}

static void vs_didComplete(id s, SEL c, id session, id task, NSError *err) {
    NSNumber *seq = objc_getAssociatedObject(task, kSeqKey);
    if (seq) {
        NSURLResponse *r = [task respondsToSelector:@selector(response)] ? [task response] : nil;
        VSClose(seq, VSStatus(r), err);
    }
    IMP orig = VSOrigDoneFor(object_getClass(s));
    if (orig) ((void (*)(id, SEL, id, id, NSError *))orig)(s, c, session, task, err);
}

/// At most ONE probed class per inheritance chain, enforced here. vs_didComplete is a
/// single shared IMP that recovers "the original" by walking up from the receiver's
/// class, so two probed classes in one chain would recurse without end: a probed
/// subclass whose own implementation calls [super URLSession:task:didCompleteWithError:]
/// lands back in vs_didComplete with the receiver unchanged, finds the SUBCLASS entry
/// again, and calls itself. Refusing the second class costs one delegate's lines in the
/// journal; not refusing it costs a stack overflow inside the app's networking, which is
/// exactly the kind of harm a log-only layer must not be able to do.
static BOOL VSChainAlreadyProbedLocked(Class owner) {
    for (NSString *name in gOrigDone) {
        Class probed = NSClassFromString(name);
        if (!probed) continue;
        if (probed == owner) return YES;
        for (Class c = probed; c; c = class_getSuperclass(c))
            if (c == owner) return YES;               // a descendant is already probed
        for (Class c = owner; c; c = class_getSuperclass(c))
            if (c == probed) return YES;              // an ancestor is already probed
    }
    return NO;
}

/// A delegate that does not already implement the callback is left untouched: adding
/// one would make -respondsToSelector: answer YES for a method the app never wrote,
/// which is a behaviour change, and this layer is not allowed any.
static void VSProbeDelegate(id delegate) {
    if (!delegate) return;
    SEL sel = @selector(URLSession:task:didCompleteWithError:);
    Class owner = VSOwner(object_getClass(delegate), sel);
    if (!owner) return;

    NSString *key = NSStringFromClass(owner);
    BOOL attached = NO;
    @synchronized (VSNetLock()) {
        if (!VSChainAlreadyProbedLocked(owner)) {
            Method m = class_getInstanceMethod(owner, sel);
            if (m) {
                gOrigDone[key] = [NSValue valueWithPointer:method_getImplementation(m)];
                method_setImplementation(m, (IMP)vs_didComplete);
                attached = YES;
            }
        }
    }
    if (attached) VSLogI(@"net", @"keys: probe attached to delegate %@", key);
}

static id (*orig_sessionWithCfg)(id, SEL, id, id, id) = NULL;

static id vs_sessionWithCfg(id s, SEL c, id cfg, id delegate, id queue) {
    VSProbeDelegate(delegate);
    return orig_sessionWithCfg(s, c, cfg, delegate, queue);
}

#pragma mark - Install

/// Swizzle at the class that owns the selector, starting from the CONCRETE session
/// class: NSURLSession is a class cluster, and patching the abstract façade would
/// leave the real subclass's override untouched — a probe that records nothing.
static BOOL VSSwizzleOwned(Class from, SEL sel, void *repl, void **outOrig, const char *name) {
    Class owner = VSOwner(from, sel);
    if (!owner) { VSLogW(@"net", @"probe miss: %s not found", name); return NO; }
    Method m = class_getInstanceMethod(owner, sel);
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}

@implementation VSHookNetwork

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)install {
    if (gInstalled) return YES;
    gPending  = [NSMutableDictionary dictionary];
    gOrigDone = [NSMutableDictionary dictionary];

    Class concrete = object_getClass(NSURLSession.sharedSession);
    if (!concrete) { VSLogW(@"net", @"probe not installed: no shared session"); return NO; }

    struct { SEL sel; void *repl; void **orig; const char *name; } sw[] = {
        { @selector(dataTaskWithRequest:),                    (void *)vs_dtReq,   (void **)&orig_dtReq,   "dataTaskWithRequest:" },
        { @selector(dataTaskWithRequest:completionHandler:),  (void *)vs_dtReqCH, (void **)&orig_dtReqCH, "dataTaskWithRequest:completionHandler:" },
        { @selector(dataTaskWithURL:),                        (void *)vs_dtURL,   (void **)&orig_dtURL,   "dataTaskWithURL:" },
        { @selector(dataTaskWithURL:completionHandler:),      (void *)vs_dtURLCH, (void **)&orig_dtURLCH, "dataTaskWithURL:completionHandler:" },
        { @selector(uploadTaskWithRequest:fromData:),         (void *)vs_utReq,   (void **)&orig_utReq,   "uploadTaskWithRequest:fromData:" },
        { @selector(uploadTaskWithRequest:fromData:completionHandler:), (void *)vs_utReqCH, (void **)&orig_utReqCH, "uploadTaskWithRequest:fromData:completionHandler:" },
    };
    int ok = 0;
    for (size_t i = 0; i < sizeof(sw) / sizeof(sw[0]); i++)
        if (VSSwizzleOwned(concrete, sw[i].sel, sw[i].repl, sw[i].orig, sw[i].name)) ok++;

    // Delegate-driven tasks report completion on the app's own delegate object, whose
    // class is only known once it creates a session — so intercept the factory.
    Class meta = object_getClass(NSURLSession.class);
    SEL sf = @selector(sessionWithConfiguration:delegate:delegateQueue:);
    Method sm = class_getInstanceMethod(meta, sf);
    if (sm) {
        orig_sessionWithCfg = (id (*)(id, SEL, id, id, id))method_getImplementation(sm);
        method_setImplementation(sm, (IMP)vs_sessionWithCfg);
    } else {
        VSLogW(@"net", @"probe miss: +sessionWithConfiguration:delegate:delegateQueue:");
    }

    gInstalled = (ok > 0);
    VSLogI(@"net", @"keys: HTTP probe %@ (%d/%zu factories, method+path+status only, no values)",
           gInstalled ? @"active" : @"INACTIVE", ok, sizeof(sw) / sizeof(sw[0]));
    return gInstalled;
}

/// Newest first, capped at five: a stuck step has exactly one interesting entry and
/// a dump of every in-flight image request would bury it.
+ (NSString *)pendingDescription {
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    @synchronized (VSNetLock()) {
        NSArray<NSNumber *> *keys = [gPending.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                return [b compare:a];
            }];
        for (NSNumber *k in keys) {
            if (rows.count >= 5) break;
            NSDictionary *info = gPending[k];
            NSDate *at = info[@"at"];
            [rows addObject:[NSString stringWithFormat:@"#%@ %@ (%.1fs)",
                             k, info[@"label"], at ? -at.timeIntervalSinceNow : 0]];
        }
    }
    return rows.count ? [rows componentsJoinedByString:@" | "] : @"aucune requête en attente";
}

@end
