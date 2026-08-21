//  VSMapPickerVC.h — city search + map + "Activer" (ARCHITECTURE §4.1).
//
//  The front-end for a container's base location. MapKit is already linked by
//  Instagram, so there is no new dependency and no API key. The chosen point is
//  the map's center (a fixed crosshair), so panning IS choosing — simpler and
//  more precise than a draggable pin. Search uses MKLocalSearchCompleter for
//  as-you-type city completion. "Activer" reverse-geocodes the center for a clean
//  label, then hands the coordinate back through `onPick`.

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface VSMapPickerVC : UIViewController

/// Pre-centers on an existing location; pass 0/0 for "no location yet".
- (instancetype)initWithLatitude:(CLLocationDegrees)lat
                       longitude:(CLLocationDegrees)lon
                           label:(NSString *)label;

/// Called when the user taps "Activer". Altitude is 0 (no public elevation API);
/// the location layer treats 0 m as sea level, which is plausible everywhere.
@property (nonatomic, copy) void (^onPick)(CLLocationDegrees lat,
                                           CLLocationDegrees lon,
                                           CLLocationDistance alt,
                                           NSString *label);

@end
