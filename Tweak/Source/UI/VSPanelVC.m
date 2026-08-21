//  VSPanelVC.m

#import "VSPanelVC.h"
#import "VSCreateVC.h"
#import "VSDiagnosticsVC.h"
#import "VSUIController.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSContainer.h"
#import "../Core/VSIdentity.h"

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
@property (nonatomic, strong) UIView  *headerDot;
@property (nonatomic, assign) BOOL dismissFired;
@end

@implementation VSPanelVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vessel";
    // Translucent: the view itself is clear and a frosted material sits behind the
    // table, so Instagram shows through softly. Cells are made clear in cellForRow
    // so the blur is what the rows float on — the "un peu translucide" look.
    self.view.backgroundColor = UIColor.clearColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.backgroundView = [[UIVisualEffectView alloc] initWithEffect:[VSTheme panelBlur]];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    self.tableView.tableHeaderView = [self buildHeader];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:VSContainersDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark - Header

- (UIView *)buildHeader {
    UIView *h = [UIView new];

    self.headerDot = [UIView new];
    self.headerDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerDot.layer.cornerRadius = 15;
    [self.headerDot.widthAnchor constraintEqualToConstant:30].active = YES;
    [self.headerDot.heightAnchor constraintEqualToConstant:30].active = YES;
    [h addSubview:self.headerDot];

    self.headerName = [UILabel new];
    self.headerName.font = [VSTheme fontTitle];
    self.headerName.textColor = [VSTheme primaryText];

    self.headerSub = [UILabel new];
    self.headerSub.font = [VSTheme fontCaption];
    self.headerSub.textColor = [VSTheme secondaryText];
    self.headerSub.numberOfLines = 0;

    UIStackView *col = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.headerName, self.headerSub]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 2;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [h addSubview:col];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerDot.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:20],
        [self.headerDot.centerYAnchor constraintEqualToAnchor:col.centerYAnchor],
        [col.leadingAnchor constraintEqualToAnchor:self.headerDot.trailingAnchor constant:12],
        [col.trailingAnchor constraintEqualToAnchor:h.trailingAnchor constant:-20],
        [col.topAnchor constraintEqualToAnchor:h.topAnchor constant:12],
        [col.bottomAnchor constraintEqualToAnchor:h.bottomAnchor constant:-16],
    ]];
    return h;
}

// A table header view sized by Auto Layout: measure, then reassign so the table
// adopts the new height. Guarded so the reassignment does not loop.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
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
    self.headerDot.backgroundColor = [VSTheme colorForContainer:a];
    self.headerName.text = a.name.length ? a.name : @"—";
    self.headerSub.text = [self subtitleForContainer:a];
    [self.view setNeedsLayout];
}

- (NSString *)subtitleForContainer:(VSContainer *)c {
    NSString *model = c.identity.marketingName.length ? c.identity.marketingName : @"iPhone";
    NSString *place = (c.locationEnabled && c.locationLabel.length)
        ? c.locationLabel : @"Position réelle";
    return [NSString stringWithFormat:@"%@ · %@", model, place];
}

#pragma mark - Dismiss lifecycle

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Fire only when the whole sheet goes away, never on a push to a child.
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

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == VSPanelSectionAccounts ? @"Comptes" : nil;
}

- (UIImage *)dotImage:(UIColor *)color {
    CGFloat d = 22;
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, d, d)] fill];
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == VSPanelSectionAccounts) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"acct"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:@"acct"];
        VSContainer *c = self.containers[ip.row];
        BOOL active = [c.cid isEqualToString:VSManager.shared.active.cid];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.text = c.name;
        cell.textLabel.font = [VSTheme fontHeadline];
        cell.detailTextLabel.text = [self subtitleForContainer:c];
        cell.detailTextLabel.textColor = [VSTheme secondaryText];
        // Monochrome: the active account is the one tinted with the brand color,
        // every other is a neutral grey. No more per-account rainbow.
        cell.imageView.image = [self dotImage:(active ? [VSTheme accent]
                                                      : UIColor.systemGray3Color)];
        cell.accessoryType = active ? UITableViewCellAccessoryCheckmark
                                    : UITableViewCellAccessoryNone;
        return cell;
    }
    if (ip.section == VSPanelSectionActions) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"action"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:@"action"];
        cell.backgroundColor = UIColor.clearColor;
        if (ip.row == 0) {
            cell.textLabel.text = @"＋  Créer un conteneur";
            cell.textLabel.textColor = [VSTheme accent];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"Diagnostics";
            cell.textLabel.textColor = [VSTheme primaryText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.font = [VSTheme fontBody];
        return cell;
    }
    // Reset
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"reset"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:@"reset"];
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.text = @"⟲  Tout réinitialiser";
    cell.textLabel.textColor = [VSTheme danger];
    cell.textLabel.font = [VSTheme fontHeadline];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
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
    // iPad anchor for the action sheet.
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
    // so we never delete the live container out from under the running app (the
    // old in-session reset did, which is why it appeared to "do nothing" then
    // wedge). armFullReset only records intent and flushes it.
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
    dup.backgroundColor = [VSTheme accent];

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
/// gets a FRESH identity from the manager — so it is genuinely "another phone",
/// which is the only thing that keeps two containers isolated to the server.
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
