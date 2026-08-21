//  VSCreateVC.m

#import "VSCreateVC.h"
#import "VSMapPickerVC.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSContainer.h"
#import "../Core/VSIdentity.h"

@interface VSCreateVC () <UITextFieldDelegate>
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, copy)   NSString *pickedHex;
@property (nonatomic, strong) NSMutableArray<UIButton *> *swatches;
@property (nonatomic, strong) VSIdentity *previewIdentity;
@property (nonatomic, strong) UILabel *identityLabel;
@property (nonatomic, strong) UILabel *locationValueLabel;
@property (nonatomic, assign) BOOL locationChosen;
@property (nonatomic, assign) CLLocationDegrees pLat, pLon;
@property (nonatomic, assign) CLLocationDistance pAlt;
@property (nonatomic, copy)   NSString *pLabel;
@end

@implementation VSCreateVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Nouveau container";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.swatches = [NSMutableArray array];
    self.pickedHex = VSTheme.paletteHex.firstObject;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Créer" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(createTapped)];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
    ]];

    [self buildNameColorSection];
    [self buildIdentitySection];
    [self buildLocationSection];
}

#pragma mark - Section scaffolding

/// A captioned rounded card added to the vertical stack. `content` is pinned
/// inside the card with uniform padding, so the card's height follows its
/// content — no fixed heights to get wrong on different text sizes.
- (void)addSection:(NSString *)title content:(UIView *)content {
    UILabel *t = [UILabel new];
    t.text = title;
    t.font = [VSTheme fontCaption];
    t.textColor = [VSTheme secondaryText];
    [self.stack addArrangedSubview:t];

    UIView *card = [UIView new];
    card.backgroundColor = [VSTheme cardBackground];
    card.layer.cornerRadius = [VSTheme cardCornerRadius];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
    ]];
    [self.stack addArrangedSubview:card];
}

#pragma mark - 1 · Name & color

- (void)buildNameColorSection {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 12;

    self.nameField = [UITextField new];
    self.nameField.placeholder = @"Nom du container";
    self.nameField.font = [VSTheme fontBody];
    self.nameField.textColor = [VSTheme primaryText];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.returnKeyType = UIReturnKeyDone;
    self.nameField.delegate = self;
    [col addArrangedSubview:self.nameField];

    [col addArrangedSubview:[self buildSwatchRow]];
    [self addSection:@"1 · Nom & couleur" content:col];
    [self highlightSelectedSwatch];
}

- (UIStackView *)buildSwatchRow {
    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    NSArray<NSString *> *palette = [VSTheme paletteHex];
    for (NSInteger i = 0; i < (NSInteger)palette.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.backgroundColor = [VSTheme colorFromHex:palette[i]];
        b.layer.cornerRadius = 15;
        b.layer.borderColor = [VSTheme primaryText].CGColor;
        [b.heightAnchor constraintEqualToConstant:30].active = YES;
        [b addTarget:self action:@selector(swatchTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.swatches addObject:b];
        [row addArrangedSubview:b];
    }
    return row;
}

- (void)swatchTapped:(UIButton *)b {
    self.pickedHex = [VSTheme paletteHex][b.tag];
    [self highlightSelectedSwatch];
    [VSTheme hapticTap];
}

/// Ring + slight enlargement on the chosen swatch, so the selection reads even
/// for users who cannot tell two adjacent hues apart.
- (void)highlightSelectedSwatch {
    for (UIButton *b in self.swatches) {
        BOOL on = [[VSTheme paletteHex][b.tag] isEqualToString:self.pickedHex];
        b.layer.borderWidth = on ? 3 : 0;
        b.transform = on ? CGAffineTransformMakeScale(1.12, 1.12)
                         : CGAffineTransformIdentity;
    }
}

#pragma mark - 2 · Device identity

- (void)buildIdentitySection {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;

    self.identityLabel = [UILabel new];
    self.identityLabel.numberOfLines = 0;
    self.identityLabel.font = [VSTheme fontMono];
    self.identityLabel.textColor = [VSTheme primaryText];
    [col addArrangedSubview:self.identityLabel];

    UIButton *regen = [UIButton buttonWithType:UIButtonTypeSystem];
    [regen setTitle:@"↻ Régénérer l'identité" forState:UIControlStateNormal];
    regen.titleLabel.font = [VSTheme fontHeadline];
    [regen setTitleColor:[VSTheme accent] forState:UIControlStateNormal];
    regen.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [regen addTarget:self action:@selector(regenerateIdentity)
        forControlEvents:UIControlEventTouchUpInside];
    [col addArrangedSubview:regen];

    [self addSection:@"2 · Identité de l'appareil (unique)" content:col];
    [self regenerateIdentity];   // first preview
}

/// Generated against the LIVE screen geometry and the real OS, and de-duplicated
/// against every other container — the same call the manager makes internally,
/// so the previewed identity is a genuine, collision-free one that ships as-is.
- (VSIdentity *)freshPreview {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    CGFloat scale = UIScreen.mainScreen.nativeScale;
    NSString *loc = NSLocale.currentLocale.localeIdentifier ?: @"fr_FR";
    NSString *tz  = NSTimeZone.systemTimeZone.name ?: @"Europe/Paris";
    return [VSIdentity generateForScreenPixelSize:px
                                            scale:scale
                                        osVersion:[VSIdentity realOSVersion]
                                          osBuild:[VSIdentity realOSBuild]
                                           locale:loc
                                         timeZone:tz
                                            taken:[VSManager.shared takenIdentifierValues]];
}

- (void)regenerateIdentity {
    self.previewIdentity = [self freshPreview];
    [self renderIdentity];
    [VSTheme hapticTap];
}

- (void)renderIdentity {
    VSIdentity *idn = self.previewIdentity;
    if (!idn) { self.identityLabel.text = @""; return; }
    self.identityLabel.text = [NSString stringWithFormat:
        @"%@\nModèle : %@ (%@)\nNom : %@\nSérie : %@\nIDFV : %@",
        [idn shortDescription], idn.marketingName, idn.machine,
        idn.deviceName, idn.serialNumber, idn.idfv];
}

#pragma mark - 3 · Base location (optional)

- (void)buildLocationSection {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;

    self.locationValueLabel = [UILabel new];
    self.locationValueLabel.numberOfLines = 0;
    self.locationValueLabel.font = [VSTheme fontBody];
    self.locationValueLabel.textColor = [VSTheme secondaryText];
    [col addArrangedSubview:self.locationValueLabel];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.distribution = UIStackViewDistributionFillEqually;

    UIButton *choose = [UIButton buttonWithType:UIButtonTypeSystem];
    [choose setTitle:@"Choisir sur la carte" forState:UIControlStateNormal];
    choose.titleLabel.font = [VSTheme fontHeadline];
    [choose setTitleColor:[VSTheme accent] forState:UIControlStateNormal];
    choose.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [choose addTarget:self action:@selector(chooseLocation)
        forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:choose];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:@"Retirer" forState:UIControlStateNormal];
    clear.titleLabel.font = [VSTheme fontBody];
    [clear setTitleColor:[VSTheme danger] forState:UIControlStateNormal];
    clear.contentHorizontalAlignment = UIControlContentHorizontalAlignmentTrailing;
    [clear addTarget:self action:@selector(clearLocation)
        forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:clear];

    [col addArrangedSubview:row];
    [self addSection:@"3 · Localisation de base (optionnel)" content:col];
    [self renderLocation];
}

- (void)chooseLocation {
    VSMapPickerVC *map = [[VSMapPickerVC alloc]
        initWithLatitude:(self.locationChosen ? self.pLat : 0)
               longitude:(self.locationChosen ? self.pLon : 0)
                   label:(self.locationChosen ? self.pLabel : nil)];
    __weak VSCreateVC *weakSelf = self;
    map.onPick = ^(CLLocationDegrees lat, CLLocationDegrees lon,
                   CLLocationDistance alt, NSString *label) {
        VSCreateVC *s = weakSelf; if (!s) return;
        s.locationChosen = YES;
        s.pLat = lat; s.pLon = lon; s.pAlt = alt; s.pLabel = label;
        [s renderLocation];
    };
    if (self.navigationController)
        [self.navigationController pushViewController:map animated:YES];
    else
        [self presentViewController:
            [[UINavigationController alloc] initWithRootViewController:map]
                           animated:YES completion:nil];
}

- (void)clearLocation {
    self.locationChosen = NO;
    self.pLat = 0; self.pLon = 0; self.pAlt = 0; self.pLabel = nil;
    [self renderLocation];
    [VSTheme hapticTap];
}

- (void)renderLocation {
    self.locationValueLabel.text = self.locationChosen
        ? [NSString stringWithFormat:@"📍 %@\n%.4f, %.4f",
           self.pLabel ?: @"Position", self.pLat, self.pLon]
        : @"Aucune — l'app utilisera la position réelle du téléphone.";
}

#pragma mark - Commit

- (void)createTapped {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) name = @"Container";

    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    CGFloat scale = UIScreen.mainScreen.nativeScale;
    NSError *err = nil;
    VSContainer *c = [VSManager.shared createContainerNamed:name
                                            screenPixelSize:px
                                                      scale:scale
                                                      error:&err];
    if (!c) {
        [self alert:@"Création impossible"
            message:err.localizedDescription ?: @"Erreur inconnue."];
        return;
    }
    // What the user previewed IS what ships: replace the manager's own identity
    // with the previewed one (both collision-checked against the same set).
    if (self.previewIdentity) c.identity = self.previewIdentity;
    c.colorHex = self.pickedHex;
    if (self.locationChosen) {
        c.locationEnabled = YES;
        c.latitude = self.pLat;
        c.longitude = self.pLon;
        c.altitude = self.pAlt;
        c.locationLabel = self.pLabel;
    }
    [VSManager.shared saveContainer:c];
    [VSTheme hapticSuccess];

    // Pop first, then hand the container back on the next runloop so the panel
    // (top again) can present its "switch now?" prompt without stacking on us.
    void (^done)(VSContainer *) = self.onCreated;
    [self dismissOrPop];
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(c); });
}

- (void)cancelTapped { [self dismissOrPop]; }

- (void)dismissOrPop {
    [self.view endEditing:YES];
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject != self)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
