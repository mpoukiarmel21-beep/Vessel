//  VSFloatingButton.m

#import "VSFloatingButton.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSContainer.h"
#import "../Core/VSPaths.h"
#import "../Core/VSStore.h"

static NSString *const kEdgeKey = @"btnEdge";   // "L" / "R"
static NSString *const kFracKey = @"btnFrac";   // vertical position, 0..1

@interface VSFloatingButton ()
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) CAShapeLayer *ring;
@property (nonatomic, strong) CAShapeLayer *cardBack;   // logo: rear card (outline)
@property (nonatomic, strong) CAShapeLayer *cardFront;  // logo: front card (filled)
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIView  *badge;
@property (nonatomic, strong) VSStore *prefs;
@property (nonatomic, assign) NSInteger dimToken;
@property (nonatomic, assign) BOOL positioned;
@end

@implementation VSFloatingButton

- (instancetype)init {
    CGFloat s = [VSTheme floatingButtonSize];
    if ((self = [super initWithFrame:CGRectMake(0, 0, s, s)])) {
        NSString *p = [[VSPaths vesselRoot] stringByAppendingPathComponent:@"diag/ui.plist"];
        _prefs = [[VSStore alloc] initWithPath:p label:@"ui"];

        // Shadow on the button itself; the blur is clipped to the circle inside.
        self.layer.shadowColor   = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius  = 10;
        self.layer.shadowOffset  = CGSizeMake(0, 4);

        _blur = [[UIVisualEffectView alloc] initWithEffect:[VSTheme buttonBlur]];
        _blur.userInteractionEnabled = NO;
        _blur.clipsToBounds = YES;
        [self addSubview:_blur];

        _ring = [CAShapeLayer layer];
        _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineWidth = 2.0;
        [self.layer addSublayer:_ring];

        // Code-drawn "stacked cards" mark: two overlapping rounded squares that
        // read as several identities layered together — Vessel's whole idea. No
        // bundled asset, so it scales crisply and tints with the brand color.
        _cardBack = [CAShapeLayer layer];
        _cardBack.fillColor = UIColor.clearColor.CGColor;
        _cardBack.lineWidth = 2.4;
        _cardBack.lineJoin = kCALineJoinRound;
        [self.layer addSublayer:_cardBack];

        _cardFront = [CAShapeLayer layer];
        _cardFront.lineWidth = 2.4;
        _cardFront.lineJoin = kCALineJoinRound;
        [self.layer addSublayer:_cardFront];

        _badge = [UIView new];
        _badge.backgroundColor = [VSTheme accent];
        _badge.layer.borderColor = UIColor.systemBackgroundColor.CGColor;
        _badge.layer.borderWidth = 2.0;
        [self addSubview:_badge];

        _badgeLabel = [UILabel new];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        _badgeLabel.textColor = UIColor.whiteColor;
        [_badge addSubview:_badgeLabel];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
        // Hold-in-place opens the quick switcher. The default 0.5 s / 10 pt slop
        // means a drag (which moves further) still falls through to the pan, and a
        // quick tap still falls through to the tap — the three never collide.
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:hold];

        [self refresh];
        [self wake];
    }
    return self;
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = self.bounds.size.width;
    self.layer.cornerRadius = s / 2.0;
    _blur.frame = self.bounds;
    _blur.layer.cornerRadius = s / 2.0;

    // Ring inset by half its width so the stroke sits fully inside the circle.
    CGFloat inset = _ring.lineWidth / 2.0;
    _ring.path = [UIBezierPath bezierPathWithOvalInRect:
                  CGRectInset(self.bounds, inset, inset)].CGPath;

    // Two rounded squares, offset diagonally: rear card up-right (outline), front
    // card down-left (filled). Sized/placed off the button so it scales with it.
    CGFloat card   = s * 0.40;
    CGFloat corner = card * 0.30;
    CGFloat g      = s * 0.115;               // diagonal offset between the cards
    CGPoint ctr    = CGPointMake(s / 2.0, s / 2.0);
    CGRect backR  = CGRectMake(ctr.x + g/2 - card/2, ctr.y - g/2 - card/2, card, card);
    CGRect frontR = CGRectMake(ctr.x - g/2 - card/2, ctr.y + g/2 - card/2, card, card);
    _cardBack.path  = [UIBezierPath bezierPathWithRoundedRect:backR  cornerRadius:corner].CGPath;
    _cardFront.path = [UIBezierPath bezierPathWithRoundedRect:frontR cornerRadius:corner].CGPath;

    CGFloat b = 20.0;
    _badge.frame = CGRectMake(s - b, -2, b, b);
    _badge.layer.cornerRadius = b / 2.0;
    _badgeLabel.frame = _badge.bounds;

    if (!_positioned) { [self restorePosition]; _positioned = YES; }
}

#pragma mark - Content

- (void)refresh {
    // One brand color throughout — no per-container tint. The active container is
    // conveyed by the panel, not by recolouring the button.
    UIColor *color = [VSTheme accent];
    _ring.strokeColor      = color.CGColor;
    _cardBack.strokeColor  = color.CGColor;
    _cardFront.fillColor   = color.CGColor;
    _cardFront.strokeColor = color.CGColor;
    _badge.backgroundColor = color;

    NSUInteger n = VSManager.shared.containers.count;
    _badgeLabel.text = n > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)n];
    _badge.hidden = (n <= 1);   // no badge when the default is the only container
}

#pragma mark - Gestures

- (void)handleTap:(UITapGestureRecognizer *)g {
    [self wake];
    [VSTheme hapticTap];
    if (self.onTap) self.onTap();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;   // fire once, on catch
    [self wake];
    [VSTheme hapticSnap];
    if (self.onLongPress) self.onLongPress();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    [self wake];
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        [self snapToNearestEdgeAnimated:YES];
    }
}

#pragma mark - Wake / auto-dim

- (void)wake {
    self.dimToken++;
    NSInteger tok = self.dimToken;
    [UIView animateWithDuration:0.2 animations:^{ self.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (tok != self.dimToken) return;         // a newer interaction superseded us
        [UIView animateWithDuration:0.4 animations:^{ self.alpha = 0.4; }];
    });
}

#pragma mark - Edge magnetism + persistence

/// Center range the button may occupy, inset by the safe area and the margin so
/// it never tucks under the notch, the home indicator, or off-screen.
- (void)edgeMinX:(CGFloat *)minX maxX:(CGFloat *)maxX
            minY:(CGFloat *)minY maxY:(CGFloat *)maxY {
    UIView *host = self.superview;
    CGRect b = host.bounds;
    UIEdgeInsets safe = host.safeAreaInsets;
    CGFloat s = self.bounds.size.width, m = [VSTheme floatingButtonMargin];
    *minX = safe.left  + m + s / 2.0;
    *maxX = b.size.width  - safe.right  - m - s / 2.0;
    *minY = safe.top   + m + s / 2.0;
    *maxY = b.size.height - safe.bottom - m - s / 2.0;
}

- (void)snapToNearestEdgeAnimated:(BOOL)animated {
    if (!self.superview) return;
    CGFloat minX, maxX, minY, maxY;
    [self edgeMinX:&minX maxX:&maxX minY:&minY maxY:&maxY];
    if (maxX < minX || maxY < minY) return;    // host not laid out yet

    CGFloat y = MIN(MAX(self.center.y, minY), maxY);
    BOOL left = self.center.x < self.superview.bounds.size.width / 2.0;
    CGFloat x = left ? minX : maxX;

    void (^move)(void) = ^{ self.center = CGPointMake(x, y); };
    if (animated) {
        [UIView animateWithDuration:0.45 delay:0
             usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:move completion:nil];
        [VSTheme hapticSnap];
    } else {
        move();
    }

    CGFloat frac = (maxY > minY) ? (y - minY) / (maxY - minY) : 0.5;
    [_prefs setObject:(left ? @"L" : @"R") forKey:kEdgeKey];
    [_prefs setObject:@(frac) forKey:kFracKey];
    [_prefs flushNow];
}

- (void)restorePosition {
    if (!self.superview) return;
    CGFloat minX, maxX, minY, maxY;
    [self edgeMinX:&minX maxX:&maxX minY:&minY maxY:&maxY];
    if (maxX < minX || maxY < minY) return;

    NSString *edge = [_prefs objectForKey:kEdgeKey];
    id fracObj = [_prefs objectForKey:kFracKey];
    // Default: lower-right, within comfortable thumb reach.
    BOOL left = [edge isEqualToString:@"L"];
    CGFloat frac = fracObj ? MIN(MAX([fracObj doubleValue], 0.0), 1.0) : 0.62;
    self.center = CGPointMake(left ? minX : maxX, minY + frac * (maxY - minY));
}

@end
