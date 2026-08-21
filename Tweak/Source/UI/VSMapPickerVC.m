//  VSMapPickerVC.m

#import "VSMapPickerVC.h"
#import "VSTheme.h"
#import <MapKit/MapKit.h>

@interface VSMapPickerVC () <UISearchBarDelegate, MKLocalSearchCompleterDelegate,
                             UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIImageView *crosshair;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *resultsTable;
@property (nonatomic, strong) UIButton *activateButton;
@property (nonatomic, strong) MKLocalSearchCompleter *completer;
@property (nonatomic, copy)   NSArray<MKLocalSearchCompletion *> *completions;
@property (nonatomic, assign) CLLocationDegrees startLat, startLon;
@property (nonatomic, copy)   NSString *startLabel;
@property (nonatomic, assign) BOOL geocoding;
@end

@implementation VSMapPickerVC

- (instancetype)initWithLatitude:(CLLocationDegrees)lat
                       longitude:(CLLocationDegrees)lon
                           label:(NSString *)label {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _startLat = lat; _startLon = lon; _startLabel = [label copy];
        _completions = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Localisation";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    _mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mapView.showsUserLocation = NO;   // never reveal the real position on this map
    [self.view addSubview:_mapView];

    // Fixed crosshair: whatever is under it is the chosen point.
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:34
                                                                                weight:UIImageSymbolWeightBold];
    _crosshair = [[UIImageView alloc] initWithImage:
                  [UIImage systemImageNamed:@"mappin" withConfiguration:cfg]];
    _crosshair.tintColor = [VSTheme accent];
    _crosshair.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_crosshair];

    _searchBar = [UISearchBar new];
    _searchBar.placeholder = @"Rechercher une ville";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_searchBar];

    _resultsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _resultsTable.dataSource = self;
    _resultsTable.delegate = self;
    _resultsTable.hidden = YES;
    _resultsTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_resultsTable];

    _activateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_activateButton setTitle:@"Activer cette position" forState:UIControlStateNormal];
    [_activateButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _activateButton.titleLabel.font = [VSTheme fontHeadline];
    _activateButton.backgroundColor = [VSTheme accent];
    _activateButton.layer.cornerRadius = [VSTheme controlCornerRadius];
    _activateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_activateButton addTarget:self action:@selector(activateTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_activateButton];

    _completer = [MKLocalSearchCompleter new];
    _completer.delegate = self;

    [self installConstraints];
    [self applyStartRegion];
}

- (void)installConstraints {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [_searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],

        [_resultsTable.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor],
        [_resultsTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_resultsTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_resultsTable.heightAnchor constraintEqualToConstant:260],

        // Pin tip sits exactly on the map center.
        [_crosshair.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_crosshair.bottomAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_activateButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_activateButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_activateButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [_activateButton.heightAnchor constraintEqualToConstant:52],
    ]];
}

- (void)applyStartRegion {
    BOOL hasStart = !(_startLat == 0 && _startLon == 0);
    CLLocationCoordinate2D c = hasStart
        ? CLLocationCoordinate2DMake(_startLat, _startLon)
        : CLLocationCoordinate2DMake(48.8566, 2.3522);   // Paris, a sane default
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 6000, 6000);
    [_mapView setRegion:region animated:NO];
    if (_startLabel.length) _searchBar.text = _startLabel;
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (text.length == 0) {
        self.completions = @[];
        self.resultsTable.hidden = YES;
        [self.resultsTable reloadData];
        return;
    }
    self.completer.queryFragment = text;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    self.completions = completer.results ?: @[];
    self.resultsTable.hidden = (self.completions.count == 0);
    [self.resultsTable reloadData];
}

- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    self.completions = @[];
    self.resultsTable.hidden = YES;
    [self.resultsTable reloadData];
}

#pragma mark - Results table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.completions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"c"];
    MKLocalSearchCompletion *r = self.completions[ip.row];
    cell.textLabel.text = r.title;
    cell.detailTextLabel.text = r.subtitle;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MKLocalSearchCompletion *r = self.completions[ip.row];
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] initWithCompletion:r];
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:req];
    NSString *chosenTitle = r.title;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *e) {
        MKMapItem *item = resp.mapItems.firstObject;
        if (!item) return;
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(
            item.placemark.coordinate, 4000, 4000) animated:YES];
        self.searchBar.text = chosenTitle;
    }];
    self.resultsTable.hidden = YES;
    [self.searchBar resignFirstResponder];
}

#pragma mark - Activer

- (void)activateTapped {
    if (self.geocoding) return;
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    self.geocoding = YES;
    self.activateButton.enabled = NO;

    CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    CLGeocoder *geo = [CLGeocoder new];
    [geo reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *e) {
        NSString *label = [self labelFromPlacemark:marks.firstObject coordinate:c];
        self.geocoding = NO;
        self.activateButton.enabled = YES;
        if (self.onPick) self.onPick(c.latitude, c.longitude, 0, label);
        [VSTheme hapticSuccess];
        [self dismissSelf];
    }];
}

/// A short human label: "Paris, France", falling back to the search text, then to
/// raw coordinates — never nil, so the container always shows something readable.
- (NSString *)labelFromPlacemark:(CLPlacemark *)m coordinate:(CLLocationCoordinate2D)c {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *city = m.locality ?: m.subAdministrativeArea ?: m.administrativeArea;
    if (city.length) [parts addObject:city];
    if (m.country.length) [parts addObject:m.country];
    if (parts.count) return [parts componentsJoinedByString:@", "];
    if (self.searchBar.text.length) return self.searchBar.text;
    return [NSString stringWithFormat:@"%.4f, %.4f", c.latitude, c.longitude];
}

- (void)dismissSelf {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

@end
