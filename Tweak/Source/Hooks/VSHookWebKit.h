//  VSHookWebKit.h — isolation layer 4b: WKWebsiteDataStore.
//
//  Layer 4 (VSHookCookies) isolates +[NSHTTPCookieStorage sharedHTTPCookieStorage],
//  which covers CFNetwork/NSURLSession traffic and the classic cookie jar. But a
//  WKWebView does NOT read that jar: WebKit keeps its cookies, localStorage,
//  IndexedDB and cache in a WKWebsiteDataStore, out of our process, keyed by the
//  store — and +[WKWebsiteDataStore defaultDataStore] is a process-wide singleton
//  exactly like the cookie storage. Instagram signs in through an embedded web
//  view for several flows (OAuth, checkpoints, some web surfaces); left shared,
//  the sessionid written into WebKit storage by one container is visible to the
//  next — the same "les comptes se mélangent" / "le compte a disparu" bugs, one
//  layer deeper than cookies.
//
//  Mechanism: swizzle the class method +[WKWebsiteDataStore defaultDataStore] to
//  return a PERSISTENT, per-container store obtained from
//  +[WKWebsiteDataStore dataStoreForIdentifier:] (iOS 17+), whose identifier is a
//  UUID derived deterministically from the container id — so the same container
//  always reopens the same web storage across launches (web logins persist), and
//  two containers never share one.
//
//  Fail-safe by construction:
//    * WebKit is resolved by name (NSClassFromString), never linked — no load-time
//      dependency and nothing to see in our load commands.
//    * On any OS without dataStoreForIdentifier: (pre-iOS 17) the layer installs
//      PASSIVE — it swizzles nothing and returns NO. Instagram keeps the shared
//      default store: web logins are not isolated, but nothing regresses and there
//      is no crash.
//    * The swizzled getter falls back to the real default store if the per-container
//      store cannot be built, so a web view can never come back nil.

#import <Foundation/Foundation.h>

@interface VSHookWebKit : NSObject

/// Swizzles +[WKWebsiteDataStore defaultDataStore] to hand back this container's
/// private persistent store. Idempotent. Returns NO (installing nothing) on empty
/// cid, when WebKit is absent, or on an OS without per-identifier data stores.
+ (BOOL)installForContainerID:(NSString *)cid;

/// Log-only observability shim used when full isolation is disabled. Swizzles the
/// same +[WKWebsiteDataStore defaultDataStore] but only records the first time
/// Instagram asks for the web data store (revealing whether a flow such as signup
/// runs through a web view) and then returns the genuine default store. Holds no
/// lock and builds no store, so it cannot wedge. Idempotent; no-op if the full
/// isolation is already installed.
+ (void)installProbe;

+ (BOOL)isInstalled;

/// Deletes a container's WebKit storage from disk (cookies, localStorage, caches).
/// Called from VSManager when a container is deleted or everything is reset, so a
/// removed account leaves nothing behind in the WebKit store either. No-op when
/// WebKit or the API is unavailable; safe to call for a cid that never opened a
/// web view. Marshalled to the main thread, as WebKit requires.
+ (void)purgeStoreForContainerID:(NSString *)cid;

/// Layer-4b verification for VSSelfTest: proves +defaultDataStore is routed through
/// this container's store and a per-container identifier is set. It deliberately
/// does NOT force WebKit to spin up from the boot constructor; physical storage is
/// exercised naturally the first time Instagram opens a web view. nil means the
/// layer holds.
+ (NSString *)firstLeak;

@end
