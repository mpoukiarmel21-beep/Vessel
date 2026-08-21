//  VSContainer.m

#import "VSContainer.h"
#import "VSPaths.h"
#import "VSLog.h"

static NSString *const kCID   = @"cid";
static NSString *const kName  = @"name";
static NSString *const kColor = @"color";
static NSString *const kIdent = @"ident";
static NSString *const kDflt  = @"default";
static NSString *const kMade  = @"createdAt";
static NSString *const kUsed  = @"lastUsedAt";
static NSString *const kLocOn = @"locOn";
static NSString *const kLat   = @"lat";
static NSString *const kLon   = @"lon";
static NSString *const kAlt   = @"alt";
static NSString *const kLabel = @"locLabel";
static NSString *const kNote  = @"note";

@implementation VSContainer

+ (NSString *)newID {
    uint8_t b[8]; arc4random_buf(b, sizeof(b));
    NSMutableString *s = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

+ (instancetype)containerWithID:(NSString *)cid name:(NSString *)name {
    VSContainer *c = [VSContainer new];
    c->_cid = [(cid.length ? cid : [self newID]) copy];
    c.name = name.length ? name : @"Container";
    c.createdAt = [NSDate date];
    c.lastUsedAt = c.createdAt;
    return c;
}

+ (instancetype)containerWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    NSString *cid = d[kCID];
    if (![cid isKindOfClass:NSString.class] || cid.length == 0) {
        VSLogE(@"container", @"entry without cid, skipped");
        return nil;
    }
    VSContainer *c = [VSContainer new];
    c->_cid = [cid copy];
    c.name            = d[kName] ?: @"Container";
    c.colorHex        = d[kColor];
    c.identity        = [VSIdentity identityWithDictionary:d[kIdent]];
    c.isDefault       = [d[kDflt] boolValue];
    c.createdAt       = d[kMade] ?: [NSDate date];
    c.lastUsedAt      = d[kUsed] ?: c.createdAt;
    c.locationEnabled = [d[kLocOn] boolValue];
    c.latitude        = [d[kLat] doubleValue];
    c.longitude       = [d[kLon] doubleValue];
    c.altitude        = [d[kAlt] doubleValue];
    c.locationLabel   = d[kLabel];
    c.note            = d[kNote];
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[kCID]   = _cid ?: @"";
    d[kName]  = _name ?: @"";
    if (_colorHex.length) d[kColor] = _colorHex;
    d[kDflt]  = @(_isDefault);
    d[kMade]  = _createdAt ?: [NSDate date];
    d[kUsed]  = _lastUsedAt ?: _createdAt ?: [NSDate date];
    d[kLocOn] = @(_locationEnabled);
    d[kLat]   = @(_latitude);
    d[kLon]   = @(_longitude);
    d[kAlt]   = @(_altitude);
    if (_locationLabel.length) d[kLabel] = _locationLabel;
    if (_note.length)          d[kNote]  = _note;
    // A container without its identity would come back as a different phone on
    // the next launch, which is exactly what must never happen — but writing an
    // empty dictionary is still better than dropping the whole entry, because
    // the tree (and the logged-in account inside it) stays reachable.
    if (_identity) d[kIdent] = _identity.dictionaryRepresentation;
    else VSLogE(@"container", @"%@ has no identity at save time", _cid);
    return d;
}

#pragma mark - Storage

- (NSString *)rootPath    { return [VSPaths rootForContainerID:_cid]; }
- (NSString *)privatePath { return [VSPaths privateDirForContainerID:_cid]; }

- (BOOL)prepareStorage {
    NSError *e = nil;
    BOOL ok = [VSPaths prepareTreeForContainerID:_cid error:&e];
    if (!ok) VSLogE(@"container", @"%@ tree failed: %@", _cid, e.localizedDescription);
    return ok;
}

- (unsigned long long)diskUsage { return [VSPaths diskUsageForContainerID:_cid]; }

- (CLLocation *)baseLocation {
    if (!_locationEnabled) return nil;
    if (_latitude == 0 && _longitude == 0) return nil;   // never spoof to null island
    return [[CLLocation alloc]
            initWithCoordinate:CLLocationCoordinate2DMake(_latitude, _longitude)
                      altitude:_altitude
            horizontalAccuracy:5
              verticalAccuracy:5
                     timestamp:[NSDate date]];
}

@end
