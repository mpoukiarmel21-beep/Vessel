//  VSHookDevice.m — layer 5: device fingerprint spoofing (see VSHookDevice.h).

#import "VSHookDevice.h"
#import "../Core/VSIdentity.h"
#import "../Core/VSLog.h"
#import "../vendor/fishhook/fishhook.h"
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

// C-string / scalar globals, filled once at install from the frozen identity.
// The sysctl/uname replacements run on ARBITRARY threads — including C threads
// with no autorelease pool — so they must touch only these plain C globals and
// never an NSString's -UTF8String, whose buffer can be autoreleased.
static char     *gMachine, *gBoardID, *gOSBuild, *gOSVersion, *gDarwinKernel;
static char     *gSerial,  *gPlatformUUID;
static uint64_t  gMemSize;
static int       gCPU, gPhysCPU;
static BOOL      gInstalled = NO;
static BOOL      gSpoofOS   = NO;   // only when the real device shares the major

// ObjC-side spoof values, used only from ObjC swizzles (always on a thread that
// has a pool). Strong for the process lifetime.
static NSUUID   *gIDFV, *gIDFA;
static NSString *gOSVersionNS;

static char *VSStrDup(NSString *s) { return s.length ? strdup(s.UTF8String) : NULL; }

#pragma mark - sysctl reply helpers (the buffer-size protocol)

/// Standard sysctl OUT semantics, restated once: a NULL oldp is a size query; a
/// too-small buffer is -1/ENOMEM; otherwise copy and report the exact length.
/// One helper serves both the string nodes (n = strlen+1) and the integer nodes.
static int vs_reply_bytes(const void *src, size_t n, void *oldp, size_t *oldlenp) {
    if (!oldlenp)     { errno = EINVAL; return -1; }
    if (oldp == NULL) { *oldlenp = n;   return 0;  }
    if (*oldlenp < n) { errno = ENOMEM; return -1; }
    memcpy(oldp, src, n);
    *oldlenp = n;
    return 0;
}
static int vs_reply_str(const char *s, void *oldp, size_t *oldlenp) {
    return vs_reply_bytes(s, strlen(s) + 1, oldp, oldlenp);
}

/// +1 CFString, released by the caller — the "Create" ownership contract IOKit
/// and MobileGestalt callers already expect from these functions.
static CFStringRef vs_cfstr(const char *s) {
    return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

#pragma mark - sysctlbyname / sysctl / uname

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t)       = NULL;
static int (*orig_uname)(struct utsname *)                                      = NULL;

static int vs_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // Writes (newp) and every name we do not spoof fall straight through.
    if (!gInstalled || newp != NULL || name == NULL)
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);

    if (gMachine && !strcmp(name, "hw.machine")) return vs_reply_str(gMachine, oldp, oldlenp);
    if (gBoardID && !strcmp(name, "hw.model"))   return vs_reply_str(gBoardID, oldp, oldlenp);

    if (gSpoofOS) {
        if (gOSBuild      && !strcmp(name, "kern.osversion"))        return vs_reply_str(gOSBuild, oldp, oldlenp);
        if (gOSVersion    && !strcmp(name, "kern.osproductversion")) return vs_reply_str(gOSVersion, oldp, oldlenp);
        if (gDarwinKernel && !strcmp(name, "kern.osrelease"))        return vs_reply_str(gDarwinKernel, oldp, oldlenp);
    }
    if (gMemSize && !strcmp(name, "hw.memsize")) {
        uint64_t v = gMemSize; return vs_reply_bytes(&v, sizeof v, oldp, oldlenp);
    }
    if (gCPU && (!strcmp(name, "hw.ncpu") || !strcmp(name, "hw.logicalcpu") ||
                 !strcmp(name, "hw.logicalcpu_max") || !strcmp(name, "hw.activecpu"))) {
        int v = gCPU; return vs_reply_bytes(&v, sizeof v, oldp, oldlenp);
    }
    if (gPhysCPU && (!strcmp(name, "hw.physicalcpu") || !strcmp(name, "hw.physicalcpu_max"))) {
        int v = gPhysCPU; return vs_reply_bytes(&v, sizeof v, oldp, oldlenp);
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
static int vs_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // The MIB form must agree with the name form, or code that calls sysctl(3)
    // directly (CTL_HW/HW_MACHINE) would still see the real model.
    if (!gInstalled || newp != NULL || name == NULL || namelen < 2)
        return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (name[0] == CTL_HW) {
        if (gMachine && name[1] == HW_MACHINE) return vs_reply_str(gMachine, oldp, oldlenp);
        if (gBoardID && name[1] == HW_MODEL)   return vs_reply_str(gBoardID, oldp, oldlenp);
        if (gMemSize && name[1] == HW_MEMSIZE) { uint64_t v = gMemSize; return vs_reply_bytes(&v, sizeof v, oldp, oldlenp); }
        if (gCPU     && name[1] == HW_NCPU)    { int v = gCPU;          return vs_reply_bytes(&v, sizeof v, oldp, oldlenp); }
    } else if (name[0] == CTL_KERN && gSpoofOS) {
        if (gOSBuild      && name[1] == KERN_OSVERSION) return vs_reply_str(gOSBuild, oldp, oldlenp);
        if (gDarwinKernel && name[1] == KERN_OSRELEASE) return vs_reply_str(gDarwinKernel, oldp, oldlenp);
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static int vs_uname(struct utsname *u) {
    int rc = orig_uname(u);
    if (rc != 0 || !gInstalled || u == NULL) return rc;   // uname().machine is the model on Darwin
    if (gMachine)                   strlcpy(u->machine, gMachine,      sizeof(u->machine));
    if (gSpoofOS && gDarwinKernel)  strlcpy(u->release, gDarwinKernel, sizeof(u->release));
    return rc;
}

#pragma mark - IOKit / MobileGestalt (swap content, never fabricate visibility)

// Declared with primitive types on purpose: the file then needs neither the IOKit
// headers nor a link against the (private) IOKit framework. fishhook binds purely
// by symbol name, and io_registry_entry_t is just a mach_port_t (unsigned int).
static CFTypeRef (*orig_ioregProp)(unsigned int, CFStringRef, CFAllocatorRef, uint32_t)                = NULL;
static CFTypeRef (*orig_ioregSearch)(unsigned int, const char *, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef)                                                     = NULL;

/// Replace the value only when the app actually received one of the matching
/// type. A NULL/other-typed original is passed through untouched: we change what
/// a read returns, we never turn a denied read into a value.
static CFTypeRef vs_swap(CFTypeRef v, CFStringRef key, CFStringRef want, const char *val) {
    if (val && v && CFGetTypeID(v) == CFStringGetTypeID() && CFEqual(key, want)) {
        CFRelease(v);
        return vs_cfstr(val);
    }
    return v;
}

static CFTypeRef vs_ioregProp(unsigned int entry, CFStringRef key, CFAllocatorRef a, uint32_t o) {
    CFTypeRef v = orig_ioregProp(entry, key, a, o);
    if (!gInstalled || key == NULL) return v;
    v = vs_swap(v, key, CFSTR("IOPlatformUUID"),         gPlatformUUID);
    v = vs_swap(v, key, CFSTR("IOPlatformSerialNumber"), gSerial);
    return v;
}

static CFTypeRef vs_ioregSearch(unsigned int entry, const char *plane, CFStringRef key,
                                CFAllocatorRef a, uint32_t o) {
    CFTypeRef v = orig_ioregSearch(entry, plane, key, a, o);
    if (!gInstalled || key == NULL) return v;
    v = vs_swap(v, key, CFSTR("IOPlatformUUID"),         gPlatformUUID);
    v = vs_swap(v, key, CFSTR("IOPlatformSerialNumber"), gSerial);
    return v;
}

static CFTypeRef vs_MGCopyAnswer(CFStringRef q) {
    CFTypeRef v = orig_MGCopyAnswer(q);
    if (!gInstalled || q == NULL) return v;
    v = vs_swap(v, q, CFSTR("ProductType"),  gMachine);
    v = vs_swap(v, q, CFSTR("SerialNumber"), gSerial);
    if (gSpoofOS) {
        v = vs_swap(v, q, CFSTR("ProductVersion"), gOSVersion);
        v = vs_swap(v, q, CFSTR("BuildVersion"),   gOSBuild);
    }
    return v;
}
#pragma mark - ObjC swizzles (UIDevice / AdSupport / ATT)

static NSString *(*orig_systemVersion)(id, SEL) = NULL;
static NSUUID   *(*orig_idfv)(id, SEL)          = NULL;
static NSUUID   *(*orig_idfa)(id, SEL)          = NULL;
static BOOL      (*orig_adTracking)(id, SEL)    = NULL;
static NSInteger (*orig_attStatus)(id, SEL)     = NULL;

// -[UIDevice name] is deliberately NOT swizzled: since iOS 16 it returns a
// generic "iPhone" to apps without the user-assigned-device-name entitlement
// (Instagram has none), so projecting a personalised name would be an
// inconsistency, not a disguise. deviceName stays in the identity for the
// uniqueness/collision domain only.
static NSString *vs_systemVersion(id s, SEL c) { return (gSpoofOS && gOSVersionNS) ? gOSVersionNS : orig_systemVersion(s, c); }
static NSUUID   *vs_idfv(id s, SEL c)          { return gIDFV ?: orig_idfv(s, c); }
static NSUUID   *vs_idfa(id s, SEL c)          { return gIDFA ?: orig_idfa(s, c); }
// A unique, non-zero IDFA is only self-consistent if tracking reads as
// authorised; a real device with tracking denied reports the all-zero IDFA. So
// these travel together with the spoofed IDFA: authorised (3) + enabled.
static BOOL      vs_adTracking(id s, SEL c)    { return gIDFA ? YES : orig_adTracking(s, c); }
static NSInteger vs_attStatus(id s, SEL c)     { return gIDFA ? 3   : orig_attStatus(s, c); }

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
#pragma mark - Install

@implementation VSHookDevice

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installWithIdentity:(VSIdentity *)identity {
    if (gInstalled) return YES;
    if (!identity || identity.machine.length == 0) {
        VSLogE(@"device", @"refusing to install: no identity/machine");
        return NO;
    }

    // OS-version spoof is gated on the real device sharing the same major (§3.2):
    // claiming an OS the real frameworks are not is how you send Instagram down a
    // code path that does not exist here and crash it. Model + identifiers are
    // safe regardless and always applied.
    int realMajor = [VSIdentity realOSVersion].intValue;
    int idMajor   = identity.osVersion.intValue;
    gSpoofOS = (realMajor > 0 && realMajor == idMajor);

    gMachine      = VSStrDup(identity.machine);
    gBoardID      = VSStrDup(identity.boardID);
    gOSBuild      = VSStrDup(identity.osBuild);
    gOSVersion    = VSStrDup(identity.osVersion);
    gDarwinKernel = VSStrDup(identity.darwinKernel);
    gSerial       = VSStrDup(identity.serialNumber);
    gPlatformUUID = VSStrDup(identity.platformUUID);
    gMemSize      = identity.memSize;
    gCPU          = identity.cpuCount;
    gPhysCPU      = identity.physicalCPUCount;

    gIDFV        = identity.idfv.length ? [[NSUUID alloc] initWithUUIDString:identity.idfv] : nil;
    gIDFA        = identity.idfa.length ? [[NSUUID alloc] initWithUUIDString:identity.idfa] : nil;
    gOSVersionNS = [identity.osVersion copy];

    // Resolve every C original up front. sysctl/sysctlbyname/uname are essential;
    // a replacement that later called a NULL original would crash the app instead
    // of spoofing it, so if even one is missing we install nothing. IOKit / MG are
    // optional — present only if the app already links them — so a miss there just
    // drops that one rebinding.
    orig_sysctlbyname = (int (*)(const char *, void *, size_t *, void *, size_t))dlsym(RTLD_DEFAULT, "sysctlbyname");
    orig_sysctl       = (int (*)(int *, u_int, void *, size_t *, void *, size_t))dlsym(RTLD_DEFAULT, "sysctl");
    orig_uname        = (int (*)(struct utsname *))dlsym(RTLD_DEFAULT, "uname");
    if (!orig_sysctlbyname || !orig_sysctl || !orig_uname) {
        VSLogE(@"device", @"refusing to install: essential libc symbol missing (byname=%d sysctl=%d uname=%d)",
               orig_sysctlbyname != NULL, orig_sysctl != NULL, orig_uname != NULL);
        return NO;
    }
    orig_ioregProp    = (CFTypeRef (*)(unsigned int, CFStringRef, CFAllocatorRef, uint32_t))dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    orig_ioregSearch  = (CFTypeRef (*)(unsigned int, const char *, CFStringRef, CFAllocatorRef, uint32_t))dlsym(RTLD_DEFAULT, "IORegistryEntrySearchCFProperty");
    orig_MGCopyAnswer = (CFTypeRef (*)(CFStringRef))dlsym(RTLD_DEFAULT, "MGCopyAnswer");

    gInstalled = YES;   // globals + essential origs are ready; replacements may fire now

    struct rebinding rb[6];
    size_t n = 0;
    rb[n++] = (struct rebinding){ "sysctlbyname", (void *)vs_sysctlbyname, (void **)&orig_sysctlbyname };
    rb[n++] = (struct rebinding){ "sysctl",       (void *)vs_sysctl,       (void **)&orig_sysctl };
    rb[n++] = (struct rebinding){ "uname",        (void *)vs_uname,        (void **)&orig_uname };
    if (orig_ioregProp)    rb[n++] = (struct rebinding){ "IORegistryEntryCreateCFProperty", (void *)vs_ioregProp,   (void **)&orig_ioregProp };
    if (orig_ioregSearch)  rb[n++] = (struct rebinding){ "IORegistryEntrySearchCFProperty", (void *)vs_ioregSearch, (void **)&orig_ioregSearch };
    if (orig_MGCopyAnswer) rb[n++] = (struct rebinding){ "MGCopyAnswer",                    (void *)vs_MGCopyAnswer,(void **)&orig_MGCopyAnswer };
    int rc = rebind_symbols(rb, n);
    if (rc != 0) VSLogW(@"device", @"rebind_symbols returned %d", rc);

    // ObjC accessors app code calls directly. systemVersion self-gates on
    // gSpoofOS, so it is safe to swizzle unconditionally.
    VSSwizzle(UIDevice.class, @selector(systemVersion),       (void *)vs_systemVersion, (void **)&orig_systemVersion);
    VSSwizzle(UIDevice.class, @selector(identifierForVendor), (void *)vs_idfv,          (void **)&orig_idfv);

    Class asim = NSClassFromString(@"ASIdentifierManager");
    if (asim && gIDFA) {
        VSSwizzle(asim, @selector(advertisingIdentifier),        (void *)vs_idfa,       (void **)&orig_idfa);
        VSSwizzle(asim, @selector(isAdvertisingTrackingEnabled), (void *)vs_adTracking, (void **)&orig_adTracking);
    }
    Class att = NSClassFromString(@"ATTrackingManager");
    if (att && gIDFA)
        VSSwizzleClassM(att, @selector(trackingAuthorizationStatus), (void *)vs_attStatus, (void **)&orig_attStatus);

    VSLogI(@"device", @"identity spoofed: %s / %s · spoofOS=%@ (real %@ / claim %@)",
           gMachine, gBoardID ?: "?", gSpoofOS ? @"YES" : @"NO",
           [VSIdentity realOSVersion], identity.osVersion);
    return YES;
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"device hooks not installed";

    char buf[256]; size_t len = sizeof buf;
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0)
        return @"sysctlbyname(hw.machine) failed";
    if (gMachine && strcmp(buf, gMachine) != 0)
        return [NSString stringWithFormat:@"hw.machine reads '%s', expected '%s'", buf, gMachine];

    int mib[2] = { CTL_HW, HW_MACHINE };
    char mbuf[256]; size_t mlen = sizeof mbuf;
    if (sysctl(mib, 2, mbuf, &mlen, NULL, 0) == 0 && gMachine && strcmp(mbuf, gMachine) != 0)
        return [NSString stringWithFormat:@"sysctl(HW_MACHINE) reads '%s'", mbuf];

    struct utsname u;
    if (uname(&u) == 0 && gMachine && strcmp(u.machine, gMachine) != 0)
        return [NSString stringWithFormat:@"uname().machine reads '%s'", u.machine];

    UIDevice *d = UIDevice.currentDevice;
    if (gIDFV && ![d.identifierForVendor.UUIDString isEqualToString:gIDFV.UUIDString])
        return [NSString stringWithFormat:@"identifierForVendor reads %@", d.identifierForVendor.UUIDString];
    if (gSpoofOS && gOSVersionNS && ![d.systemVersion isEqualToString:gOSVersionNS])
        return [NSString stringWithFormat:@"systemVersion reads %@", d.systemVersion];

    if (gIDFA) {
        NSUUID *ad = ASIdentifierManager.sharedManager.advertisingIdentifier;
        if (![ad.UUIDString isEqualToString:gIDFA.UUIDString])
            return [NSString stringWithFormat:@"advertisingIdentifier reads %@", ad.UUIDString];
    }
    return nil;
}

@end
