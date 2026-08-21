//  VSHookLocale.h — identity layer: time zone + locale, consistent with the container.
//
//  The device fingerprint (VSHookDevice) and the GPS (Phase 6) place a container
//  in a region; its clock and formatting have to agree. Instagram reads the
//  region the ordinary way — +[NSTimeZone systemTimeZone], +[NSLocale
//  currentLocale], +[NSLocale preferredLanguages] — so we swizzle those class
//  methods to report the container's frozen locale/timezone.
//
//  This is intentionally conservative: when the container's locale equals the
//  real device's (the common case — a French user's containers all default to
//  fr_FR / Europe/Paris) the swizzles are a no-op in effect. It only diverges
//  once a container is pinned to a different region, which is exactly when the
//  divergence is wanted.

#import <Foundation/Foundation.h>

@class VSIdentity;

@interface VSHookLocale : NSObject

/// Swizzle NSTimeZone / NSLocale class accessors to report `identity`'s region.
/// Idempotent. A missing/invalid timezone or locale id is skipped rather than
/// fatal; the boot step stays green.
+ (BOOL)installWithIdentity:(VSIdentity *)identity;

+ (BOOL)isInstalled;

/// First region value still reading through to the real device, or nil if the
/// locale/timezone are coherent with the container.
+ (NSString *)firstLeak;

@end
