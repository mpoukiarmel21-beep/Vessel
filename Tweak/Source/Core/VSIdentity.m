//  VSIdentity.m

#import "VSIdentity.h"
#import "VSLog.h"
#import <sys/sysctl.h>
#import <sys/types.h>
#import <string.h>
#import <math.h>

/// One row per model iOS 26 can actually run (A13 and up: iPhone 11 and later,
/// plus iPhone SE 2nd/3rd generation). Pixel size is the NATIVE portrait
/// resolution, which is what Instagram's UA reports and what therefore has to
/// agree with the model name. Board ids are the real board configurations, cross
/// checked against theapplewiki and the ipsw.me device API — a made-up hw.model
/// paired with a genuine hw.machine is exactly the kind of mismatch that is
/// cheap for a server to test and impossible to explain away.
typedef struct {
    const char *machine;   // hw.machine
    const char *board;     // hw.model
    const char *name;      // marketing name, our UI only
    int wPx, hPx;          // native portrait pixels
    int scale;
    int memGB;             // nominal RAM, scaled against the real hw.memsize
    int cores;             // hw.ncpu / hw.logicalcpu / hw.physicalcpu
} VSModelSpec;

static const VSModelSpec kModels[] = {
    // A13
    { "iPhone12,1", "N104AP", "iPhone 11",           828, 1792, 2,  4, 6 },
    { "iPhone12,3", "D421AP", "iPhone 11 Pro",      1125, 2436, 3,  4, 6 },
    { "iPhone12,5", "D431AP", "iPhone 11 Pro Max",  1242, 2688, 3,  4, 6 },
    { "iPhone12,8", "D79AP",  "iPhone SE (2020)",    750, 1334, 2,  3, 6 },
    // A14
    { "iPhone13,1", "D52gAP", "iPhone 12 mini",     1080, 2340, 3,  4, 6 },
    { "iPhone13,2", "D53gAP", "iPhone 12",          1170, 2532, 3,  4, 6 },
    { "iPhone13,3", "D53pAP", "iPhone 12 Pro",      1170, 2532, 3,  6, 6 },
    { "iPhone13,4", "D54pAP", "iPhone 12 Pro Max",  1284, 2778, 3,  6, 6 },
    // A15
    { "iPhone14,4", "D16AP",  "iPhone 13 mini",     1080, 2340, 3,  4, 6 },
    { "iPhone14,5", "D17AP",  "iPhone 13",          1170, 2532, 3,  4, 6 },
    { "iPhone14,2", "D63AP",  "iPhone 13 Pro",      1170, 2532, 3,  6, 6 },
    { "iPhone14,3", "D64AP",  "iPhone 13 Pro Max",  1284, 2778, 3,  6, 6 },
    { "iPhone14,6", "D49AP",  "iPhone SE (2022)",    750, 1334, 2,  4, 6 },
    { "iPhone14,7", "D27AP",  "iPhone 14",          1170, 2532, 3,  6, 6 },
    { "iPhone14,8", "D28AP",  "iPhone 14 Plus",     1284, 2778, 3,  6, 6 },
    // A16
    { "iPhone15,2", "D73AP",  "iPhone 14 Pro",      1179, 2556, 3,  6, 6 },
    { "iPhone15,3", "D74AP",  "iPhone 14 Pro Max",  1290, 2796, 3,  6, 6 },
    { "iPhone15,4", "D37AP",  "iPhone 15",          1179, 2556, 3,  6, 6 },
    { "iPhone15,5", "D38AP",  "iPhone 15 Plus",     1290, 2796, 3,  6, 6 },
    // A17 Pro
    { "iPhone16,1", "D83AP",  "iPhone 15 Pro",      1179, 2556, 3,  8, 6 },
    { "iPhone16,2", "D84AP",  "iPhone 15 Pro Max",  1290, 2796, 3,  8, 6 },
    // A18
    { "iPhone17,3", "D47AP",  "iPhone 16",          1179, 2556, 3,  8, 6 },
    { "iPhone17,4", "D48AP",  "iPhone 16 Plus",     1290, 2796, 3,  8, 6 },
    { "iPhone17,5", "V59AP",  "iPhone 16e",         1170, 2532, 3,  8, 6 },
    // A18 Pro
    { "iPhone17,1", "D93AP",  "iPhone 16 Pro",      1206, 2622, 3,  8, 6 },
    { "iPhone17,2", "D94AP",  "iPhone 16 Pro Max",  1320, 2868, 3,  8, 6 },
    // A19
    { "iPhone18,3", "V57AP",  "iPhone 17",          1206, 2622, 3,  8, 6 },
    // A19 Pro
    { "iPhone18,1", "V53AP",  "iPhone 17 Pro",      1206, 2622, 3, 12, 6 },
    { "iPhone18,2", "V54AP",  "iPhone 17 Pro Max",  1320, 2868, 3, 12, 6 },
    { "iPhone18,4", "D23AP",  "iPhone Air",         1260, 2736, 3, 12, 6 },
};

static const int kModelCount = (int)(sizeof(kModels) / sizeof(kModels[0]));

/// Apple-registered OUIs. A MAC is only reachable through getifaddrs, which on
/// modern iOS hands every app 02:00:00:00:00:00 anyway — but if anything ever
/// does read one, it should at least look like Apple silicon.
static const char *kAppleOUIs[] = {
    "00:1E:C2", "3C:07:54", "90:B0:ED", "F0:B4:79", "04:0C:CE",
    "78:7E:61", "DC:2B:2A", "9C:35:EB", "5C:F9:38", "68:AB:1E",
};
static const int kOUICount = (int)(sizeof(kAppleOUIs) / sizeof(kAppleOUIs[0]));

/// Device names people actually have. The pool is French because that is the
/// account region; a name pattern that never varies would itself be a marker.
static NSString *const kFirstNames[] = {
    @"Léa", @"Hugo", @"Emma", @"Lucas", @"Chloé", @"Nathan", @"Manon",
    @"Enzo", @"Camille", @"Théo", @"Sarah", @"Louis", @"Inès", @"Gabriel",
    @"Jade", @"Raphaël", @"Alice", @"Adam", @"Louise", @"Noah",
};
static const int kFirstNameCount = 20;

static uint32_t VSRand(uint32_t upper) { return upper ? arc4random_uniform(upper) : 0; }

#pragma mark - Real hardware snapshot

static NSString *gRealMachine = nil, *gRealBoard = nil;
static NSString *gRealOSVersion = nil, *gRealOSBuild = nil;
static unsigned long long gRealMem = 0;
static int gRealCPU = 0;

static NSString *VSSysctlString(const char *name) {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return nil;
    char *buf = malloc(len);
    if (!buf) return nil;
    NSString *out = nil;
    if (sysctlbyname(name, buf, &len, NULL, 0) == 0) {
        out = [[NSString alloc] initWithBytes:buf
                                       length:strnlen(buf, len)
                                     encoding:NSUTF8StringEncoding];
    }
    free(buf);
    return out.length ? out : nil;
}

static unsigned long long VSSysctlU64(const char *name) {
    uint64_t v = 0; size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    return v;
}

static NSString *VSUpperUUID(void) {
    return NSUUID.UUID.UUIDString.uppercaseString;
}

/// Apple's post-2021 randomised serial format: 10 characters, uppercase
/// alphanumeric. I and O are excluded — Apple avoids them because they read as
/// 1 and 0.
static NSString *VSRandomSerial(void) {
    static const char *abc = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    size_t n = strlen(abc);
    NSMutableString *s = [NSMutableString stringWithCapacity:10];
    for (int i = 0; i < 10; i++) [s appendFormat:@"%c", abc[VSRand((uint32_t)n)]];
    return s;
}

static NSString *VSRandomMAC(void) {
    NSMutableString *s = [NSMutableString stringWithUTF8String:kAppleOUIs[VSRand(kOUICount)]];
    for (int i = 0; i < 3; i++) [s appendFormat:@":%02X", VSRand(256)];
    return s;
}

/// kern.osrelease. The Darwin major tracked the iOS major + 6 up to iOS 18
/// (Darwin 24); when Apple renumbered iOS 19 to iOS 26 the kernel stayed on its
/// own sequence, so iOS 26 is Darwin 25. Both branches are kept rather than one
/// fudged formula, because a wrong kernel string is exactly the kind of detail
/// a fingerprinter cross-checks.
static NSString *VSDarwinKernelForOS(NSString *osVersion) {
    NSArray<NSString *> *parts = [osVersion componentsSeparatedByString:@"."];
    int major = parts.count > 0 ? parts[0].intValue : 26;
    int minor = parts.count > 1 ? parts[1].intValue : 0;
    int darwin = (major >= 26) ? (major - 1) : (major + 6);
    return [NSString stringWithFormat:@"%d.%d.0", darwin, minor];
}

/// Indexes of models whose native screen matches, in either orientation.
static NSArray<NSNumber *> *VSModelsMatchingScreen(int w, int h, int scale) {
    int lo = MIN(w, h), hi = MAX(w, h);
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < kModelCount; i++) {
        if (kModels[i].scale != scale) continue;
        if (MIN(kModels[i].wPx, kModels[i].hPx) == lo &&
            MAX(kModels[i].wPx, kModels[i].hPx) == hi) {
            [out addObject:@(i)];
        }
    }
    return out;
}

/// hw.memsize for a model with `gb` GB of nominal RAM, derived from the real
/// reading rather than computed as gb × 2^30. The kernel does not necessarily
/// report a round power of two (firmware and hardware carve-outs come off the
/// top first), and whatever shape the real device's value has, the spoofed one
/// keeps it. When the chosen model has the same nominal RAM as the real phone —
/// the common case, since the model pool is screen-matched and screen size
/// correlates with RAM — the value returned is the real one, byte for byte.
static unsigned long long VSMemSizeForGB(int gb) {
    unsigned long long real = [VSIdentity realMemSize];   // never 0, see +realMemSize
    int realGB = (int)llround((double)real / 1073741824.0);
    if (gb <= 0 || realGB <= 0 || gb == realGB) return real;
    return (unsigned long long)llround((double)real * (double)gb / (double)realGB);
}

@implementation VSIdentity

+ (void)snapshotRealHardware {
    if (gRealMachine.length) return;
    gRealMachine   = VSSysctlString("hw.machine")            ?: @"iPhone12,1";
    gRealBoard     = VSSysctlString("hw.model")              ?: @"N104AP";
    gRealOSVersion = VSSysctlString("kern.osproductversion") ?: @"26.6.1";
    gRealOSBuild   = VSSysctlString("kern.osversion")        ?: @"23G83";
    gRealMem       = VSSysctlU64("hw.memsize");
    gRealCPU       = (int)VSSysctlU64("hw.ncpu");
    if (gRealCPU == 0) gRealCPU = 6;
    VSLogI(@"identity", @"real hardware: %@ (%@) iOS %@ (%@) %.1f GB, %d cores",
           gRealMachine, gRealBoard, gRealOSVersion, gRealOSBuild,
           gRealMem / 1073741824.0, gRealCPU);
}

+ (NSString *)realMachine   { return gRealMachine   ?: @"iPhone12,1"; }
+ (NSString *)realBoardID   { return gRealBoard     ?: @"N104AP"; }
+ (NSString *)realOSVersion { return gRealOSVersion ?: @"26.6.1"; }
+ (NSString *)realOSBuild   { return gRealOSBuild   ?: @"23G83"; }
+ (unsigned long long)realMemSize { return gRealMem ?: 4294967296ULL; }
+ (int)realCPUCount { return gRealCPU ?: 6; }

#pragma mark - Generation

+ (instancetype)generateForScreenPixelSize:(CGSize)pxSize
                                     scale:(CGFloat)scale
                                 osVersion:(NSString *)osVersion
                                   osBuild:(NSString *)osBuild
                                    locale:(NSString *)localeID
                                  timeZone:(NSString *)timeZoneID
                                     taken:(NSSet<NSString *> *)taken {
    int w = (int)lround(pxSize.width), h = (int)lround(pxSize.height);
    int sc = (int)lround(scale);

    NSArray<NSNumber *> *pool = VSModelsMatchingScreen(w, h, sc);
    if (pool.count == 0) {
        // Unknown geometry: reporting a model whose screen contradicts the
        // resolution Instagram reads from UIScreen would be worse than not
        // spoofing the model at all, so fall back to the real machine string.
        VSLogW(@"identity", @"no model matches %dx%d@%dx — model left unspoofed", w, h, sc);
    }

    VSIdentity *id_ = [VSIdentity new];

    if (pool.count > 0) {
        const VSModelSpec *m = &kModels[pool[VSRand((uint32_t)pool.count)].intValue];
        id_.machine         = @(m->machine);
        id_.boardID         = @(m->board);
        id_.marketingName   = @(m->name);
        id_.memSize         = VSMemSizeForGB(m->memGB);
        id_.cpuCount        = m->cores;
        id_.physicalCPUCount= m->cores;
    } else {
        id_.machine         = [VSIdentity realMachine];
        id_.boardID         = [VSIdentity realBoardID];
        id_.marketingName   = [VSIdentity realMachine];
        id_.memSize         = [VSIdentity realMemSize];
        id_.cpuCount        = [VSIdentity realCPUCount];
        id_.physicalCPUCount= [VSIdentity realCPUCount];
    }

    id_.osVersion    = osVersion.length ? osVersion : [VSIdentity realOSVersion];
    id_.osBuild      = osBuild.length   ? osBuild   : [VSIdentity realOSBuild];
    id_.darwinKernel = VSDarwinKernelForOS(id_.osVersion);
    id_.localeID     = localeID.length   ? localeID   : @"fr_FR";
    id_.languageID   = [id_.localeID stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    id_.timeZoneID   = timeZoneID.length ? timeZoneID : @"Europe/Paris";

    // Identifiers, retried until nothing collides with an existing container.
    // UUID collisions are impossible in practice; the loop exists for the
    // 10-character serial, and it is cheap.
    for (int attempt = 0; attempt < 64; attempt++) {
        id_.idfv         = VSUpperUUID();
        id_.idfa         = VSUpperUUID();
        id_.platformUUID = VSUpperUUID();
        id_.serialNumber = VSRandomSerial();
        id_.wifiMAC      = VSRandomMAC();
        id_.bluetoothMAC = VSRandomMAC();
        if (taken.count == 0 || ![id_.uniqueValues intersectsSet:taken]) break;
        VSLogW(@"identity", @"identifier collision, regenerating (attempt %d)", attempt + 1);
    }

    NSString *first = kFirstNames[VSRand(kFirstNameCount)];
    id_.deviceName = (VSRand(100) < 65)
        ? [NSString stringWithFormat:@"iPhone de %@", first]
        : @"iPhone";

    VSLogI(@"identity", @"generated %@", id_.shortDescription);
    return id_;
}

#pragma mark - Geometry from the model table

+ (CGSize)nativePixelSizeForMachine:(NSString *)machine scale:(CGFloat *)outScale {
    for (int i = 0; i < kModelCount; i++) {
        if ([machine isEqualToString:@(kModels[i].machine)]) {
            if (outScale) *outScale = kModels[i].scale;
            return CGSizeMake(kModels[i].wPx, kModels[i].hPx);
        }
    }
    if (outScale) *outScale = 0;
    return CGSizeZero;
}

+ (CGSize)realNativePixelSize:(CGFloat *)outScale {
    return [self nativePixelSizeForMachine:[self realMachine] scale:outScale];
}

+ (instancetype)generateForRealDeviceWithLocale:(NSString *)localeID
                                       timeZone:(NSString *)timeZoneID
                                          taken:(NSSet<NSString *> *)taken {
    CGFloat scale = 0;
    CGSize px = [self realNativePixelSize:&scale];
    return [self generateForScreenPixelSize:px
                                      scale:scale
                                  osVersion:[self realOSVersion]
                                    osBuild:[self realOSBuild]
                                     locale:localeID
                                   timeZone:timeZoneID
                                      taken:taken];
}

#pragma mark - Serialisation

// Short, stable keys: they are written into every container's plist and must
// never be renamed without a schema migration.
static NSString *const kK[] = {
    @"mach", @"board", @"mkt", @"mem", @"cpu", @"pcpu", @"osv", @"osb",
    @"dar", @"idfv", @"idfa", @"puuid", @"serial", @"wmac", @"bmac",
    @"dname", @"loc", @"lang", @"tz",
};

- (NSDictionary *)dictionaryRepresentation {
    return @{
        kK[0]:  _machine ?: @"", kK[1]:  _boardID ?: @"",
        kK[2]:  _marketingName ?: @"",
        kK[3]:  @(_memSize), kK[4]: @(_cpuCount), kK[5]: @(_physicalCPUCount),
        kK[6]:  _osVersion ?: @"", kK[7]: _osBuild ?: @"", kK[8]: _darwinKernel ?: @"",
        kK[9]:  _idfv ?: @"", kK[10]: _idfa ?: @"", kK[11]: _platformUUID ?: @"",
        kK[12]: _serialNumber ?: @"", kK[13]: _wifiMAC ?: @"", kK[14]: _bluetoothMAC ?: @"",
        kK[15]: _deviceName ?: @"", kK[16]: _localeID ?: @"",
        kK[17]: _languageID ?: @"", kK[18]: _timeZoneID ?: @"",
    };
}

+ (instancetype)identityWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    VSIdentity *i = [VSIdentity new];
    i.machine          = d[kK[0]];  i.boardID       = d[kK[1]];
    i.marketingName    = d[kK[2]];
    i.memSize          = [d[kK[3]] unsignedLongLongValue];
    i.cpuCount         = [d[kK[4]] intValue];
    i.physicalCPUCount = [d[kK[5]] intValue];
    i.osVersion        = d[kK[6]];  i.osBuild       = d[kK[7]];
    i.darwinKernel     = d[kK[8]];
    i.idfv             = d[kK[9]];  i.idfa          = d[kK[10]];
    i.platformUUID     = d[kK[11]]; i.serialNumber  = d[kK[12]];
    i.wifiMAC          = d[kK[13]]; i.bluetoothMAC  = d[kK[14]];
    i.deviceName       = d[kK[15]]; i.localeID      = d[kK[16]];
    i.languageID       = d[kK[17]]; i.timeZoneID    = d[kK[18]];

    // A stored identity missing its machine string is unusable: rather than
    // silently reporting an empty hw.machine (which no real phone does), refuse
    // it so the caller regenerates.
    if (i.machine.length == 0 || i.idfv.length == 0) {
        VSLogE(@"identity", @"stored identity incomplete, rejecting");
        return nil;
    }
    if (i.darwinKernel.length == 0) i.darwinKernel = VSDarwinKernelForOS(i.osVersion ?: @"26.6.1");
    return i;
}

#pragma mark - Derived

- (NSSet<NSString *> *)uniqueValues {
    NSMutableSet *s = [NSMutableSet set];
    for (NSString *v in @[ _idfv ?: @"", _idfa ?: @"", _platformUUID ?: @"",
                           _serialNumber ?: @"", _wifiMAC ?: @"", _bluetoothMAC ?: @"" ]) {
        if (v.length) [s addObject:v];
    }
    return s;
}

- (NSString *)expectedUserAgentWithAppVersion:(NSString *)appVersion
                                    pixelSize:(CGSize)pxSize
                                        scale:(CGFloat)scale {
    NSString *osU = [(_osVersion ?: @"") stringByReplacingOccurrencesOfString:@"."
                                                                   withString:@"_"];
    int w = (int)lround(MIN(pxSize.width, pxSize.height));
    int h = (int)lround(MAX(pxSize.width, pxSize.height));
    return [NSString stringWithFormat:
            @"Instagram %@ (%@; iOS %@; %@; %@; scale=%.2f; %dx%d; %@)",
            appVersion ?: @"443.0.0.0.0", _machine ?: @"", osU,
            _localeID ?: @"", _languageID ?: @"", (double)scale, w, h, _osBuild ?: @""];
}

- (NSString *)shortDescription {
    return [NSString stringWithFormat:@"%@ · iOS %@ · %@",
            _marketingName.length ? _marketingName : (_machine ?: @"?"),
            _osVersion ?: @"?", _serialNumber ?: @"?"];
}

@end
