//  VSTheme.m

#import "VSTheme.h"
#import "../Core/VSContainer.h"

@implementation VSTheme

#pragma mark - Metrics

+ (CGFloat)floatingButtonSize    { return 56.0; }
+ (CGFloat)floatingButtonMargin  { return 10.0; }
+ (CGFloat)panelCornerRadius     { return 28.0; }
+ (CGFloat)cardCornerRadius      { return 16.0; }
+ (CGFloat)controlCornerRadius   { return 12.0; }
+ (CGFloat)contentInset          { return 20.0; }

#pragma mark - Colors

+ (NSArray<NSString *> *)paletteHex {
    // Index 0 is the default accent. Ten hues, spaced so adjacent containers in a
    // list never look the same, all legible on both light and dark surfaces.
    return @[ @"#5B8CFF", @"#34C759", @"#FF9500", @"#FF375F", @"#AF52DE",
              @"#00C7BE", @"#FFD60A", @"#FF6482", @"#64D2FF", @"#BF5AF2" ];
}

+ (UIColor *)accent            { return [self colorFromHex:@"#5E5CE6"]; } // indigo — one calm, professional brand color
+ (UIColor *)danger            { return UIColor.systemRedColor; }
+ (UIColor *)cardBackground    { return UIColor.secondarySystemBackgroundColor; }
+ (UIColor *)elevatedBackground{ return UIColor.tertiarySystemBackgroundColor; }
+ (UIColor *)primaryText       { return UIColor.labelColor; }
+ (UIColor *)secondaryText     { return UIColor.secondaryLabelColor; }
+ (UIColor *)separator         { return UIColor.separatorColor; }

+ (UIColor *)colorFromHex:(NSString *)hex {
    NSString *s = [[hex ?: @"" stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6 && s.length != 8) return self.accent;
    unsigned long long v = 0;
    if (![[NSScanner scannerWithString:s] scanHexLongLong:&v]) return self.accent;
    CGFloat r, g, b, a;
    if (s.length == 8) {
        r = ((v >> 24) & 0xFF) / 255.0; g = ((v >> 16) & 0xFF) / 255.0;
        b = ((v >>  8) & 0xFF) / 255.0; a = ( v        & 0xFF) / 255.0;
    } else {
        r = ((v >> 16) & 0xFF) / 255.0; g = ((v >> 8) & 0xFF) / 255.0;
        b = ( v        & 0xFF) / 255.0; a = 1.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

+ (NSString *)hexFromColor:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return self.paletteHex.firstObject;
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
}

+ (NSString *)defaultColorHexForID:(NSString *)identifier {
    NSArray<NSString *> *pal = self.paletteHex;
    NSUInteger h = 5381;                         // djb2, stable across launches
    for (NSUInteger i = 0; i < identifier.length; i++)
        h = ((h << 5) + h) + [identifier characterAtIndex:i];
    return pal[h % pal.count];
}

+ (UIColor *)colorForContainer:(VSContainer *)container {
    // One brand color everywhere. Per-container rainbow hues were noisy and read
    // as unprofessional; the active container is now shown by placement (the
    // header, the checkmark) rather than by tint. Kept as a method so callers and
    // the stored colorHex field stay source-compatible.
    (void)container;
    return [self accent];
}

#pragma mark - Fonts

/// System font with the rounded design when the OS offers it — the "tech but
/// friendly" feel — falling back to the plain system font otherwise.
+ (UIFont *)roundedSystemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rd = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rd ? [UIFont fontWithDescriptor:rd size:size] : base;
}

+ (UIFont *)fontTitle    { return [self roundedSystemFontOfSize:22 weight:UIFontWeightBold]; }
+ (UIFont *)fontHeadline { return [self roundedSystemFontOfSize:17 weight:UIFontWeightSemibold]; }
+ (UIFont *)fontBody     { return [self roundedSystemFontOfSize:15 weight:UIFontWeightRegular]; }
+ (UIFont *)fontCaption  { return [self roundedSystemFontOfSize:13 weight:UIFontWeightMedium]; }
+ (UIFont *)fontMono {
    return [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
}

#pragma mark - Effects

+ (UIBlurEffect *)panelBlur  { return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]; }
+ (UIBlurEffect *)buttonBlur { return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]; }

#pragma mark - Haptics

+ (void)hapticImpact:(UIImpactFeedbackStyle)style {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g prepare];
    [g impactOccurred];
}
+ (void)hapticTap  { [self hapticImpact:UIImpactFeedbackStyleLight]; }
+ (void)hapticSnap { [self hapticImpact:UIImpactFeedbackStyleRigid]; }

+ (void)hapticNotify:(UINotificationFeedbackType)type {
    UINotificationFeedbackGenerator *g = [UINotificationFeedbackGenerator new];
    [g prepare];
    [g notificationOccurred:type];
}
+ (void)hapticSuccess { [self hapticNotify:UINotificationFeedbackTypeSuccess]; }
+ (void)hapticWarning { [self hapticNotify:UINotificationFeedbackTypeWarning]; }

@end
