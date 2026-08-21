//  VSIdentity.m

#import "VSIdentity.h"
#import "VSLog.h"

/// One row per model iOS 26 can actually run (A13 and up: iPhone 11 and later).
/// Pixel size is the NATIVE portrait resolution, which is what Instagram's UA
/// reports and what therefore has to agree with the model name.
typedef struct {
    const char *machine;   // hw.machine
    const char *board;     // hw.model
    const char *name;      // marketing name, our UI only
    int wPx, hPx;          // native portrait pixels
    int scale;
    int memGB;             // hw.memsize
    int cores;             // hw.ncpu / hw.logicalcpu / hw.physicalcpu
} VSModelSpec;

static const VSModelSpec kModels[] = {
    // A13
    { "iPhone12,1", "N104AP", "iPhone 11",           828, 1792, 2, 4, 6 },
    { "iPhone12,3", "D421AP", "iPhone 11 Pro",      1125, 2436, 3, 4, 6 },
    { "iPhone12,5", "D431AP", "iPhone 11 Pro Max",  1242, 2688, 3, 4, 6 },
    // A14
    { "iPhone13,1", "D52gAP", "iPhone 12 mini",     1080, 2340, 3, 4, 6 },
    { "iPhone13,2", "D53gAP", "iPhone 12",          1170, 2532, 3, 4, 6 },
    { "iPhone13,3", "D53pAP", "iPhone 12 Pro",      1170, 2532, 3, 6, 6 },
    { "iPhone13,4", "D54pAP", "iPhone 12 Pro Max",  1284, 2778, 3, 6, 6 },
    // A15
    { "iPhone14,4", "D16AP",  "iPhone 13 mini",     1080, 2340, 3, 4, 6 },
    { "iPhone14,5", "D17AP",  "iPhone 13",          1170, 2532, 3, 4, 6 },
    { "iPhone14,2", "D63AP",  "iPhone 13 Pro",      1170, 2532, 3, 6, 6 },
    { "iPhone14,3", "D64AP",  "iPhone 13 Pro Max",  1284, 2778, 3, 6, 6 },
    { "iPhone14,7", "D27AP",  "iPhone 14",          1170, 2532, 3, 6, 6 },
    { "iPhone14,8", "D28AP",  "iPhone 14 Plus",     1284, 2778, 3, 6, 6 },
    // A16
    { "iPhone15,2", "D73AP",  "iPhone 14 Pro",      1179, 2556, 3, 6, 6 },
    { "iPhone15,3", "D74AP",  "iPhone 14 Pro Max",  1290, 2796, 3, 6, 6 },
    { "iPhone15,4", "D37AP",  "iPhone 15",          1179, 2556, 3, 6, 6 },
    { "iPhone15,5", "D38AP",  "iPhone 15 Plus",     1290, 2796, 3, 6, 6 },
    // A17 Pro
    { "iPhone16,1", "D83AP",  "iPhone 15 Pro",      1179, 2556, 3, 8, 6 },
    { "iPhone16,2", "D84AP",  "iPhone 15 Pro Max",  1290, 2796, 3, 8, 6 },
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

// VSIDENTITY_PART3
