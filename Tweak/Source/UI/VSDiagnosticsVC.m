//  VSDiagnosticsVC.m

#import "VSDiagnosticsVC.h"
#import "VSTheme.h"
#import "../Core/VSManager.h"
#import "../Core/VSLog.h"
#import "../Core/VSSelfTest.h"
#import "../Hooks/VSHookNetwork.h"
#import "../Hooks/VSHookCookies.h"
#import "../Hooks/VSHookKeychain.h"

@interface VSDiagnosticsVC ()
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *selfTestLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UISwitch *sinkSwitch;
@property (nonatomic, strong) UIStackView *topicRow;
@property (nonatomic, strong) UILabel *topicLabel;
/// One switch per bisectable layer, keyed by the VSLayer* constant.
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *bisectSwitches;
@end

@implementation VSDiagnosticsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
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

    [self buildStatusSection];
    [self buildRemoteSinkSection];
    [self buildBisectSection];
    [self buildSelfTestSection];
    [self buildLogSection];
    [self reload];
}

#pragma mark - Scaffolding

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

- (UIButton *)linkButton:(NSString *)title action:(SEL)action color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [VSTheme fontHeadline];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Status

- (void)buildStatusSection {
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [VSTheme fontBody];
    self.statusLabel.textColor = [VSTheme primaryText];
    [self addSection:@"État" content:self.statusLabel];
}

#pragma mark - Remote sink

- (void)buildRemoteSinkSection {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 12;

    UILabel *desc = [UILabel new];
    desc.numberOfLines = 0;
    desc.font = [VSTheme fontCaption];
    desc.textColor = [VSTheme secondaryText];
    desc.text = @"Publie les journaux — déjà expurgés de toute donnée sensible "
                 "(cookies, jetons, position réelle) — vers un sujet ntfy.sh privé, "
                 "pour un diagnostic à distance. Désactivé par défaut.";
    [col addArrangedSubview:desc];

    UIStackView *toggleRow = [UIStackView new];
    toggleRow.axis = UILayoutConstraintAxisHorizontal;
    toggleRow.alignment = UIStackViewAlignmentCenter;
    toggleRow.spacing = 10;

    UILabel *title = [UILabel new];
    title.numberOfLines = 0;
    title.font = [VSTheme fontHeadline];
    title.textColor = [VSTheme primaryText];
    title.text = @"Activer le diagnostic à distance";
    [title setContentHuggingPriority:UILayoutPriorityDefaultLow
                             forAxis:UILayoutConstraintAxisHorizontal];

    self.sinkSwitch = [UISwitch new];
    [self.sinkSwitch setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisHorizontal];
    [self.sinkSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.sinkSwitch addTarget:self action:@selector(sinkToggled:)
              forControlEvents:UIControlEventValueChanged];

    [toggleRow addArrangedSubview:title];
    [toggleRow addArrangedSubview:self.sinkSwitch];
    [col addArrangedSubview:toggleRow];

    self.topicRow = [UIStackView new];
    self.topicRow.axis = UILayoutConstraintAxisHorizontal;
    self.topicRow.alignment = UIStackViewAlignmentCenter;
    self.topicRow.spacing = 8;

    self.topicLabel = [UILabel new];
    self.topicLabel.numberOfLines = 0;
    self.topicLabel.font = [VSTheme fontMono];
    self.topicLabel.textColor = [VSTheme primaryText];
    [self.topicLabel setContentHuggingPriority:UILayoutPriorityDefaultLow
                                       forAxis:UILayoutConstraintAxisHorizontal];

    UIButton *copyBtn = [self linkButton:@"Copier" action:@selector(copyTopic)
                                   color:[VSTheme accent]];
    [copyBtn setContentHuggingPriority:UILayoutPriorityRequired
                               forAxis:UILayoutConstraintAxisHorizontal];

    [self.topicRow addArrangedSubview:self.topicLabel];
    [self.topicRow addArrangedSubview:copyBtn];
    [col addArrangedSubview:self.topicRow];

    [self addSection:@"Diagnostic à distance" content:col];
}

#pragma mark - Layer bisect

/// A failure that survives several fixes is a failure nobody has localised. These
/// switches turn one isolation layer off for the next launch, so retrying the broken
/// flow names the guilty layer in a single build instead of costing one guess per
/// build. The state lives in diag.plist, outside every container: "Tout réinitialiser"
/// cannot clear it, and a container that refuses to work can still be diagnosed.
/// Layer 1 (fichiers) is absent on purpose — everything else is gated on it, so
/// turning it off is just safe mode, which already has its own trigger.
- (void)buildBisectSection {
    self.bisectSwitches = [NSMutableDictionary dictionary];

    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 12;

    UILabel *desc = [UILabel new];
    desc.numberOfLines = 0;
    desc.font = [VSTheme fontCaption];
    desc.textColor = [VSTheme secondaryText];
    desc.text = @"Si une action d'Instagram échoue, désactive une couche puis relance "
                 "l'app et réessaie : la couche fautive est nommée en un seul essai. "
                 "Tout doit rester activé en usage normal.";
    [col addArrangedSubview:desc];

    NSArray<NSString *> *keys = VSBisectKeys();
    for (NSString *key in keys) {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 10;

        UILabel *title = [UILabel new];
        title.numberOfLines = 0;
        title.font = [VSTheme fontBody];
        title.textColor = [VSTheme primaryText];
        title.text = VSBisectLabel(key);
        [title setContentHuggingPriority:UILayoutPriorityDefaultLow
                                forAxis:UILayoutConstraintAxisHorizontal];

        UISwitch *sw = [UISwitch new];
        // ON = couche active. The stored flag is the inverse (disabled), so the
        // control reads the way the user thinks about it.
        sw.on = ![VSLog.shared isLayerDisabled:key];
        [sw setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
        [sw setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
        [sw addTarget:self action:@selector(bisectToggled:)
     forControlEvents:UIControlEventValueChanged];
        self.bisectSwitches[key] = sw;

        [row addArrangedSubview:title];
        [row addArrangedSubview:sw];
        [col addArrangedSubview:row];
    }

    [self addSection:@"Test de couches" content:col];
}

#pragma mark - Self-test

- (void)buildSelfTestSection {
    self.selfTestLabel = [UILabel new];
    self.selfTestLabel.numberOfLines = 0;
    self.selfTestLabel.font = [VSTheme fontMono];
    self.selfTestLabel.textColor = [VSTheme primaryText];
    [self addSection:@"Auto-test" content:self.selfTestLabel];
}

#pragma mark - Log

- (void)buildLogSection {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;

    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.font = [VSTheme fontMono];
    self.logView.textColor = [VSTheme primaryText];
    self.logView.backgroundColor = [VSTheme elevatedBackground];
    self.logView.layer.cornerRadius = [VSTheme controlCornerRadius];
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.logView.heightAnchor constraintEqualToConstant:280].active = YES;
    [col addArrangedSubview:self.logView];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 16;
    row.distribution = UIStackViewDistributionFillEqually;
    [row addArrangedSubview:[self linkButton:@"Copier le journal"
                                      action:@selector(copyLog) color:[VSTheme accent]]];
    [row addArrangedSubview:[self linkButton:@"Partager"
                                      action:@selector(shareLog) color:[VSTheme accent]]];
    [col addArrangedSubview:row];

    [self addSection:@"Journal" content:col];
}

#pragma mark - Reload

- (void)reload {
    VSManager *m = VSManager.shared;
    VSLog *log = VSLog.shared;
    // The pending list is the one line to read while a step is stuck: open this
    // screen without closing Instagram and the request the app is waiting on is
    // named here, live. Empty means the app is not waiting on the network at all.
    self.statusLabel.text = [NSString stringWithFormat:
        @"Lancements : %ld\nÉchecs consécutifs : %ld\nConteneur actif : %@\n"
        @"Requêtes en attente : %@\nCookies lus par l'app : %@\n"
        @"Trousseau partagé Meta : %@\nRefus securityd : %@",
        (long)m.bootCount, (long)[log crashStreak], m.active.name ?: @"—",
        [VSHookNetwork pendingDescription],
        [VSHookCookies readStatsDescription],
        [VSHookKeychain accessGroupsDescription],
        [VSHookKeychain refusalsDescription]];

    NSString *report = [VSSelfTest lastReport];
    self.selfTestLabel.text = report.length ? report : @"Aucun rapport pour l'instant.";

    NSArray<NSString *> *lines = [log recentLines];
    self.logView.text = lines.count ? [lines componentsJoinedByString:@"\n"]
                                    : @"Journal vide.";
    [self scrollLogToBottom];

    self.sinkSwitch.on = log.remoteSinkEnabled;
    [self refreshTopicRow];

    for (NSString *key in self.bisectSwitches)
        self.bisectSwitches[key].on = ![log isLayerDisabled:key];
}

- (void)refreshTopicRow {
    BOOL on = VSLog.shared.remoteSinkEnabled;
    self.topicRow.hidden = !on;
    self.topicLabel.text = on
        ? [NSString stringWithFormat:@"Sujet : %@", VSLog.shared.remoteTopic ?: @"—"]
        : @"";
}

- (void)scrollLogToBottom {
    NSUInteger len = self.logView.text.length;
    if (len) [self.logView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
}

#pragma mark - Actions

- (void)sinkToggled:(UISwitch *)sw {
    VSLog.shared.remoteSinkEnabled = sw.on;
    VSLogI(@"diag", @"remote sink %@ by user", sw.on ? @"ENABLED" : @"disabled");
    [self reload];
    if (sw.on) [VSTheme hapticSuccess]; else [VSTheme hapticTap];
}

/// Persists the new state and tells the user it lands on the next launch: the
/// switches are read once per boot, before any hook installs, so flipping one
/// mid-session cannot uninstall a rebind that is already in place.
- (void)bisectToggled:(UISwitch *)sw {
    NSString *key = nil;
    for (NSString *k in self.bisectSwitches)
        if (self.bisectSwitches[k] == sw) { key = k; break; }
    if (key.length == 0) return;

    [VSLog.shared setLayer:key disabled:!sw.on];
    [VSTheme hapticTap];
    [self toast:sw.on ? @"Réactivée — relance l'app" : @"Désactivée — relance l'app"];
}

- (void)copyTopic {
    NSString *topic = VSLog.shared.remoteTopic;
    if (!topic.length) return;
    UIPasteboard.generalPasteboard.string = topic;
    [VSTheme hapticSuccess];
    [self toast:@"Sujet copié"];
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string = [self redactedFullLog];
    [VSTheme hapticSuccess];
    [self toast:@"Journal copié (expurgé)"];
}

- (void)shareLog {
    NSString *text = [self redactedFullLog];
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[text] applicationActivities:nil];
    // iPad needs an anchor or it throws on present.
    av.popoverPresentationController.sourceView = self.view;
    av.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds),
                   CGRectGetMaxY(self.view.bounds) - 40, 1, 1);
    [self presentViewController:av animated:YES completion:nil];
}

/// The whole log, self-test report first, every line passed through VSRedact so
/// no cookie/token/coordinate can leave the device even via a manual export.
/// The PREVIOUS session comes before the current one: a bug is reported after the
/// app has been relaunched, so that block is usually the only one that contains it.
- (NSString *)redactedFullLog {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *report = [VSSelfTest lastReport];
    if (report.length) {
        [out addObject:@"=== AUTO-TEST ==="];
        [out addObject:report];
        [out addObject:@""];
    }

    NSString *prev = [VSLog.shared previousSessionLogText] ?: @"";
    if (prev.length) {
        [out addObject:@"=== SESSION PRÉCÉDENTE ==="];
        for (NSString *line in [prev componentsSeparatedByString:@"\n"])
            [out addObject:VSRedact(line)];
        [out addObject:@""];
    }

    [out addObject:@"=== JOURNAL (SESSION ACTUELLE) ==="];
    NSString *full = [VSLog.shared fullLogText] ?: @"";
    for (NSString *line in [full componentsSeparatedByString:@"\n"])
        [out addObject:VSRedact(line)];
    return [out componentsJoinedByString:@"\n"];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}
@end
