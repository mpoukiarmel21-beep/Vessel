//  VSHookLocation.h — identity layer (layer 6): per-container fake GPS.
//
//  Instagram reads position the ordinary way: it creates a CLLocationManager,
//  checks the authorization status, calls -startUpdatingLocation and consumes the
//  -locationManager:didUpdateLocations: its delegate receives. So, exactly as with
//  the device fingerprint, we do not fabricate a report — we drive the real
//  CoreLocation API surface so the app builds its own picture of a phone sitting
//  in the container's chosen city.
//
//  The previous project's fake GPS failed a simple realism test: it delivered ONE
//  deferred callback and then went silent, so any code that waited for a stream
//  (which the Instagram map / "add location" flow does) either stalled or fell back
//  to the real fix. Here -startUpdatingLocation opens a genuine continuous stream
//  (a 1 s timer on the main run loop), -requestLocation delivers one immediate
//  fix, and significant-change monitoring runs a slow stream — the same shapes a
//  real GPS produces.
//
//  Realism, because a constant is a tell:
//    • the coordinate random-walks a few metres around the point (a real GPS never
//      returns the same fix twice),
//    • horizontalAccuracy varies 5–12 m, verticalAccuracy ~4 m,
//    • speed/course are −1 (what a stationary device reports),
//    • timestamp is "now" on every send (a frozen timestamp is the classic tell).
//
//  Opt-in per container, and frozen for the process. If the active container has
//  no base location (the default state), this layer installs itself PASSIVE:
//  it swizzles nothing and CoreLocation behaves exactly as it would unmodified —
//  spoofing a lone real account's position would be pointless and a needless
//  detection surface. The choice is read once at install, like the frozen device
//  identity and like a container switch, both of which take effect on relaunch.

#import <Foundation/Foundation.h>

@class VSContainer;

@interface VSHookLocation : NSObject

/// Read `container`'s base location and, when it is enabled and non-null, swizzle
/// the CLLocationManager surface (location getter, start/stop updating, request,
/// significant-change, authorization + accuracy, locationServicesEnabled) to
/// report it as a continuous, realistic stream. When the container has no base
/// location this installs PASSIVE (swizzles nothing) and still returns YES.
/// Idempotent; returns NO only if `container` is nil.
+ (BOOL)installForContainer:(VSContainer *)container;

+ (BOOL)isInstalled;

/// When spoofing, reads position back through the public API and returns the first
/// value still describing the real device (services disabled, wrong auth, or a fix
/// far from the base point), or nil if coherent. When installed passive (no base
/// location) returns nil: not spoofing is the correct state.
+ (NSString *)firstLeak;

@end
