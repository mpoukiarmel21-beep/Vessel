//  VSHookLocale.m — identity layer: time zone + locale (see VSHookLocale.h).

#import "VSHookLocale.h"
#import "../Core/VSIdentity.h"
#import "../Core/VSLog.h"
#import <objc/runtime.h>

// Constructed once at install, validated, then frozen and kept strong.
static NSTimeZone            *gTZ     = nil;
static NSLocale              *gLocale = nil;
static NSArray<NSString *>   *gLangs  = nil;
static BOOL                   gInstalled = NO;

static NSTimeZone *(*orig_systemTZ)(id, SEL)      = NULL;
static NSTimeZone *(*orig_localTZ)(id, SEL)       = NULL;
static NSTimeZone *(*orig_defaultTZ)(id, SEL)     = NULL;
static NSLocale   *(*orig_currentLocale)(id, SEL) = NULL;
static NSLocale   *(*orig_autoLocale)(id, SEL)    = NULL;
static NSArray    *(*orig_prefLangs)(id, SEL)     = NULL;

static NSTimeZone *vs_systemTZ(id s, SEL c)      { return gTZ ?: orig_systemTZ(s, c); }
static NSTimeZone *vs_localTZ(id s, SEL c)       { return gTZ ?: orig_localTZ(s, c); }
static NSTimeZone *vs_defaultTZ(id s, SEL c)     { return gTZ ?: orig_defaultTZ(s, c); }
static NSLocale   *vs_currentLocale(id s, SEL c) { return gLocale ?: orig_currentLocale(s, c); }
static NSLocale   *vs_autoLocale(id s, SEL c)    { return gLocale ?: orig_autoLocale(s, c); }
static NSArray    *vs_prefLangs(id s, SEL c)     { return gLangs.count ? gLangs : orig_prefLangs(s, c); }

/// Class methods live on the metaclass.
static BOOL VSSwizzleClassM(Class cls, SEL sel, void *repl, void **outOrig) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(object_getClass(cls), sel);
    if (!m) return NO;
    *outOrig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)repl);
    return YES;
}

@implementation VSHookLocale

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)installWithIdentity:(VSIdentity *)identity {
    if (gInstalled) return YES;
    if (!identity) { VSLogE(@"locale", @"refusing to install: no identity"); return NO; }

    gTZ     = identity.timeZoneID.length ? [NSTimeZone timeZoneWithName:identity.timeZoneID]    : nil;
    gLocale = identity.localeID.length   ? [NSLocale localeWithLocaleIdentifier:identity.localeID] : nil;
    gLangs  = identity.languageID.length ? @[ identity.languageID ] : nil;

    BOOL any = NO;
    if (gTZ) {
        any |= VSSwizzleClassM(NSTimeZone.class, @selector(systemTimeZone),  (void *)vs_systemTZ,  (void **)&orig_systemTZ);
        any |= VSSwizzleClassM(NSTimeZone.class, @selector(localTimeZone),   (void *)vs_localTZ,   (void **)&orig_localTZ);
        any |= VSSwizzleClassM(NSTimeZone.class, @selector(defaultTimeZone), (void *)vs_defaultTZ, (void **)&orig_defaultTZ);
    }
    if (gLocale) {
        any |= VSSwizzleClassM(NSLocale.class, @selector(currentLocale),             (void *)vs_currentLocale, (void **)&orig_currentLocale);
        any |= VSSwizzleClassM(NSLocale.class, @selector(autoupdatingCurrentLocale), (void *)vs_autoLocale,    (void **)&orig_autoLocale);
    }
    if (gLangs)
        any |= VSSwizzleClassM(NSLocale.class, @selector(preferredLanguages), (void *)vs_prefLangs, (void **)&orig_prefLangs);

    gInstalled = YES;
    VSLogI(@"locale", @"tz=%@ locale=%@ langs=%@ (swizzled=%@)",
           gTZ.name, gLocale.localeIdentifier, gLangs, any ? @"YES" : @"NO");
    return YES;
}

#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"locale hooks not installed";
    if (gTZ && ![[NSTimeZone systemTimeZone].name isEqualToString:gTZ.name])
        return [NSString stringWithFormat:@"systemTimeZone reads %@", [NSTimeZone systemTimeZone].name];
    if (gLocale && ![[NSLocale currentLocale].localeIdentifier isEqualToString:gLocale.localeIdentifier])
        return [NSString stringWithFormat:@"currentLocale reads %@", [NSLocale currentLocale].localeIdentifier];
    return nil;
}

@end
