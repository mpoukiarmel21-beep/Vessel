//  VSIdentity.h — the per-container device fingerprint.
//
//  Generated ONCE, when the container is created, then frozen. Nothing here is
//  ever recomputed at runtime: a value that changes between launches is a far
//  stronger signal to Instagram than a value that is merely unusual.
//
//  Two deliberate departures from "randomise everything":
//
//  1. The model is drawn from a pool that matches the REAL screen geometry.
//     Instagram's User-Agent embeds both the model and the resolution
//     (…(iPhone14,5; iOS 26_6_1; fr_FR; scale=3.00; 1170x2532; 23G83)). The
//     resolution comes from UIScreen, which cannot be spoofed without breaking
//     layout, so claiming a model whose screen does not match the reported
//     resolution is an obvious inconsistency. A screen-consistent pool gives
//     plausible variety instead.
//
//  2. The iOS version does NOT vary per container. All containers report the
//     same version, and only a version the real device could plausibly be
//     running. Claiming an OS the hardware cannot run (iOS 26 needs A13+, so
//     never on an iPhone XR) is another free inconsistency, and claiming a
//     version far from the real one invites Instagram down code paths the real
//     frameworks do not implement.
//
//  Uniqueness therefore comes from the identifiers that genuinely differ
//  between two physical phones of the same model: IDFV, IDFA, serial,
//  IOPlatformUUID, MAC addresses, device name — plus the four isolated data
//  layers. That is what "a different phone" actually means to a server.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface VSIdentity : NSObject

#pragma mark - Hardware

/// sysctl hw.machine — e.g. "iPhone14,5". This is what Instagram's UA carries.
@property (nonatomic, copy) NSString *machine;
/// sysctl hw.model — board id, e.g. "D17AP". Secondary, but must stay
/// consistent with `machine`.
@property (nonatomic, copy) NSString *boardID;
/// Human name, for our own UI only — e.g. "iPhone 13".
@property (nonatomic, copy) NSString *marketingName;
/// sysctl hw.memsize, in bytes.
@property (nonatomic, assign) unsigned long long memSize;
@property (nonatomic, assign) int cpuCount;          // hw.ncpu / logicalcpu
@property (nonatomic, assign) int physicalCPUCount;  // hw.physicalcpu

#pragma mark - OS

@property (nonatomic, copy) NSString *osVersion;   // "26.6.1"
@property (nonatomic, copy) NSString *osBuild;     // "23G83"  (kern.osversion)
@property (nonatomic, copy) NSString *darwinKernel;// "25.6.0" (kern.osrelease)

#pragma mark - Identifiers (the part that actually makes a container unique)

@property (nonatomic, copy) NSString *idfv;          // identifierForVendor, uppercase UUID
@property (nonatomic, copy) NSString *idfa;          // advertisingIdentifier
@property (nonatomic, copy) NSString *platformUUID;  // IOPlatformUUID
@property (nonatomic, copy) NSString *serialNumber;  // IOPlatformSerialNumber
@property (nonatomic, copy) NSString *wifiMAC;       // en0
@property (nonatomic, copy) NSString *bluetoothMAC;
@property (nonatomic, copy) NSString *deviceName;    // UIDevice.name, e.g. "iPhone de Léa"

#pragma mark - Locale / region

@property (nonatomic, copy) NSString *localeID;      // "fr_FR"
@property (nonatomic, copy) NSString *languageID;    // "fr-FR"
@property (nonatomic, copy) NSString *timeZoneID;    // "Europe/Paris"

#pragma mark - Lifecycle

/// Picks a model whose native screen matches `pxSize`/`scale` and that can run
/// `osVersion`, then generates every identifier. `taken` is the set of values
/// already used by other containers (any of the identifier strings); generation
/// retries until it does not collide.
+ (instancetype)generateForScreenPixelSize:(CGSize)pxSize
                                     scale:(CGFloat)scale
                                 osVersion:(NSString *)osVersion
                                   osBuild:(NSString *)osBuild
                                    locale:(NSString *)localeID
                                  timeZone:(NSString *)timeZoneID
                                     taken:(NSSet<NSString *> *)taken;

+ (instancetype)identityWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionaryRepresentation;

/// Every value that must be unique across containers, for collision checks.
- (NSSet<NSString *> *)uniqueValues;

/// The User-Agent Instagram would build from this identity. NOT injected
/// anywhere — Instagram builds its own from the spoofed sources. Used only by
/// the self-test, to verify the sources are mutually consistent.
- (NSString *)expectedUserAgentWithAppVersion:(NSString *)appVersion
                                    pixelSize:(CGSize)pxSize
                                        scale:(CGFloat)scale;

/// One-line summary for the UI: "iPhone 13 · iOS 26.6.1 · FK3XN1LMQ1GC".
- (NSString *)shortDescription;

@end
