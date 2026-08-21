//  VSHookLocation.m — layer 6: fake GPS as a realistic CoreLocation stream (see .h).

#import "VSHookLocation.h"
#import "../Core/VSContainer.h"
#import "../Core/VSLog.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdlib.h>

// Frozen at install from the active container's base location. When gSpoofLoc is
// NO the layer is passive: nothing below is swizzled and these are never read.
static BOOL               gInstalled = NO;
static BOOL               gSpoofLoc  = NO;
static CLLocationDegrees  gLat = 0, gLon = 0;
static CLLocationDistance gAlt = 0;

// Slow random-walk offset (metres) so no two fixes are ever identical.
static double gDriftLatM = 0, gDriftLonM = 0;

// Per-manager stream timer, held as an associated object so each CLLocationManager
// owns its own and -dealloc releases it.
static const void *kVSLocTimerKey = &kVSLocTimerKey;

static double vs_frand(double lo, double hi) {
    return lo + (hi - lo) * ((double)arc4random_uniform(10001) / 10000.0);
}

/// Build one fix: the frozen point nudged by a bounded random walk, with the
/// variable accuracy / at-rest speed / live timestamp a real GPS produces.
static CLLocation *vs_makeFix(void) {
    gDriftLatM += vs_frand(-1.5, 1.5);
    gDriftLonM += vs_frand(-1.5, 1.5);
    double r = hypot(gDriftLatM, gDriftLonM);
    if (r > 8.0) { gDriftLatM *= 8.0 / r; gDriftLonM *= 8.0 / r; }   // stay within ~8 m

    double mPerDegLat = 111320.0;
    double mPerDegLon = 111320.0 * cos(gLat * M_PI / 180.0);
    if (fabs(mPerDegLon) < 1.0) mPerDegLon = 1.0;                    // guard near the poles

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(
        gLat + gDriftLatM / mPerDegLat, gLon + gDriftLonM / mPerDegLon);
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:gAlt + vs_frand(-1.0, 1.0)
                               horizontalAccuracy:vs_frand(5.0, 12.0)
                                 verticalAccuracy:vs_frand(3.0, 5.0)
                                           course:-1
                                            speed:-1
                                        timestamp:[NSDate date]];
}
#pragma mark - Delivery

/// Deliver one fix to the manager's delegate on the main thread.
static void vs_emit(CLLocationManager *mgr) {
    id<CLLocationManagerDelegate> del = mgr.delegate;
    if (!del || ![del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
    [del locationManager:mgr didUpdateLocations:@[ vs_makeFix() ]];
}

/// One fix, delivered async on main — what -requestLocation does.
static void vs_emitOnce(CLLocationManager *mgr) {
    __weak CLLocationManager *wm = mgr;
    dispatch_async(dispatch_get_main_queue(), ^{ CLLocationManager *m = wm; if (m) vs_emit(m); });
}

/// (Re)start a continuous stream at `interval` seconds on the main run loop. Any
/// prior stream on this manager is stopped first. The timer holds the manager
/// weakly and invalidates itself once the manager is gone.
static void vs_startStream(CLLocationManager *mgr, NSTimeInterval interval) {
    NSTimer *old = objc_getAssociatedObject(mgr, kVSLocTimerKey);
    [old invalidate];

    __weak CLLocationManager *wm = mgr;
    NSTimer *t = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *timer) {
        CLLocationManager *m = wm;
        if (!m) { [timer invalidate]; return; }
        vs_emit(m);
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(mgr, kVSLocTimerKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    vs_emitOnce(mgr);   // quick first lock, without waiting a whole interval
}

static void vs_stopStream(CLLocationManager *mgr) {
    NSTimer *t = objc_getAssociatedObject(mgr, kVSLocTimerKey);
    [t invalidate];
    objc_setAssociatedObject(mgr, kVSLocTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Fire the delegate's authorization-changed callback (new or deprecated form)
/// once on the main thread — what a real -request…Authorization does after the
/// system resolves the prompt.
static void vs_fireAuthChanged(CLLocationManager *mgr) {
    __weak CLLocationManager *wm = mgr;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *m = wm; if (!m) return;
        id<CLLocationManagerDelegate> del = m.delegate; if (!del) return;
        if ([del respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
            [del locationManagerDidChangeAuthorization:m];
        else if ([del respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)])
            [del locationManager:m didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedWhenInUse];
    });
}
#pragma mark - Swizzle replacements

// Originals are captured (their address is taken below) but never called: a
// replacement only ever runs when gSpoofLoc is YES, and in that state the real
// CoreLocation behaviour is exactly what we are replacing.
static CLLocation *(*orig_location)(id, SEL)             = NULL;
static void (*orig_startUpd)(id, SEL)                    = NULL;
static void (*orig_stopUpd)(id, SEL)                     = NULL;
static void (*orig_reqLoc)(id, SEL)                      = NULL;
static void (*orig_startSig)(id, SEL)                    = NULL;
static void (*orig_stopSig)(id, SEL)                     = NULL;
static void (*orig_reqWhenInUse)(id, SEL)                = NULL;
static void (*orig_reqAlways)(id, SEL)                   = NULL;
static CLAuthorizationStatus (*orig_authInst)(id, SEL)   = NULL;
static CLAuthorizationStatus (*orig_authClass)(id, SEL)  = NULL;
static BOOL (*orig_servicesEnabled)(id, SEL)             = NULL;
static BOOL (*orig_sigAvail)(id, SEL)                    = NULL;
static CLAccuracyAuthorization (*orig_accuracy)(id, SEL) = NULL;

static CLLocation *vs_location(id s, SEL c)   { (void)s; (void)c; return vs_makeFix(); }
static void vs_startUpd(id s, SEL c)          { (void)c; vs_startStream((CLLocationManager *)s, 1.0); }
static void vs_stopUpd(id s, SEL c)           { (void)c; vs_stopStream((CLLocationManager *)s); }
static void vs_reqLoc(id s, SEL c)            { (void)c; vs_emitOnce((CLLocationManager *)s); }
static void vs_startSig(id s, SEL c)          { (void)c; vs_startStream((CLLocationManager *)s, 300.0); }
static void vs_stopSig(id s, SEL c)           { (void)c; vs_stopStream((CLLocationManager *)s); }
static void vs_reqAuth(id s, SEL c)           { (void)c; vs_fireAuthChanged((CLLocationManager *)s); }
static CLAuthorizationStatus vs_authStatus(id s, SEL c) { (void)s; (void)c; return kCLAuthorizationStatusAuthorizedWhenInUse; }
static BOOL vs_servicesEnabled(id s, SEL c)   { (void)s; (void)c; return YES; }
static BOOL vs_sigAvail(id s, SEL c)          { (void)s; (void)c; return YES; }
static CLAccuracyAuthorization vs_accuracy(id s, SEL c) { (void)s; (void)c; return CLAccuracyAuthorizationFullAccuracy; }
#pragma mark - Swizzle install

static BOOL VSSwizzle(Class cls, SEL sel, void *repl, void **outOrig) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}
/// Class methods live on the metaclass; everything else is identical.
static BOOL VSSwizzleClassM(Class cls, SEL sel, void *repl, void **outOrig) {
    return VSSwizzle(object_getClass(cls), sel, repl, outOrig);
}

@implementation VSHookLocation

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installForContainer:(VSContainer *)c {
    if (gInstalled) return YES;
    if (!c) { VSLogE(@"loc", @"refusing to install: no container"); return NO; }

    // Freeze the choice, exactly like the device identity and a container switch:
    // read once, effective for the whole process, changed only on relaunch.
    gSpoofLoc = c.locationEnabled && !(c.latitude == 0.0 && c.longitude == 0.0);
    gLat = c.latitude; gLon = c.longitude; gAlt = c.altitude;

    if (!gSpoofLoc) {
        // Passive: no base location, so leave CoreLocation entirely untouched.
        gInstalled = YES;
        VSLogI(@"loc", @"passive — %@ has no base location; CoreLocation unmodified", c.cid);
        return YES;
    }
    Class cls = CLLocationManager.class;
    VSSwizzle(cls, @selector(location),                                  (void *)vs_location,        (void **)&orig_location);
    VSSwizzle(cls, @selector(startUpdatingLocation),                     (void *)vs_startUpd,        (void **)&orig_startUpd);
    VSSwizzle(cls, @selector(stopUpdatingLocation),                      (void *)vs_stopUpd,         (void **)&orig_stopUpd);
    VSSwizzle(cls, @selector(requestLocation),                           (void *)vs_reqLoc,          (void **)&orig_reqLoc);
    VSSwizzle(cls, @selector(startMonitoringSignificantLocationChanges), (void *)vs_startSig,        (void **)&orig_startSig);
    VSSwizzle(cls, @selector(stopMonitoringSignificantLocationChanges),  (void *)vs_stopSig,         (void **)&orig_stopSig);
    VSSwizzle(cls, @selector(requestWhenInUseAuthorization),             (void *)vs_reqAuth,         (void **)&orig_reqWhenInUse);
    VSSwizzle(cls, @selector(requestAlwaysAuthorization),                (void *)vs_reqAuth,         (void **)&orig_reqAlways);
    // iOS 14+ instance accessors; class_getInstanceMethod is NULL on older and the swizzle is skipped.
    VSSwizzle(cls, @selector(authorizationStatus),                       (void *)vs_authStatus,      (void **)&orig_authInst);
    VSSwizzle(cls, @selector(accuracyAuthorization),                     (void *)vs_accuracy,        (void **)&orig_accuracy);
    // Class methods (the deprecated +authorizationStatus, +locationServicesEnabled, availability).
    VSSwizzleClassM(cls, @selector(authorizationStatus),                 (void *)vs_authStatus,      (void **)&orig_authClass);
    VSSwizzleClassM(cls, @selector(locationServicesEnabled),             (void *)vs_servicesEnabled, (void **)&orig_servicesEnabled);
    VSSwizzleClassM(cls, @selector(significantLocationChangeMonitoringAvailable), (void *)vs_sigAvail, (void **)&orig_sigAvail);

    gInstalled = YES;
    VSLogI(@"loc", @"GPS spoof active: %.5f, %.5f (alt %.0f m) — %@",
           gLat, gLon, gAlt, c.locationLabel ?: @"?");
    return YES;
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"location hooks not installed";
    if (!gSpoofLoc)  return nil;                 // passive: not spoofing is the correct state

    if (![CLLocationManager locationServicesEnabled])
        return @"locationServicesEnabled reads NO while spoofing";
    CLAuthorizationStatus st = [CLLocationManager authorizationStatus];
    if (st != kCLAuthorizationStatusAuthorizedWhenInUse)
        return [NSString stringWithFormat:@"authorizationStatus reads %d", (int)st];

    CLLocation *got = [[CLLocationManager new] location];
    if (!got) return @"location getter returned nil while spoofing";
    CLLocation *base = [[CLLocation alloc] initWithLatitude:gLat longitude:gLon];
    CLLocationDistance d = [got distanceFromLocation:base];
    if (d > 50.0)
        return [NSString stringWithFormat:@"fix %.5f,%.5f is %.0f m from base %.5f,%.5f",
                got.coordinate.latitude, got.coordinate.longitude, d, gLat, gLon];
    return nil;
}

@end



