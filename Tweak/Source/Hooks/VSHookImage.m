//  VSHookImage.m

#import "VSHookImage.h"
#import "../Core/VSLog.h"
#import "../vendor/fishhook/fishhook.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>

static BOOL     gInstalled  = NO;
static BOOL     gMasked     = NO;                     // actively hiding right now
static uint32_t gSelfIndex  = 0;                      // our image's index in the real list
static const struct mach_header *gSelfHeader = NULL;  // our image's header (identity across shifts)
static const char *gSelfName = NULL;                  // our image's path, for logging / self-test

// The two libdyld entry points we rebind. Our own code always calls through these
// saved originals, so an internal call never re-enters the hook.
static uint32_t   (*orig_image_count)(void)     = NULL;
static const char *(*orig_image_name)(uint32_t) = NULL;

#pragma mark - Self-location

/// Re-point gSelfIndex at our image if the list shifted under us. Fast path: the
/// cached index still carries our header. Returns NO only if our image is gone
/// entirely — the caller then stops masking rather than hide the wrong slot. Header
/// lookups use the REAL _dyld_get_image_header (we never hook it), so a bare call
/// here can never recurse.
static BOOL VSRelocateSelf(void) {
    if (!gSelfHeader || !orig_image_count) return NO;
    uint32_t n = orig_image_count();
    if (gSelfIndex < n && _dyld_get_image_header(gSelfIndex) == gSelfHeader) return YES;
    for (uint32_t i = 0; i < n; i++)
        if (_dyld_get_image_header(i) == gSelfHeader) { gSelfIndex = i; return YES; }
    return NO;
}

#pragma mark - Rebound entry points

static uint32_t vs_image_count(void) {
    uint32_t n = orig_image_count();
    if (!gMasked || !VSRelocateSelf()) return n;
    return n > 0 ? n - 1 : n;
}

static const char *vs_image_name(uint32_t index) {
    if (!gMasked || !VSRelocateSelf()) return orig_image_name(index);
    // Our slot is removed: indices before it are unchanged, indices at or after it
    // address the next real image, so our own name is never handed back.
    return index < gSelfIndex ? orig_image_name(index) : orig_image_name(index + 1);
}
#pragma mark - Install

@implementation VSHookImage

+ (BOOL)isInstalled { return gInstalled; }

+ (BOOL)install {
    if (gInstalled) return YES;

    // Our own image: dladdr on a function we own hands back its mach header, a
    // stable identity even as image indices move.
    Dl_info info;
    if (dladdr((const void *)&vs_image_count, &info) == 0 || !info.dli_fbase) {
        VSLogW(@"image", @"cloak: dladdr miss — image list left genuine");
        return NO;
    }
    gSelfHeader = (const struct mach_header *)info.dli_fbase;
    gSelfName   = info.dli_fname;

    // Look the originals up first: a replacement that called a NULL original would
    // crash instead of falling back.
    orig_image_count = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "_dyld_image_count");
    orig_image_name  = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
    if (!orig_image_count || !orig_image_name) {
        VSLogW(@"image", @"cloak: dlsym miss (count=%p name=%p) — image list left genuine",
               (void *)orig_image_count, (void *)orig_image_name);
        gSelfHeader = NULL; gSelfName = NULL;
        return NO;
    }

    uint32_t n = orig_image_count();
    BOOL found = NO;
    for (uint32_t i = 0; i < n; i++)
        if (_dyld_get_image_header(i) == gSelfHeader) { gSelfIndex = i; found = YES; break; }
    if (!found) {
        VSLogW(@"image", @"cloak: own image not in list — image list left genuine");
        orig_image_count = NULL; orig_image_name = NULL; gSelfHeader = NULL; gSelfName = NULL;
        return NO;
    }

    struct rebinding rb[] = {
        { "_dyld_image_count",    (void *)vs_image_count, (void **)&orig_image_count },
        { "_dyld_get_image_name", (void *)vs_image_name,  (void **)&orig_image_name },
    };
    int rc = rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
    if (rc != 0) {
        VSLogW(@"image", @"cloak: rebind_symbols=%d — image list left genuine", rc);
        gSelfHeader = NULL; gSelfName = NULL;
        return NO;
    }

    gInstalled = YES;
    gMasked    = YES;
    VSLogI(@"image", @"cloak active: image %u hidden (%u -> %u)", gSelfIndex, n, n - 1);
    return YES;
}
#pragma mark - Verification

+ (NSString *)firstLeak {
    if (!gInstalled) return @"image cloak not installed";
    if (!gMasked)    return @"image cloak installed but not masking";
    if (!orig_image_count || !orig_image_name) return @"image cloak lost its originals";

    uint32_t real   = orig_image_count();
    uint32_t masked = vs_image_count();
    if (masked != (real > 0 ? real - 1 : real))
        return [NSString stringWithFormat:@"image count not reduced (%u vs %u)", masked, real];

    // Walk the list exactly as an integrity check would and confirm our own path
    // never appears through the hooked getter.
    for (uint32_t i = 0; i < masked; i++) {
        const char *nm = vs_image_name(i);
        if (nm && gSelfName && strcmp(nm, gSelfName) == 0)
            return [NSString stringWithFormat:@"own image still visible at %u", i];
    }
    return nil;
}

@end
