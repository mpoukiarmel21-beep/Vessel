//  VSTheme.h — design tokens for the whole UI layer.
//
//  One place owns colors, metrics, fonts, blur and haptics so every screen reads
//  the same and a change lands everywhere at once. Colors are adaptive
//  (light/dark) via UIColor system colors where it matters, so the panel looks
//  native inside Instagram in either appearance. The per-container accent is the
//  one bit of chrome that is NOT system-derived: it is what lets the user tell
//  accounts apart at a glance (button ring, card pastille).

#import <UIKit/UIKit.h>

@class VSContainer;

@interface VSTheme : NSObject

#pragma mark - Metrics

+ (CGFloat)floatingButtonSize;     // 56
+ (CGFloat)floatingButtonMargin;   // gap from the screen edge when docked
+ (CGFloat)panelCornerRadius;
+ (CGFloat)cardCornerRadius;
+ (CGFloat)controlCornerRadius;
+ (CGFloat)contentInset;           // standard horizontal padding

#pragma mark - Colors

+ (UIColor *)accent;               // default accent when a container has none
+ (UIColor *)danger;               // destructive actions (reset, delete)
+ (UIColor *)cardBackground;
+ (UIColor *)elevatedBackground;
+ (UIColor *)primaryText;
+ (UIColor *)secondaryText;
+ (UIColor *)separator;

#pragma mark - Dark-glass surfaces (Control-Center 2026)

// The main panel and quick-switch run FORCED dark (a frosted dark pane floating
// over Instagram), so these are fixed light-on-dark values rather than adaptive
// system colors — the look must not flip with the host's appearance.
+ (UIColor *)glassFill;            // translucent white card fill on the dark pane
+ (UIColor *)glassFillStrong;      // a slightly more present fill (secondary rows)
+ (UIColor *)glassStroke;          // hairline card border
+ (UIColor *)onGlassPrimary;       // near-white primary text on glass
+ (UIColor *)onGlassSecondary;     // muted secondary text on glass

#pragma mark - Signature gradient

// The one lively accent: a diagonal indigo→violet sweep used for the primary
// action, the active pastille/avatar and the floating button mark. A gradient
// (not a flat tint) is what carries the "2026" feel.
+ (UIColor *)accentGradientStart;
+ (UIColor *)accentGradientEnd;
/// @[(id)start.CGColor, (id)end.CGColor] — ready for a CAGradientLayer.
+ (NSArray *)accentGradientCGColors;
/// A diagonal (top-left→bottom-right) gradient layer with the accent colors set.
/// The caller assigns the frame. Corner radius/masking is the caller's job.
+ (CAGradientLayer *)accentGradientLayer;

/// Palette the create wizard offers. Stable order; index 0 is the default accent.
+ (NSArray<NSString *> *)paletteHex;

/// "#RRGGBB" (or "#RRGGBBAA") -> UIColor. Returns +accent on a malformed string,
/// so a bad stored value can never produce a nil color mid-layout.
+ (UIColor *)colorFromHex:(NSString *)hex;
/// UIColor -> "#RRGGBB" (opaque), for persisting a picked color.
+ (NSString *)hexFromColor:(UIColor *)color;

/// Deterministic palette pick from an id, so a container with no chosen color is
/// still stable and distinct across launches.
+ (NSString *)defaultColorHexForID:(NSString *)identifier;
/// The color to actually draw for a container: its chosen color, else the
/// deterministic default. Never nil.
+ (UIColor *)colorForContainer:(VSContainer *)container;

#pragma mark - Fonts

+ (UIFont *)fontTitle;             // panel titles
+ (UIFont *)fontHeadline;          // card names
+ (UIFont *)fontBody;
+ (UIFont *)fontCaption;           // metadata under a card
+ (UIFont *)fontMono;              // identity fields, logs

#pragma mark - Effects

+ (UIBlurEffect *)panelBlur;
+ (UIBlurEffect *)panelBlurDark;   // frosted DARK pane (forced-dark panel/quick-switch)
+ (UIBlurEffect *)buttonBlur;

#pragma mark - Haptics

+ (void)hapticTap;                 // light — button press
+ (void)hapticSnap;               // rigid — edge magnetism catch
+ (void)hapticSuccess;
+ (void)hapticWarning;

@end
