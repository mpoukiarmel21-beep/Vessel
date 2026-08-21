//  VSHookImage.h — anti-detection: hide our own dylib from image enumeration.
//
//  A modified app is most cheaply detected by walking the loaded-image list and
//  looking for a library that has no business being there. The public walk is
//  _dyld_image_count() + _dyld_get_image_name(i); an integrity check that finds a
//  non-system dylib injected next to Instagram's own frameworks flags the process
//  as tampered. We rebind those two libdyld entry points so the walk returns the
//  list with our image removed: the count is one lower and every index at or after
//  our slot is shifted past it, so our name is never returned.
//
//  Scope, deliberately narrow (see the .m for the full argument):
//    * We hook ONLY _dyld_image_count and _dyld_get_image_name. fishhook drives its
//      own rebinding loop off _dyld_get_image_header / _dyld_get_image_vmaddr_slide;
//      hooking those would corrupt fishhook's iteration if any rebind ran after us.
//      So this layer installs LAST, after every other rebind, and touches neither.
//    * The trade-off: a detector that reads a header by index (unhooked) and a name
//      by the same index (hooked) sees them disagree for indices past our slot. That
//      correlation is far rarer than a plain name scan, and defeating it would mean
//      breaking fishhook — which the "must not regress" constraint forbids.
//
//  Fail-safe by construction:
//    * If we cannot locate our own image, resolve libdyld, or rebind, the layer
//      installs nothing and returns NO — the app keeps the genuine image list.
//    * The image list can shift at runtime (a later dlopen). Before masking on any
//      call we revalidate our cached index against our header and rescan if it moved;
//      if our image can no longer be found we stop masking (reveal, never miscount or
//      crash). Newly loaded images are unaffected — fishhook rebinds them through its
//      add-image callback, which takes header+slide directly and never calls us.

#import <Foundation/Foundation.h>

@interface VSHookImage : NSObject

/// Rebinds _dyld_image_count / _dyld_get_image_name so the loaded-image walk no
/// longer shows our dylib. MUST be installed last, after every fishhook rebind the
/// tweak performs. Idempotent; returns NO (masking nothing) if our image cannot be
/// located, libdyld cannot be resolved, or the rebind fails.
+ (BOOL)install;

+ (BOOL)isInstalled;

/// Verification for VSSelfTest: walks the list through the hooked entry points and
/// confirms the count dropped by one and our own image name is absent. nil means
/// the cloak holds.
+ (NSString *)firstLeak;

@end
