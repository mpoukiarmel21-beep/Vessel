//  VSHookDevice.h — identity layer (layer 5): per-container device fingerprint.
//
//  Instagram never asks us "which device are you"; it reads the OS the way any
//  app does — sysctl(hw.machine), uname(), IOKit (IOPlatformUUID / serial),
//  MobileGestalt, UIDevice, ASIdentifierManager — and assembles its own
//  User-Agent and device report from what those return. So we do not falsify the
//  report, we falsify the SOURCES, and let Instagram build a coherent picture of
//  a phone that is not this one.
//
//  Two rules keep it undetectable:
//    • Consistency over novelty. The model comes from VSIdentity, which already
//      picked one whose native screen matches the real panel, so the UA's model
//      and its resolution agree. The OS version is only projected when the real
//      device shares the same major (§3.2) — claiming an OS the frameworks are
//      not is how you crash the app, not spoof it.
//    • Swap content, never fabricate visibility. For IOKit / MobileGestalt we
//      replace only the value the app already receives; if the real read returned
//      nothing (the sandbox denied it, as it does for most of these on iOS), we
//      return nothing too. Inventing a value the real device never exposes is a
//      louder signal than not spoofing.
//
//  All values come from the frozen VSIdentity of the active container, snapshot
//  once at install into plain C globals so the sysctl/uname replacements — which
//  fire on arbitrary threads with no autorelease pool — touch no ObjC at all.

#import <Foundation/Foundation.h>

@class VSIdentity;

@interface VSHookDevice : NSObject

/// Rebind the C sources (sysctl/sysctlbyname/uname, and IOKit/MobileGestalt when
/// present) and swizzle the ObjC accessors (UIDevice.systemVersion /
/// identifierForVendor, ASIdentifierManager, ATTrackingManager) to report
/// `identity`. Idempotent; refuses (returns NO) if identity or its machine is
/// missing, or if an essential libc symbol cannot be resolved.
+ (BOOL)installWithIdentity:(VSIdentity *)identity;

+ (BOOL)isInstalled;

/// Reads the spoofed sources back through the public API and returns the first
/// one still leaking the real device, or nil if the fingerprint is coherent.
+ (NSString *)firstLeak;

@end
