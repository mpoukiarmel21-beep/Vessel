//  VSContainer.h — one container: identity + storage + base location.
//
//  A container is the unit the user creates from the floating button. To the
//  server it must look like a different phone, which means all four of these
//  travel together and are created at the same moment:
//
//    * a directory tree that becomes the app's HOME,
//    * a frozen device identity (see VSIdentity),
//    * a keychain/preferences/cookies namespace,
//    * a base location the account was "created" in.
//
//  The object is a plain value type. VSManager owns the list and the writes;
//  nothing here touches disk on its own except +prepareStorage.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "VSIdentity.h"

@interface VSContainer : NSObject

/// Directory name and namespace prefix. Lowercase hex, 16 chars — short enough
/// to keep keychain attribute strings readable, wide enough never to collide.
@property (nonatomic, readonly, copy) NSString *cid;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) VSIdentity *identity;

/// The default container cannot be deleted or renamed away; "Tout réinitialiser"
/// recreates it empty. Without it the app would have no working state at all if
/// the user deleted every container.
@property (nonatomic, assign) BOOL isDefault;

@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) NSDate *lastUsedAt;

#pragma mark - Base location

/// When NO, CoreLocation behaves normally (the real position is reported).
@property (nonatomic, assign) BOOL locationEnabled;
@property (nonatomic, assign) CLLocationDegrees latitude;
@property (nonatomic, assign) CLLocationDegrees longitude;
@property (nonatomic, assign) CLLocationDistance altitude;
/// Human label shown in the UI, e.g. "Paris, France".
@property (nonatomic, copy) NSString *locationLabel;

/// Free-text note the user can attach so an account is recognisable later
/// ("compte boutique"). Stored on-device only; never sent to the remote sink.
@property (nonatomic, copy) NSString *note;

#pragma mark - Lifecycle

+ (instancetype)containerWithID:(NSString *)cid name:(NSString *)name;
+ (instancetype)containerWithDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionaryRepresentation;

/// Fresh 16-char lowercase-hex id.
+ (NSString *)newID;

/// Creates the on-disk tree for this container. Idempotent.
- (BOOL)prepareStorage;

/// Absolute path that becomes the fake HOME.
- (NSString *)rootPath;
/// Tweak-private directory inside the container (defaults, cookies, aux stores).
- (NSString *)privatePath;

/// Bytes currently used on disk.
- (unsigned long long)diskUsage;

- (CLLocation *)baseLocation;

@end
