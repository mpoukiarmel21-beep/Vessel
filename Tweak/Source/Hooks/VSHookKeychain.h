//  VSHookKeychain.h — isolation layer 2: the keychain.
//
//  This is the layer the user's headline bug depends on. Instagram keeps its
//  session — the logged-in account's token — in the keychain, NOT in a file
//  under HOME. securityd owns the keychain out of process, so redirecting HOME
//  (layer 1) moves none of it: without this layer every container reads and
//  writes the SAME keychain rows, which is exactly how "je me connecte, je ferme
//  l'app, je reviens et le compte a disparu" and "les comptes se mélangent entre
//  conteneurs" both happen.
//
//  Mechanism: fishhook the four C entry points every keychain client goes
//  through — SecItemAdd / SecItemCopyMatching / SecItemUpdate / SecItemDelete —
//  and namespace each item by the active container. The item's identity
//  attributes (service, account, server, label, application-tag) are prefixed
//  with a per-container tag on the way in, and the prefix is stripped on the way
//  out, so:
//
//    * two containers that store "the same" Instagram token land on different
//      rows and never overwrite each other (fixes the mixing);
//    * a container only ever sees rows carrying its own tag, so the token it
//      wrote is still there — and only its own — after a kill/relaunch (fixes
//      the disappearance);
//    * a broad query or delete that names no identity attribute (e.g. "delete
//      every generic password") is post-filtered to this container's rows, so a
//      logout in one container cannot wipe another's.
//
//  Every replacement is wrapped so that any internal failure falls back to the
//  plain prefixed call: the worst case degrades to layer-2-without-broad-filter,
//  never to a crash inside Instagram's auth path.

#import <Foundation/Foundation.h>

@interface VSHookKeychain : NSObject

/// Installs the four fishhook rebindings and caches the namespace derived from
/// `cid` (VSManager's active container id). Idempotent; returns NO and installs
/// nothing if cid is empty or the Security symbols cannot be resolved, leaving
/// Instagram on the shared keychain rather than on a half-namespaced one.
+ (BOOL)installForContainerID:(NSString *)cid;

+ (BOOL)isInstalled;

/// The per-container attribute prefix in use, or nil. Exposed for the self-test.
+ (NSString *)namespacePrefix;

/// Layer-2 verification for VSSelfTest: adds a uniquely-named generic-password
/// item through the public SecItem API, proves it can be read back, proves the
/// raw (un-prefixed) query securityd sees would carry the namespace, deletes it,
/// and returns a description of the first thing that did not hold. nil means the
/// layer holds. Uses a service name outside anything Instagram would touch and
/// cleans up after itself.
+ (NSString *)firstLeak;

@end
