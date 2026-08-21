//  VSStore.h — atomic, write-through, self-healing plist store.
//
//  This is the module that answers "my Instagram account vanishes when I close
//  the app". Every mutation is persisted within 300 ms, and unconditionally
//  flushed on background/terminate/resign-active. A corrupt primary file falls
//  back to the previous known-good copy instead of silently starting empty —
//  starting empty is exactly what looks like "the account disappeared".

#import <Foundation/Foundation.h>

@interface VSStore : NSObject

/// @param path  plist file; parent directory is created if needed.
/// @param label short name used in logs.
- (instancetype)initWithPath:(NSString *)path label:(NSString *)label;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *label;

- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)obj forKey:(NSString *)key;   // nil obj removes
- (void)removeObjectForKey:(NSString *)key;
- (NSDictionary *)allValues;
- (void)replaceAllValues:(NSDictionary *)dict;
- (BOOL)hasKey:(NSString *)key;
- (NSUInteger)count;

/// Blocks until the current contents are on disk. Safe to call from any thread.
- (BOOL)flushNow;

/// Deletes the store and its backup from disk and clears memory.
- (void)destroy;

/// Subscribes to app lifecycle notifications for guaranteed flushes.
/// Called once per store by VSBootstrap after UIApplication exists.
- (void)attachLifecycleFlush;

@end
