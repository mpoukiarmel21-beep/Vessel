//  VSQuickSwitchVC.m — "Bascule rapide", the long-press quick account switcher.

#import "VSQuickSwitchVC.h"
#import "VSUIController.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSContainer.h"
#import "../Core/VSIdentity.h"

#pragma mark - Carousel card

/// One container as a tappable card: gradient avatar + initial for the active one,
/// muted glass for the rest. Reports its cid on tap; the sheet does the switching.
@interface VSQuickCard : UIView
@property (nonatomic, strong) UIView *avatar;
@property (nonatomic, strong) CAGradientLayer *avatarGradient;
@property (nonatomic, copy)   NSString *cid;
@property (nonatomic, copy)   void (^onTap)(NSString *cid);
@end

@implementation VSQuickCard

- (instancetype)initWithContainer:(VSContainer *)c active:(BOOL)active {
    if ((self = [super initWithFrame:CGRectZero])) {
        _cid = [c.cid copy];
        self.backgroundColor = [VSTheme glassFill];
        self.layer.cornerRadius = 20;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = (active ? [VSTheme accentGradientEnd]
                                         : [VSTheme glassStroke]).CGColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _avatar = [UIView new];
        _avatar.layer.cornerRadius = 16;
        _avatar.layer.cornerCurve = kCACornerCurveContinuous;
        _avatar.clipsToBounds = YES;
        _avatar.backgroundColor = active ? UIColor.clearColor : [VSTheme glassFillStrong];
        _avatar.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_avatar];

        _avatarGradient = [VSTheme accentGradientLayer];
        _avatarGradient.hidden = !active;
        [_avatar.layer addSublayer:_avatarGradient];

        UILabel *initial = [UILabel new];
        initial.text = [self initialFor:c];
        initial.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        initial.textColor = active ? UIColor.whiteColor : [VSTheme onGlassSecondary];
        initial.textAlignment = NSTextAlignmentCenter;
        initial.translatesAutoresizingMaskIntoConstraints = NO;
        [_avatar addSubview:initial];

        UILabel *name = [UILabel new];
        name.text = c.name;
        name.font = [VSTheme fontHeadline];
        name.textColor = [VSTheme onGlassPrimary];
        name.textAlignment = NSTextAlignmentCenter;
        name.numberOfLines = 1;
        name.adjustsFontSizeToFitWidth = YES;
        name.minimumScaleFactor = 0.8;
        name.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:name];

        UILabel *sub = [UILabel new];
        sub.text = active ? @"Actif"
                          : (c.identity.marketingName.length ? c.identity.marketingName : @"iPhone");
        sub.font = [VSTheme fontCaption];
        sub.textColor = active ? [VSTheme accentGradientEnd] : [VSTheme onGlassSecondary];
        sub.textAlignment = NSTextAlignmentCenter;
        sub.numberOfLines = 1;
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:sub];

        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:148],
            [_avatar.topAnchor constraintEqualToAnchor:self.topAnchor constant:22],
            [_avatar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:56],
            [_avatar.heightAnchor constraintEqualToConstant:56],
            [initial.centerXAnchor constraintEqualToAnchor:_avatar.centerXAnchor],
            [initial.centerYAnchor constraintEqualToAnchor:_avatar.centerYAnchor],
            [name.topAnchor constraintEqualToAnchor:_avatar.bottomAnchor constant:12],
            [name.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [name.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
            [sub.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [sub.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [sub.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-16],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (NSString *)initialFor:(VSContainer *)c {
    NSString *n = [c.name stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return n.length ? [[n substringToIndex:1] uppercaseString] : @"•";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.avatarGradient.frame = self.avatar.bounds;
}

- (void)tapped { if (self.onTap) self.onTap(self.cid); }
@end

#pragma mark - Quick-switch sheet

@interface VSQuickSwitchVC ()
@property (nonatomic, assign) BOOL dismissFired;
@end

@implementation VSQuickSwitchVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;   // forced-dark frosted pane
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *bg = [[UIVisualEffectView alloc]
        initWithEffect:[VSTheme panelBlurDark]];
    bg.frame = self.view.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:bg];

    UILabel *title = [UILabel new];
    title.text = @"Bascule rapide";
    title.font = [VSTheme fontTitle];
    title.textColor = [VSTheme onGlassPrimary];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *hint = [UILabel new];
    hint.text = @"Choisissez un conteneur. Instagram redémarrera.";
    hint.font = [VSTheme fontCaption];
    hint.textColor = [VSTheme onGlassSecondary];
    hint.numberOfLines = 0;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hint];

    UIScrollView *scroll = [UIScrollView new];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *rowStack = [UIStackView new];
    rowStack.axis = UILayoutConstraintAxisHorizontal;
    rowStack.spacing = 12;
    rowStack.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 20);
    rowStack.layoutMarginsRelativeArrangement = YES;
    rowStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:rowStack];

    NSString *activeCid = VSManager.shared.active.cid;
    __weak VSQuickSwitchVC *weakSelf = self;
    for (VSContainer *c in VSManager.shared.containers) {
        BOOL active = [c.cid isEqualToString:activeCid];
        VSQuickCard *card = [[VSQuickCard alloc] initWithContainer:c active:active];
        card.onTap = ^(NSString *cid) { [weakSelf handleTapCid:cid]; };
        [rowStack addArrangedSubview:card];
    }

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18],
        [hint.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:18],
        [scroll.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.heightAnchor constraintEqualToConstant:188],
        [rowStack.topAnchor    constraintEqualToAnchor:scroll.topAnchor],
        [rowStack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [rowStack.leadingAnchor  constraintEqualToAnchor:scroll.leadingAnchor],
        [rowStack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [rowStack.heightAnchor constraintEqualToAnchor:scroll.heightAnchor],
    ]];
}

#pragma mark - Switching (records choice + relaunch, never re-points a live app)

- (void)handleTapCid:(NSString *)cid {
    VSContainer *active = VSManager.shared.active;
    if (!cid.length || [cid isEqualToString:active.cid]) {
        [VSTheme hapticTap];                       // already active — nothing to do
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    VSContainer *target = nil;
    for (VSContainer *x in VSManager.shared.containers)
        if ([x.cid isEqualToString:cid]) { target = x; break; }
    if (!target) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Basculer ?"
        message:[NSString stringWithFormat:
            @"Passer sur « %@ » ? Instagram va redémarrer pour appliquer le changement.",
            target.name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler"
        style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Basculer & redémarrer"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            if ([VSManager.shared selectContainerForNextLaunch:target.cid]) {
                [VSTheme hapticSuccess];
                [VSUIController relaunchToApplyContainerSwitch];
            }
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Dismiss lifecycle

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && !self.dismissFired) {
        self.dismissFired = YES;
        if (self.onDismiss) self.onDismiss();
    }
}

@end
