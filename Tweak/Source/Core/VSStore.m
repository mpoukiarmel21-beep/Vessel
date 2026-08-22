//  VSStore.m

#import "VSStore.h"
#import "VSLog.h"
#import "VSWatchdog.h"
#import <UIKit/UIKit.h>

static const NSTimeInterval kCoalesce = 0.30;

@interface VSStore () {
    NSMutableDictionary *_mem;
    dispatch_queue_t _q;          // serialises memory (fast, in-process)
    dispatch_queue_t _io;         // serialises disk writes (slow) — OFF the read path
    BOOL _dirty;
    BOOL _flushScheduled;
    BOOL _lifecycleAttached;
}
@end

@implementation VSStore

- (instancetype)initWithPath:(NSString *)path label:(NSString *)label {
    if ((self = [super init])) {
        _path = [path copy];
        _label = [label copy] ?: @"store";
        _q  = dispatch_queue_create("vessel.store", DISPATCH_QUEUE_SERIAL);
        _io = dispatch_queue_create("vessel.store.io", DISPATCH_QUEUE_SERIAL);
        _mem = [NSMutableDictionary dictionary];
        [self loadFromDisk];
    }
    return self;
}

- (NSString *)backupPath { return [_path stringByAppendingPathExtension:@"bak"]; }
- (NSString *)tempPath   { return [_path stringByAppendingPathExtension:@"tmp"]; }

- (void)loadFromDisk {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:_path.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *d = [self readPlistAt:_path];
    if (!d) {
        d = [self readPlistAt:[self backupPath]];
        if (d) {
            VSLogW(@"store", @"%@: primary unreadable, recovered from backup (%lu keys)",
                   _label, (unsigned long)d.count);
            // Re-promote the backup so the next launch reads a healthy primary.
            [d writeToFile:_path atomically:YES];
        } else if ([fm fileExistsAtPath:_path]) {
            VSLogE(@"store", @"%@: primary AND backup unreadable — quarantining", _label);
            [fm moveItemAtPath:_path
                        toPath:[_path stringByAppendingPathExtension:@"corrupt"] error:nil];
        }
    }
    if (d) [_mem setDictionary:d];
    VSLogI(@"store", @"%@ loaded: %lu keys from %@", _label,
           (unsigned long)_mem.count, _path.lastPathComponent);
}

- (NSDictionary *)readPlistAt:(NSString *)p {
    NSData *data = [NSData dataWithContentsOfFile:p];
    if (data.length == 0) return nil;
    NSError *e = nil;
    id o = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&e];
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}

#pragma mark - Accessors

- (id)objectForKey:(NSString *)key {
    if (key.length == 0) return nil;
    __block id v;
    dispatch_sync(_q, ^{ v = self->_mem[key]; });
    return v;
}

- (id)objectForKey:(NSString *)key found:(BOOL *)found {
    if (key.length == 0) { if (found) *found = NO; return nil; }
    __block id v; __block BOOL f;
    dispatch_sync(_q, ^{ v = self->_mem[key]; f = (v != nil); });
    if (found) *found = f;
    return v;
}

- (BOOL)hasKey:(NSString *)key {
    if (key.length == 0) return NO;
    __block BOOL h;
    dispatch_sync(_q, ^{ h = (self->_mem[key] != nil); });
    return h;
}

- (NSUInteger)count {
    __block NSUInteger c;
    dispatch_sync(_q, ^{ c = self->_mem.count; });
    return c;
}

- (NSDictionary *)allValues {
    __block NSDictionary *d;
    dispatch_sync(_q, ^{ d = [self->_mem copy]; });
    return d;
}

- (void)setObject:(id)obj forKey:(NSString *)key {
    if (key.length == 0) return;
    dispatch_async(_q, ^{
        if (obj) self->_mem[key] = obj; else [self->_mem removeObjectForKey:key];
        [self markDirtyLocked];
    });
}

- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }

- (void)replaceAllValues:(NSDictionary *)dict {
    dispatch_async(_q, ^{
        [self->_mem setDictionary:dict ?: @{}];
        [self markDirtyLocked];
    });
}

#pragma mark - Persistence

/// Must be called on _q.
- (void)markDirtyLocked {
    _dirty = YES;
    if (_flushScheduled) return;
    _flushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoalesce * NSEC_PER_SEC)), _q, ^{
        self->_flushScheduled = NO;
        [self writeLocked];
    });
}

/// Must be called on _q. Serialises the in-memory dictionary (fast, CPU-only) then
/// hands the actual file work to _io, so a read on _q is never blocked behind a
/// disk write or the .bak copy — the churn that, under a signup write storm, wedged
/// the main thread while it waited on a NSUserDefaults read. Durability is unchanged:
/// the bytes are captured here, the write just happens a hair later on another queue.
- (void)writeLocked {
    if (!_dirty) return;
    NSData *data = [self serializeLocked];
    if (!data) return;                       // serialise failure already logged; stay dirty
    _dirty = NO;
    NSString *path = _path, *bak = self.backupPath;
    dispatch_async(_io, ^{
        if (![self writeData:data toPath:path backup:bak])
            dispatch_async(self->_q, ^{ self->_dirty = YES; });   // re-arm; a later change retries
    });
}

/// Must be called on _q.
- (NSData *)serializeLocked {
    NSError *e = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_mem
                        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];
    if (!data) VSLogE(@"store", @"%@: serialise failed: %@", _label, e.localizedDescription);
    return data;
}

/// Runs on _io. NSDataWritingAtomic writes to a sibling temp file and atomically
/// exchanges it with the target, so a crash mid-write can never leave a truncated
/// primary. The previous primary is MOVED (not copied) to .bak first, giving one
/// generation of rollback if the new contents themselves turn out to be bad. The
/// move is O(1) whatever the file size; the old full-file copy here was O(size) on
/// EVERY write, and under a signup write storm that copy cost was what let the _io
/// backlog grow large enough to stall a synchronous flush waiting behind it. If the
/// process dies in the sub-millisecond window between the rename and the atomic
/// write, the primary is momentarily absent but .bak holds the last good copy, which
/// -loadFromDisk already recovers from and re-promotes — same durability, far cheaper.
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path backup:(NSString *)bak {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path]) {
        [fm removeItemAtPath:bak error:nil];
        [fm moveItemAtPath:path toPath:bak error:nil];
    }
    NSError *e = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&e]) {
        VSLogE(@"store", @"%@: atomic write failed: %@", _label, e.localizedDescription);
        // The primary was just moved to .bak and the new write failed, so restore it
        // rather than leave the store with no readable primary until the next write.
        if (![fm fileExistsAtPath:path] && [fm fileExistsAtPath:bak])
            [fm moveItemAtPath:bak toPath:path error:nil];
        return NO;
    }
    return YES;
}

- (void)flushAsync {
    dispatch_async(_q, ^{ [self writeLocked]; });
}

- (BOOL)flushNow {
    VSMark("store:flushNow");
    __block NSData *data = nil;
    dispatch_sync(_q, ^{
        if (!self->_dirty) return;
        data = [self serializeLocked];
        if (data) self->_dirty = NO;
    });
    if (!data) {                             // already clean — just drain any in-flight write
        dispatch_sync(_io, ^{});
        return YES;
    }
    __block BOOL ok = NO;
    NSString *path = _path, *bak = self.backupPath;
    dispatch_sync(_io, ^{ ok = [self writeData:data toPath:path backup:bak]; });
    if (!ok) dispatch_async(_q, ^{ self->_dirty = YES; });
    return ok;
}

- (void)destroy {
    dispatch_sync(_q, ^{
        [self->_mem removeAllObjects];
        self->_dirty = NO;
    });
    dispatch_sync(_io, ^{                    // ordered after any writes already queued
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:self->_path error:nil];
        [fm removeItemAtPath:[self backupPath] error:nil];
        [fm removeItemAtPath:[self tempPath] error:nil];
    });
    VSLogI(@"store", @"%@ destroyed", _label);
}

#pragma mark - Lifecycle-guaranteed flush

- (void)attachLifecycleFlush {
    if (_lifecycleAttached) return;
    _lifecycleAttached = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    // Only these two are TERMINAL: the process is about to die, so an async write
    // would never land — they must block until the bytes are down. They are also
    // rare (once per app death), so a synchronous flush here costs nothing visible.
    NSArray *terminal = @[ UIApplicationWillTerminateNotification,
                           UIApplicationDidEnterBackgroundNotification ];
    for (NSNotificationName n in terminal) {
        [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([self flushNow]) {
                VSLogD(@"store", @"%@ flushed on %@", self->_label, note.name);
            } else {
                VSLogE(@"store", @"%@ FLUSH FAILED on %@", self->_label, note.name);
            }
        }];
    }

    // These two are TRANSIENT and, during signup, arrive in storms: the keyboard,
    // the photo picker and a system prompt each resign-active, and image work fires
    // memory warnings. The app keeps running afterwards, so a synchronous flushNow
    // here bought no durability the 300 ms coalesced write does not already give —
    // it only put four back-to-back dispatch_sync(_io) disk writes on the MAIN
    // thread per event, which under a storm wedged it behind the whole I/O backlog
    // (the ~30 s "nom complet" freeze). flushAsync captures the same bytes without
    // ever blocking the main thread.
    NSArray *transient = @[ UIApplicationWillResignActiveNotification,
                            UIApplicationDidReceiveMemoryWarningNotification ];
    for (NSNotificationName n in transient) {
        [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            [self flushAsync];
        }];
    }
}

@end
