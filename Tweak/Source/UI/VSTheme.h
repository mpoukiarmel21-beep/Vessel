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
+ (UIBlurEffect *)buttonBlur;

#pragma mark - Haptics

+ (void)hapticTap;                 // light — button press
+ (void)hapticSnap;               // rigid — edge magnetism catch
+ (void)hapticSuccess;
+ (void)hapticWarning;

@end
