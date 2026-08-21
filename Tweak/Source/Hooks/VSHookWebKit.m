//  VSHookWebKit.m

#import "VSHookWebKit.h"
#import "../Core/VSLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static Class   gWKDS      = Nil;   // WKWebsiteDataStore, resolved by name
static NSUUID *gUUID      = nil;   // this container's stable store identifier
static id      gStore     = nil;   // cached per-container store (lazy)
static BOOL    gInstalled = NO;
static BOOL    gBuilding  = NO;    // re-entrancy guard around store creation

static id (*orig_defaultDataStore)(id, SEL) = NULL;

/// One lock guarding the lazy build of gStore.
static id VSWebKitLock(void) {
    static id t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSObject new]; });
    return t;
}

/// A container id maps to ONE data-store identifier, deterministically, so the
/// same container reopens the same WebKit storage every launch (this is what makes
/// a web login survive a kill) while two containers never collide. MD5 gives 16
/// bytes; we set the RFC-4122 version (4) and variant bits so the result is a
/// well-formed UUID — +dataStoreForIdentifier: rejects malformed / all-zero ones.
static NSUUID *VSUUIDForCID(NSString *cid) {
    if (cid.length == 0) return nil;
    NSData *d = [cid dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, h);
    h[6] = (h[6] & 0x0F) | 0x40;   // version 4
    h[8] = (h[8] & 0x3F) | 0x80;   // variant 1
    return [[NSUUID alloc] initWithUUIDBytes:h];
}

/// Builds (once) and returns this container's persistent store, or nil if WebKit
/// cannot provide one — the caller then falls back to the real default store.
static id VSContainerStore(void) {
    @synchronized (VSWebKitLock()) {
        if (gStore || gBuilding) return gStore;
        if (!gWKDS || !gUUID) return nil;
        gBuilding = YES;
        @try {
            typedef id (*Fn)(Class, SEL, NSUUID *);
            Fn fn = (Fn)objc_msgSend;
            gStore = fn(gWKDS, @selector(dataStoreForIdentifier:), gUUID);
        } @catch (NSException *e) {
            VSLogE(@"webkit", @"dataStoreForIdentifier: threw (%@) — using default store", e.reason);
            gStore = nil;
        }
        gBuilding = NO;
        return gStore;
    }
}
#pragma mark - Swizzled replacement

/// Replaces +[WKWebsiteDataStore defaultDataStore]. Any code that reads the
/// "default" store — including -[WKWebViewConfiguration init], which adopts it
/// implicitly — receives the container store instead. Falls back to the genuine
/// default if our store cannot be built, so a web view is never handed nil.
static id vs_defaultDataStore(id self_, SEL _cmd) {
    if (!gInstalled) return orig_defaultDataStore(self_, _cmd);
    id store = VSContainerStore();
    return store ?: orig_defaultDataStore(self_, _cmd);
}

#pragma mark - Install

@implementation VSHookWebKit

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installForContainerID:(NSString *)cid {
    if (gInstalled) return YES;
    if (cid.length == 0) { VSLogE(@"webkit", @"refusing to install: empty cid"); return NO; }

    gWKDS = NSClassFromString(@"WKWebsiteDataStore");
    if (!gWKDS) { VSLogW(@"webkit", @"WKWebsiteDataStore absent — web storage not isolated"); return NO; }

    // Per-identifier persistent stores are iOS 17+. Without them there is no way to
    // give a web view a NAMED persistent store, and an ephemeral one would drop the
    // web login on every launch — worse than sharing. So: install nothing, stay on
    // the shared default store, report NO. (The user's device is iOS 26; this guard
    // is for older installs and future-proofing.)
    if (![gWKDS respondsToSelector:@selector(dataStoreForIdentifier:)]) {
        VSLogW(@"webkit", @"dataStoreForIdentifier: unavailable on this OS — web storage not isolated");
        gWKDS = Nil;
        return NO;
    }

    gUUID = VSUUIDForCID(cid);
    if (!gUUID) { VSLogE(@"webkit", @"could not derive a store identifier from cid"); gWKDS = Nil; return NO; }

    Method m = class_getClassMethod(gWKDS, @selector(defaultDataStore));
    if (!m) {
        VSLogW(@"webkit", @"+defaultDataStore not found — web storage not isolated");
        gWKDS = Nil; gUUID = nil;
        return NO;
    }
    orig_defaultDataStore = (id (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)vs_defaultDataStore);

    gInstalled = YES;
    VSLogI(@"webkit", @"isolated -> data store %@", gUUID.UUIDString);
    return YES;
}
#pragma mark - Purge (container delete / reset)

+ (void)purgeStoreForContainerID:(NSString *)cid {
    Class wkds = NSClassFromString(@"WKWebsiteDataStore");
    if (!wkds || cid.length == 0) return;
    if (![wkds respondsToSelector:@selector(removeDataStoreForIdentifier:completionHandler:)]) return;
    NSUUID *uuid = VSUUIDForCID(cid);
    if (!uuid) return;

    // WebKit requires the main thread for data-store management.
    void (^work)(void) = ^{
        @try {
            typedef void (*Fn)(Class, SEL, NSUUID *, void (^)(NSError *));
            Fn fn = (Fn)objc_msgSend;
            fn(wkds, @selector(removeDataStoreForIdentifier:completionHandler:), uuid,
               ^(NSError *e) {
                   if (e) VSLogW(@"webkit", @"purge %@: %@", cid, e.localizedDescription);
                   else   VSLogI(@"webkit", @"purged web store for %@", cid);
               });
        } @catch (NSException *ex) {
            VSLogW(@"webkit", @"purge threw for %@: %@", cid, ex.reason);
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"layer 4b (WebKit) not installed";
    if (!gWKDS)      return @"WKWebsiteDataStore not present after install";
    if (!gUUID)      return @"no per-container data-store identifier";

    // Structural proof only: confirm +defaultDataStore is routed through us. We do
    // NOT call +defaultDataStore here — that would force WebKit's network process
    // to start from the boot constructor, a needless risk. The real physical proof
    // (that a web view's storage lands in this container) happens the first time
    // Instagram opens a web view, by construction of dataStoreForIdentifier:.
    Method m = class_getClassMethod(gWKDS, @selector(defaultDataStore));
    if (!m || method_getImplementation(m) != (IMP)vs_defaultDataStore)
        return @"+defaultDataStore is not routed through the container store";
    return nil;
}

@end


