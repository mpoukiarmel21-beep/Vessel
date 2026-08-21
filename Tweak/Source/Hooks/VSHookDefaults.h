//  VSHookDefaults.h — isolation layer 3: NSUserDefaults / CFPreferences.
//
//  Instagram keeps a great deal of per-account state in its preferences plist
//  (com.burbn.instagram.plist): the list of saved logins, the "current user"
//  hint, feature flags scoped to an account, onboarding progress. cfprefsd owns
//  that plist OUT of process, exactly like securityd owns the keychain, so
//  redirecting HOME (layer 1) moves none of it. Without this layer every
//  container reads and writes the SAME preferences, which is a second, quieter
//  path to the two headline bugs: a saved-logins array written by one container
//  is seen by another ("les comptes se mélangent"), and a "current user"
//  overwritten by the last container to launch looks like the previous account
//  vanished.
//
//  Mechanism, two overlapping interceptions so no caller slips past:
//
//    1. method_setImplementation on the NSUserDefaults accessors and mutators
//       app code actually calls (object/string/array/…/integer/bool/URL and
//       their setters, plus removeObjectForKey:, synchronize, and
//       dictionaryRepresentation).
//    2. fishhook on the public CFPreferences C family (CopyAppValue /
//       SetAppValue / CopyValue / SetValue / CopyKeyList / *Synchronize),
//       scoped to the app's own bundle id, for the SDKs that bypass
//       NSUserDefaults and talk to CFPreferences directly.
//
//  Policy — the isolation guarantee rests on one asymmetry:
//
//    * WRITES go to this container's private store and NOWHERE else. The shared
//      cfprefsd plist is never written, so one container's writes can never be
//      observed by another. This is what fixes the mixing.
//    * READS return this container's value when it has one; on a miss they fall
//      back to the real defaults, so the registration domain (-registerDefaults:,
//      rebuilt identically each launch) and the global Apple domain (AppleLanguages,
//      AppleLocale — genuinely the same physical phone) still read correctly and
//      Instagram is never handed a surprise nil.
//    * a removeObjectForKey: records a tombstone rather than a plain delete, so a
//      key removed in this container stays removed even if the shared plist still
//      carries a pre-Vessel value for it — a remove that silently un-did itself on
//      the next read would be its own bug.
//
//  Secrets (the session token) live in the keychain, isolated by layer 2; this
//  layer deliberately never mirrors the shared plist into a container, so the
//  worst residue is that a brand-new container reads the user's own pre-Vessel
//  preferences until it writes its own — never another container's.
//
//  Every replacement falls back to the plain original on any anomaly (not
//  installed, empty key, nil defaults), so the failure mode is "not isolated",
//  never a crash inside Instagram's startup.

#import <Foundation/Foundation.h>

@interface VSHookDefaults : NSObject

/// Installs the NSUserDefaults swizzles and the CFPreferences rebindings and
/// opens this container's private preferences store. Idempotent; returns NO and
/// installs nothing if cid is empty, leaving Instagram on the shared defaults
/// rather than on a half-isolated set.
+ (BOOL)installForContainerID:(NSString *)cid;

+ (BOOL)isInstalled;

/// Layer-3 verification for VSSelfTest: writes a uniquely-named key through the
/// public NSUserDefaults API, proves it reads back, proves it physically landed
/// in this container's private store on disk (and therefore not in the shared
/// plist), proves a removeObjectForKey: makes it read back nil, then cleans up.
/// nil means the layer holds.
+ (NSString *)firstLeak;

@end
