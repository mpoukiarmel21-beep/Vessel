//  VSStore.m

#import "VSStore.h"
#import "VSLog.h"
#import <UIKit/UIKit.h>

static const NSTimeInterval kCoalesce = 0.30;

@interface VSStore () {
    NSMutableDictionary *_mem;
    dispatch_queue_t _q;          // serialises memory + disk
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
        _q = dispatch_queue_create("vessel.store", DISPATCH_QUEUE_SERIAL);
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

/// Must be called on _q.
/// NSDataWritingAtomic writes to a sibling temp file and atomically exchanges it
/// with the target, so a crash mid-write can never leave a truncated primary.
/// The previous primary is copied to .bak first, giving one generation of
/// rollback if the new contents themselves turn out to be bad.
- (BOOL)writeLocked {
    if (!_dirty) return YES;
    NSError *e = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_mem
                        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];
    if (!data) {
        VSLogE(@"store", @"%@: serialise failed: %@", _label, e.localizedDescription);
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:_path]) {
        [fm removeItemAtPath:[self backupPath] error:nil];
        [fm copyItemAtPath:_path toPath:[self backupPath] error:nil];
    }
    if (![data writeToFile:_path options:NSDataWritingAtomic error:&e]) {
        VSLogE(@"store", @"%@: atomic write failed: %@", _label, e.localizedDescription);
        return NO;
    }
    _dirty = NO;
    return YES;
}

- (BOOL)flushNow {
    __block BOOL ok;
    dispatch_sync(_q, ^{ ok = [self writeLocked]; });
    return ok;
}

- (void)destroy {
    dispatch_sync(_q, ^{
        [self->_mem removeAllObjects];
        self->_dirty = NO;
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
    NSArray *names = @[ UIApplicationDidEnterBackgroundNotification,
                        UIApplicationWillTerminateNotification,
                        UIApplicationWillResignActiveNotification,
                        UIApplicationDidReceiveMemoryWarningNotification ];
    for (NSNotificationName n in names) {
        [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([self flushNow]) {
                VSLogD(@"store", @"%@ flushed on %@", self->_label, note.name);
            } else {
                VSLogE(@"store", @"%@ FLUSH FAILED on %@", self->_label, note.name);
            }
        }];
    }
}

@end
