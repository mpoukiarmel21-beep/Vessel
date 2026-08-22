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
//
//  Coherence with CFNetwork (added after the signup-hang investigation). The jar is
//  an overlay, NOT a shadow. CFNetwork absorbs Set-Cookie and emits the Cookie:
//  header through the CF-level store underneath NSHTTPCookieStorage and never calls
//  the ObjC methods swizzled here, so a jar that only intercepted the ObjC surface
//  split the session in two: the server's csrftoken went into the CF store while
//  Instagram read ours, found nothing, and sent every signed POST with an empty
//  X-CSRFToken — which is precisely a signup step whose "Next" silently does
//  nothing. Reads therefore absorb from the real store and writes are mirrored into
//  it, so there is one session, visible from both sides.

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
/// in the shared store), deletes it, proves it is gone, then cleans up. Finishes
/// with -coherenceLeak. nil means the layer holds.
+ (NSString *)firstLeak;

/// Crosses the ObjC/CFNetwork boundary in both directions: a cookie set by the app
/// must reach the store CFNetwork sends from, and a cookie stored by the network
/// stack must be visible to the app. The second direction is the csrftoken path, so
/// a failure here is a signup blocker rather than a cosmetic isolation gap.
+ (NSString *)coherenceLeak;

/// Which side of the cookie state exists on disk, for the journal. Paths only.
+ (NSString *)storagePlacementDescription;

/// How many times the app actually read this surface, and how many of those were for
/// an instagram.com /api/ URL, plus the cookie NAMES handed over on the last one.
/// Instagram 443's API runs on Tigon (a C++ stack, cookies added by
/// IGCookieAddingInterceptor — verified in the base IPA), so whether it reads through
/// NSHTTPCookieStorage at all is an open question this answers in one launch instead
/// of one build. Counts and key names only; never a cookie value.
+ (NSString *)readStatsDescription;

@end
