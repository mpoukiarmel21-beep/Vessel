//  VSPanelVC.m — main panel, "Verre sombre / Control-Center 2026" look.
//
//  A forced-dark frosted pane floating over Instagram. Each account is its own
//  rounded translucent card with a gradient avatar; the active one wears a
//  gradient "Actif" pill. The primary action ("Nouveau conteneur") is the one
//  gradient-filled row, so the eye lands on it first. Switching a container never
//  re-points the running app — it records the choice and relaunches (rule 5).

#import "VSPanelVC.h"
#import "VSCreateVC.h"
#import "VSDiagnosticsVC.h"
#import "VSUIController.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSContainer.h"
#import "../Core/VSIdentity.h"

#pragma mark - Account card cell

@interface VSAccountCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *avatar;
@property (nonatomic, strong) CAGradientLayer *avatarGradient;
@property (nonatomic, strong) UILabel *initial;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) UILabel *pillLabel;
@property (nonatomic, strong) CAGradientLayer *pillGradient;
- (void)configureName:(NSString *)name initial:(NSString *)initial
             subtitle:(NSString *)sub active:(BOOL)active;
@end

@implementation VSAccountCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [UIView new];
        _card.backgroundColor = [VSTheme glassFill];
        _card.layer.cornerRadius = 20;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.layer.borderWidth = 1.0;
        _card.layer.borderColor = [VSTheme glassStroke].CGColor;
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_card];

        _avatar = [UIView new];
        _avatar.layer.cornerRadius = 14;
        _avatar.layer.cornerCurve = kCACornerCurveContinuous;
        _avatar.clipsToBounds = YES;
        _avatar.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:_avatar];

        _avatarGradient = [VSTheme accentGradientLayer];
        [_avatar.layer addSublayer:_avatarGradient];

        _initial = [UILabel new];
        _initial.textAlignment = NSTextAlignmentCenter;
        _initial.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        _initial.translatesAutoresizingMaskIntoConstraints = NO;
        [_avatar addSubview:_initial];

        _nameLabel = [UILabel new];
        _nameLabel.font = [VSTheme fontHeadline];
        _nameLabel.textColor = [VSTheme onGlassPrimary];

        _subLabel = [UILabel new];
        _subLabel.font = [VSTheme fontCaption];
        _subLabel.textColor = [VSTheme onGlassSecondary];
        _subLabel.numberOfLines = 1;

        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _subLabel]];
        col.axis = UILayoutConstraintAxisVertical;
        col.spacing = 2;
        col.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:col];

        _pill = [UIView new];
        _pill.clipsToBounds = YES;
        _pill.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:_pill];
        _pillGradient = [VSTheme accentGradientLayer];
        [_pill.layer addSublayer:_pillGradient];

        _pillLabel = [UILabel new];
        _pillLabel.text = @"Actif";
        _pillLabel.textColor = UIColor.whiteColor;
        _pillLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_pill addSubview:_pillLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:16],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_card.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:5],
            [_card.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-5],

            [_avatar.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_avatar.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_avatar.widthAnchor  constraintEqualToConstant:46],
            [_avatar.heightAnchor constraintEqualToConstant:46],
            [_initial.centerXAnchor constraintEqualToAnchor:_avatar.centerXAnchor],
            [_initial.centerYAnchor constraintEqualToAnchor:_avatar.centerYAnchor],

            [col.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:12],
            [col.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [col.trailingAnchor constraintLessThanOrEqualToAnchor:_pill.leadingAnchor constant:-8],

            [_pill.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
            [_pill.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_pill.heightAnchor constraintEqualToConstant:24],
            [_pillLabel.leadingAnchor  constraintEqualToAnchor:_pill.leadingAnchor  constant:10],
            [_pillLabel.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-10],
            [_pillLabel.centerYAnchor  constraintEqualToAnchor:_pill.centerYAnchor],
        ]];
        return self;
    }
    return self;
}

- (void)configureName:(NSString *)name initial:(NSString *)initial
             subtitle:(NSString *)sub active:(BOOL)active {
    self.nameLabel.text = name;
    self.subLabel.text = sub;
    self.initial.text = initial;
    self.pill.hidden = !active;
    self.avatarGradient.hidden = !active;
    if (active) {
        self.avatar.backgroundColor = UIColor.clearColor;
        self.initial.textColor = UIColor.whiteColor;
        self.card.layer.borderColor = [VSTheme accentGradientEnd].CGColor;
    } else {
        self.avatar.backgroundColor = [VSTheme glassFillStrong];
        self.initial.textColor = [VSTheme onGlassSecondary];
        self.card.layer.borderColor = [VSTheme glassStroke].CGColor;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.avatarGradient.frame = self.avatar.bounds;
    self.pillGradient.frame = self.pill.bounds;
    self.pill.layer.cornerRadius = self.pill.bounds.size.height / 2.0;
}
@end

#pragma mark - Action / reset card cell

@interface VSActionCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) CAGradientLayer *bgGradient;   // primary only
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *chevron;
- (void)configurePrimary:(NSString *)title icon:(NSString *)icon;
- (void)configureGlass:(NSString *)title icon:(NSString *)icon
                  tint:(UIColor *)tint chevron:(BOOL)chevron;
@end

@implementation VSActionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [UIView new];
        _card.layer.cornerRadius = 18;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.clipsToBounds = YES;
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_card];

        _bgGradient = [VSTheme accentGradientLayer];
        _bgGradient.hidden = YES;
        [_card.layer addSublayer:_bgGradient];

        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:_icon];

        _label = [UILabel new];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:_label];

        _chevron = [[UIImageView alloc] initWithImage:
                    [UIImage systemImageNamed:@"chevron.right"]];
        _chevron.tintColor = [VSTheme onGlassSecondary];
        _chevron.translatesAutoresizingMaskIntoConstraints = NO;
        [_card addSubview:_chevron];

        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:16],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_card.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:5],
            [_card.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-5],

            [_icon.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
            [_icon.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:22],
            [_icon.heightAnchor constraintEqualToConstant:22],

            [_label.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:14],
            [_label.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],

            [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
            [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        ]];
        return self;
    }
    return self;
}

- (void)configurePrimary:(NSString *)title icon:(NSString *)icon {
    self.bgGradient.hidden = NO;
    self.card.backgroundColor = UIColor.clearColor;
    self.label.text = title;
    self.label.font = [VSTheme fontHeadline];
    self.label.textColor = UIColor.whiteColor;
    self.icon.image = [UIImage systemImageNamed:icon];
    self.icon.tintColor = UIColor.whiteColor;
    self.chevron.hidden = YES;
}

- (void)configureGlass:(NSString *)title icon:(NSString *)icon
                  tint:(UIColor *)tint chevron:(BOOL)chevron {
    self.bgGradient.hidden = YES;
    self.card.backgroundColor = [VSTheme glassFill];
    self.label.text = title;
    self.label.font = [VSTheme fontBody];
    self.label.textColor = tint;
    self.icon.image = [UIImage systemImageNamed:icon];
    self.icon.tintColor = tint;
    self.chevron.hidden = !chevron;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.bgGradient.frame = self.card.bounds;
}
@end

#pragma mark - Panel

typedef NS_ENUM(NSInteger, VSPanelSection) {
    VSPanelSectionAccounts = 0,
    VSPanelSectionActions,
    VSPanelSectionReset,
    VSPanelSectionCount,
};

@interface VSPanelVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy)   NSArray<VSContainer *> *containers;
@property (nonatomic, strong) UILabel *headerName;
@property (nonatomic, strong) UILabel *headerSub;
@property (nonatomic, strong) UIView  *headerTile;
@property (nonatomic, strong) CAGradientLayer *headerTileGradient;
@property (nonatomic, assign) BOOL dismissFired;
@end

@implementation VSPanelVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vessel";
    // The whole panel is a dark frosted pane, regardless of the host's appearance.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];
    [self styleNavBar];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.backgroundView = [[UIVisualEffectView alloc] initWithEffect:[VSTheme panelBlurDark]];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:VSAccountCell.class forCellReuseIdentifier:@"acct"];
    [self.tableView registerClass:VSActionCell.class  forCellReuseIdentifier:@"action"];
    [self.view addSubview:self.tableView];
    self.tableView.tableHeaderView = [self buildHeader];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:VSContainersDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// Transparent bar so the frosted pane reads through it; white controls/title.
- (void)styleNavBar {
    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.tintColor = [VSTheme onGlassPrimary];
    UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
    [ap configureWithTransparentBackground];
    ap.backgroundColor = UIColor.clearColor;
    ap.titleTextAttributes = @{ NSForegroundColorAttributeName: [VSTheme onGlassPrimary] };
    bar.standardAppearance = ap;
    bar.scrollEdgeAppearance = ap;
    bar.compactAppearance = ap;
}
#pragma mark - Header

- (UIView *)buildHeader {
    UIView *h = [UIView new];

    self.headerTile = [UIView new];
    self.headerTile.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTile.layer.cornerRadius = 13;
    self.headerTile.layer.cornerCurve = kCACornerCurveContinuous;
    self.headerTile.clipsToBounds = YES;
    [self.headerTile.widthAnchor constraintEqualToConstant:44].active = YES;
    [self.headerTile.heightAnchor constraintEqualToConstant:44].active = YES;
    [h addSubview:self.headerTile];

    self.headerTileGradient = [VSTheme accentGradientLayer];
    self.headerTileGradient.frame = CGRectMake(0, 0, 44, 44);
    [self.headerTile.layer addSublayer:self.headerTileGradient];

    UIImageView *glyph = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"square.stack.3d.up.fill"]];
    glyph.tintColor = UIColor.whiteColor;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerTile addSubview:glyph];

    self.headerName = [UILabel new];
    self.headerName.font = [VSTheme fontTitle];
    self.headerName.textColor = [VSTheme onGlassPrimary];

    self.headerSub = [UILabel new];
    self.headerSub.font = [VSTheme fontCaption];
    self.headerSub.textColor = [VSTheme onGlassSecondary];
    self.headerSub.numberOfLines = 0;

    UIStackView *col = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.headerName, self.headerSub]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 2;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [h addSubview:col];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerTile.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:20],
        [self.headerTile.centerYAnchor constraintEqualToAnchor:col.centerYAnchor],
        [glyph.centerXAnchor constraintEqualToAnchor:self.headerTile.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:self.headerTile.centerYAnchor],
        [glyph.widthAnchor constraintEqualToConstant:24],
        [glyph.heightAnchor constraintEqualToConstant:24],
        [col.leadingAnchor constraintEqualToAnchor:self.headerTile.trailingAnchor constant:14],
        [col.trailingAnchor constraintEqualToAnchor:h.trailingAnchor constant:-20],
        [col.topAnchor constraintEqualToAnchor:h.topAnchor constant:14],
        [col.bottomAnchor constraintEqualToAnchor:h.bottomAnchor constant:-18],
    ]];
    return h;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.headerTileGradient.frame = self.headerTile.bounds;
    UIView *h = self.tableView.tableHeaderView;
    if (!h) return;
    CGFloat w = self.tableView.bounds.size.width;
    CGFloat fit = [h systemLayoutSizeFittingSize:CGSizeMake(w, 0)
                   withHorizontalFittingPriority:UILayoutPriorityRequired
                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (ABS(fit - h.frame.size.height) > 0.5 || ABS(w - h.frame.size.width) > 0.5) {
        h.frame = CGRectMake(0, 0, w, fit);
        self.tableView.tableHeaderView = h;
    }
}
#pragma mark - Data

- (void)refresh {
    self.containers = VSManager.shared.containers;
    [self updateHeader];
    [self.tableView reloadData];
}

- (void)updateHeader {
    VSContainer *a = VSManager.shared.active;
    self.headerName.text = @"Vessel";
    NSUInteger n = self.containers.count;
    NSString *count = n > 1 ? [NSString stringWithFormat:@"%lu conteneurs", (unsigned long)n]
                            : @"1 conteneur";
    self.headerSub.text = [NSString stringWithFormat:@"%@ · actif : %@",
                           count, a.name.length ? a.name : @"—"];
    [self.view setNeedsLayout];
}

- (NSString *)subtitleForContainer:(VSContainer *)c {
    NSString *model = c.identity.marketingName.length ? c.identity.marketingName : @"iPhone";
    NSString *place = (c.locationEnabled && c.locationLabel.length)
        ? c.locationLabel : @"Position réelle";
    return [NSString stringWithFormat:@"%@ · %@", model, place];
}

- (NSString *)initialForContainer:(VSContainer *)c {
    NSString *n = [c.name stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return n.length ? [[n substringToIndex:1] uppercaseString] : @"•";
}

#pragma mark - Dismiss lifecycle

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    BOOL gone = self.isBeingDismissed || self.navigationController.isBeingDismissed;
    if (gone && !self.dismissFired) {
        self.dismissFired = YES;
        if (self.onDismiss) self.onDismiss();
    }
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return VSPanelSectionCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case VSPanelSectionAccounts: return self.containers.count;
        case VSPanelSectionActions:  return 2;
        case VSPanelSectionReset:    return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == VSPanelSectionAccounts ? 84.0 : 64.0;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    if (s == VSPanelSectionAccounts) return 38.0;
    if (s == VSPanelSectionActions)  return 22.0;
    return 10.0;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return s == VSPanelSectionReset ? 24.0 : CGFLOAT_MIN;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    return [UIView new];   // suppress grouped default footer
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (s != VSPanelSectionAccounts) return [UIView new];
    UIView *h = [UIView new];
    UILabel *l = [UILabel new];
    l.text = @"COMPTES";
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = [VSTheme onGlassSecondary];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [h addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:22],
        [l.bottomAnchor constraintEqualToAnchor:h.bottomAnchor constant:-8],
    ]];
    return h;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == VSPanelSectionAccounts) {
        VSAccountCell *cell = [tv dequeueReusableCellWithIdentifier:@"acct"];
        VSContainer *c = self.containers[ip.row];
        BOOL active = [c.cid isEqualToString:VSManager.shared.active.cid];
        [cell configureName:c.name
                    initial:[self initialForContainer:c]
                   subtitle:[self subtitleForContainer:c]
                     active:active];
        return cell;
    }
    if (ip.section == VSPanelSectionActions) {
        VSActionCell *cell = [tv dequeueReusableCellWithIdentifier:@"action"];
        if (ip.row == 0)
            [cell configurePrimary:@"Nouveau conteneur" icon:@"plus"];
        else
            [cell configureGlass:@"Diagnostics" icon:@"waveform.path.ecg"
                            tint:[VSTheme onGlassPrimary] chevron:YES];
        return cell;
    }
    VSActionCell *cell = [tv dequeueReusableCellWithIdentifier:@"action"];
    [cell configureGlass:@"Tout réinitialiser" icon:@"trash"
                    tint:[VSTheme danger] chevron:NO];
    return cell;
}

#pragma mark - Table delegate

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == VSPanelSectionAccounts;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == VSPanelSectionAccounts) {
        [self switchToContainer:self.containers[ip.row]];
    } else if (ip.section == VSPanelSectionActions) {
        if (ip.row == 0) [self openCreate]; else [self openDiagnostics];
    } else {
        [self confirmResetEverything];
    }
}

- (void)openCreate {
    VSCreateVC *vc = [VSCreateVC new];
    __weak VSPanelVC *weakSelf = self;
    vc.onCreated = ^(VSContainer *c) { [weakSelf offerSwitchToNewContainer:c]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDiagnostics {
    [self.navigationController pushViewController:[VSDiagnosticsVC new] animated:YES];
}
#pragma mark - Switching (records choice + relaunch, never re-points a live app)

- (void)offerSwitchToNewContainer:(VSContainer *)c {
    if (!c) return;
    [self refresh];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Conteneur créé"
        message:[NSString stringWithFormat:
            @"Basculer vers « %@ » maintenant ? L'application va redémarrer.", c.name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Plus tard"
        style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Basculer"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self commitSwitchTo:c];
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)switchToContainer:(VSContainer *)c {
    if (!c || [c.cid isEqualToString:VSManager.shared.active.cid]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Changer de conteneur"
        message:[NSString stringWithFormat:
            @"Basculer vers « %@ » ? L'application va redémarrer pour appliquer le changement.", c.name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler"
        style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Basculer & redémarrer"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self commitSwitchTo:c];
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)commitSwitchTo:(VSContainer *)c {
    if (![VSManager.shared selectContainerForNextLaunch:c.cid]) return;
    [VSTheme hapticSuccess];
    [VSUIController relaunchToApplyContainerSwitch];
}

#pragma mark - Reset everything (double confirmation)

- (void)confirmResetEverything {
    UIAlertController *a1 = [UIAlertController alertControllerWithTitle:@"Tout réinitialiser ?"
        message:@"Supprime TOUS les conteneurs et leurs données (comptes, cookies, "
                 "réglages). Cette action est irréversible."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a1 addAction:[UIAlertAction actionWithTitle:@"Annuler"
        style:UIAlertActionStyleCancel handler:nil]];
    [a1 addAction:[UIAlertAction actionWithTitle:@"Continuer…"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self confirmResetStage2];
        }]];
    a1.popoverPresentationController.sourceView = self.tableView;
    a1.popoverPresentationController.sourceRect = [self.tableView
        rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:VSPanelSectionReset]];
    [self presentViewController:a1 animated:YES completion:nil];
}
- (void)confirmResetStage2 {
    UIAlertController *a2 = [UIAlertController alertControllerWithTitle:@"Vraiment tout effacer ?"
        message:@"Dernier avertissement : tous les conteneurs seront perdus. "
                 "L'application va redémarrer."
        preferredStyle:UIAlertControllerStyleAlert];
    [a2 addAction:[UIAlertAction actionWithTitle:@"Annuler"
        style:UIAlertActionStyleCancel handler:nil]];
    [a2 addAction:[UIAlertAction actionWithTitle:@"Tout effacer"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self performReset];
        }]];
    [self presentViewController:a2 animated:YES completion:nil];
}

- (void)performReset {
    // Arm-and-relaunch: the wipe happens at next boot, before HOME is redirected,
    // so we never delete the live container out from under the running app.
    if ([VSManager.shared armFullReset]) {
        [VSTheme hapticSuccess];
        [VSUIController relaunchToApplyContainerSwitch];
    } else {
        [self alert:@"Échec" message:@"La réinitialisation n'a pas pu être programmée."];
    }
}

#pragma mark - Swipe actions

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != VSPanelSectionAccounts) return nil;
    VSContainer *c = self.containers[ip.row];
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];

    BOOL isActive = [c.cid isEqualToString:VSManager.shared.active.cid];
    if (!c.isDefault && !isActive) {
        UIContextualAction *del = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Supprimer"
            handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
                [self confirmDelete:c completion:done];
            }];
        [actions addObject:del];
    }

    UIContextualAction *dup = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal title:@"Dupliquer"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self duplicate:c];
            done(YES);
        }];
    dup.backgroundColor = [VSTheme accentGradientStart];

    UIContextualAction *ren = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal title:@"Renommer"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self promptRename:c completion:done];
        }];
    ren.backgroundColor = UIColor.systemGrayColor;

    [actions addObject:dup];
    [actions addObject:ren];
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}
- (void)confirmDelete:(VSContainer *)c completion:(void (^)(BOOL))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Supprimer le conteneur"
        message:[NSString stringWithFormat:
            @"Supprimer « %@ » et toutes ses données ? Irréversible.", c.name]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *x) { done(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Supprimer" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *x) {
            NSError *e = nil;
            BOOL ok = [VSManager.shared deleteContainer:c.cid error:&e];
            done(ok);
            if (ok) { [VSTheme hapticSuccess]; [self refresh]; }
            else [self alert:@"Suppression impossible" message:e.localizedDescription ?: @""];
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptRename:(VSContainer *)c completion:(void (^)(BOOL))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Renommer"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = c.name;
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *x) { done(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) {
            NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL ok = name.length && [VSManager.shared renameContainer:c.cid to:name];
            done(ok);
            if (ok) { [VSTheme hapticTap]; [self refresh]; }
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Duplicate

/// A duplicate copies the user-facing settings (color, base location, note) but
/// gets a FRESH identity from the manager — so it is genuinely "another phone".
- (void)duplicate:(VSContainer *)c {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    CGFloat scale = UIScreen.mainScreen.nativeScale;
    NSError *e = nil;
    NSString *name = [c.name stringByAppendingString:@" copie"];
    VSContainer *n = [VSManager.shared createContainerNamed:name
                                            screenPixelSize:px scale:scale error:&e];
    if (!n) { [self alert:@"Duplication impossible" message:e.localizedDescription ?: @""]; return; }
    n.colorHex = c.colorHex;
    if (c.locationEnabled) {
        n.locationEnabled = YES;
        n.latitude = c.latitude;
        n.longitude = c.longitude;
        n.altitude = c.altitude;
        n.locationLabel = c.locationLabel;
    }
    n.note = c.note;
    [VSManager.shared saveContainer:n];
    [VSTheme hapticSuccess];
    [self refresh];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
