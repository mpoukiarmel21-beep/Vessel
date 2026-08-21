//  VSHookCookies.h — isolation layer 4: HTTP cookies.
//
//  Instagram's web views and a share of its API traffic authenticate with
//  cookies kept in +[NSHTTPCookieStorage sharedHTTPCookieStorage] — a
//  process-wide singleton backed by a file the OS manages partly out of process,
//  so, like the keychain and cfprefsd, redirecting HOME (layer 1) does not split
//  it. Two containers sharing one cookie jar is a third route to the headline
//  bugs: the sessionid cookie written after one container logs in is visible to
//  the next ("les comptes se mélangent"), and a logout that clears the shared jar
//  takes the other container's session with it ("le compte a disparu").
//
//  Mechanism: swizzle the shared storage's accessors and mutators (cookies,
//  cookiesForURL:, setCookie:, setCookies:forURL:mainDocumentURL:, deleteCookie:,
//  removeCookiesSinceDate:, sortedCookiesUsingDescriptors:) and back them with a
//  per-container jar persisted inside the container. The interception is gated on
//  identity — it fires ONLY for the one shared instance — so an ephemeral session
//  (NSURLSessionConfiguration.ephemeralSessionConfiguration), which deliberately
//  owns a private in-memory jar and is already isolated, is left untouched rather
//  than quietly folded into the container's cookies.
//
//  Every replacement falls back to the original for any storage that is not the
//  shared one and no-ops safely if the layer is not installed, so the failure mode
//  is "cookies not isolated", never a crash inside Instagram's networking.

#import <Foundation/Foundation.h>

@interface VSHookCookies : NSObject

/// Swizzles the shared NSHTTPCookieStorage and opens this container's private
/// cookie jar. Idempotent; returns NO and installs nothing on empty cid, leaving
/// Instagram on the shared jar rather than on a half-isolated one.
+ (BOOL)installForContainerID:(NSString *)cid;

+ (BOOL)isInstalled;

/// Layer-4 verification for VSSelfTest: sets a uniquely-named cookie through the
/// shared storage, proves it reads back through -cookies and -cookiesForURL:,
/// proves it physically landed in this container's jar on disk (and therefore not
/// in the shared store), deletes it, proves it is gone, then cleans up. nil means
/// the layer holds.
+ (NSString *)firstLeak;

@end
