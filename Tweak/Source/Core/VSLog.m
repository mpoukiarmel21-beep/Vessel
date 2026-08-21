//  VSLog.m

#import "VSLog.h"
#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <signal.h>
#import <pthread.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <sys/time.h>
#import <time.h>

static const NSInteger kRingCapacity = 800;
static NSString *const kPrefsFile   = @"diag.plist";
static NSString *const kCrashFile   = @"crash-pending.log";
static NSString *const kStreakKey   = @"crashStreak";
static NSString *const kSinkKey     = @"remoteSinkEnabled";
static NSString *const kTopicKey    = @"remoteTopic";

// Written from signal handlers, so it must stay async-signal-safe-ish: plain
// C globals only, no ObjC, no malloc on the crash path.
static char  gCrashFilePath[1024]   = {0};
static int   gHighestBreadcrumb     = 0;
static volatile sig_atomic_t gInCrashHandler = 0;

/// Thread-safe wall-clock stamp. NSDateFormatter is NOT safe for concurrent use
/// and -log: is called from every thread Instagram owns, so formatting is done
/// in C instead.
static void VSTimestamp(char *out, size_t cap) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    snprintf(out, cap, "%02d:%02d:%02d.%03d",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000));
}

NSString *VSRedact(NSString *line) {
    if (line.length == 0) return line;
    static NSArray<NSString *> *needles = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[ @"sessionid", @"csrftoken", @"ds_user", @"authorization",
                     @"password", @"passwd", @"token", @"bearer", @"cookie",
                     @"secret", @"x-mid", @"ig-u-", @"claim", @"apikey",
                     @"api_key", @"access_token", @"refresh" ];
    });
    NSString *low = line.lowercaseString;
    for (NSString *n in needles) {
        if ([low containsString:n]) return @"<redacted: sensitive key matched>";
    }
    // Long opaque blobs are almost always credentials; keep only a length hint.
    static NSRegularExpression *blob = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        blob = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9+/=_-]{40,}"
                                                        options:0 error:nil];
    });
    return [blob stringByReplacingMatchesInString:line options:0
                                            range:NSMakeRange(0, line.length)
                                     withTemplate:@"<blob>"];
}

@interface VSLog () {
    NSMutableArray<NSString *> *_ring;
    dispatch_queue_t _q;
    NSFileHandle *_fh;
    NSString *_diagDir;
    NSMutableDictionary *_prefs;
    BOOL _ready;
}
@end

@implementation VSLog

+ (VSLog *)shared {
    static VSLog *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[VSLog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ring  = [NSMutableArray arrayWithCapacity:kRingCapacity];
        _prefs = [NSMutableDictionary dictionary];
        _q = dispatch_queue_create("vessel.log", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)bootstrapWithRealDataRoot:(NSString *)realRoot {
    if (_ready || realRoot.length == 0) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    _diagDir = [realRoot stringByAppendingPathComponent:@"diag"];
    [fm createDirectoryAtPath:_diagDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *pp = [_diagDir stringByAppendingPathComponent:kPrefsFile];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pp];
    if (d) [_prefs setDictionary:d];
    if (!_prefs[kTopicKey]) {
        _prefs[kTopicKey] = [self randomTopic];
        [self savePrefs];
    }

    // One log file per session, capped history: keep the 6 most recent.
    NSString *stamp = [@((long long)[NSDate date].timeIntervalSince1970) stringValue];
    _logFilePath = [_diagDir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"session-%@.log", stamp]];
    [fm createFileAtPath:_logFilePath contents:nil attributes:nil];
    _fh = [NSFileHandle fileHandleForWritingAtPath:_logFilePath];
    [self pruneOldLogs];

    NSString *cp = [_diagDir stringByAppendingPathComponent:kCrashFile];
    strncpy(gCrashFilePath, cp.fileSystemRepresentation, sizeof(gCrashFilePath) - 1);

    _ready = YES;
    [self log:VSLogLevelInfo tag:@"log" fmt:@"=== Vessel session start === diag=%@", _diagDir];
}

- (NSString *)randomTopic {
    uint8_t b[16]; arc4random_buf(b, sizeof(b));
    NSMutableString *s = [NSMutableString stringWithString:@"vsl-"];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

- (void)savePrefs {
    if (!_diagDir) return;
    [_prefs writeToFile:[_diagDir stringByAppendingPathComponent:kPrefsFile] atomically:YES];
}

- (void)pruneOldLogs {
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:_diagDir error:nil];
    NSMutableArray *logs = [NSMutableArray array];
    for (NSString *f in all) if ([f hasPrefix:@"session-"]) [logs addObject:f];
    [logs sortUsingSelector:@selector(compare:)];
    while (logs.count > 6) {
        NSString *old = logs.firstObject; [logs removeObjectAtIndex:0];
        [NSFileManager.defaultManager removeItemAtPath:
            [_diagDir stringByAppendingPathComponent:old] error:nil];
    }
}

#pragma mark - Sink switch

- (NSString *)remoteTopic { return _prefs[kTopicKey] ?: @""; }

- (BOOL)remoteSinkEnabled { return [_prefs[kSinkKey] boolValue]; }

- (void)setRemoteSinkEnabled:(BOOL)on {
    _prefs[kSinkKey] = @(on);
    [self savePrefs];
    [self log:VSLogLevelInfo tag:@"log" fmt:@"remote sink -> %@", on ? @"ON" : @"OFF"];
}

#pragma mark - Logging

- (void)log:(VSLogLevel)level tag:(NSString *)tag fmt:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static const char *names[] = { "DBG", "INF", "WRN", "ERR" };
    char ts[24]; VSTimestamp(ts, sizeof(ts));
    NSString *line = [NSString stringWithFormat:@"%s %s [%@] %@",
                      ts, names[MIN(MAX(level, 0), 3)], tag ?: @"-", msg];

    dispatch_async(_q, ^{
        [self->_ring addObject:line];
        while (self->_ring.count > kRingCapacity) [self->_ring removeObjectAtIndex:0];
        if (self->_fh) {
            @try {
                [self->_fh writeData:[[line stringByAppendingString:@"\n"]
                                      dataUsingEncoding:NSUTF8StringEncoding]];
            } @catch (__unused NSException *e) { self->_fh = nil; }
        }
    });

    // Always mirror to the system log: visible in Console.app over USB even if
    // the file layer is broken (e.g. a crash before the log dir exists).
    NSLog(@"[Vessel] %@", line);

    if (level >= VSLogLevelWarn && self.remoteSinkEnabled) [self pushRemote:line];
}

- (void)breadcrumb:(VSBootStep)step note:(NSString *)note {
    if (step > gHighestBreadcrumb) gHighestBreadcrumb = (int)step;
    [self log:VSLogLevelInfo tag:@"boot" fmt:@"%02ld %@", (long)step, note ?: @""];
}

- (void)pushRemote:(NSString *)line {
    NSString *safe = VSRedact(line);
    NSString *topic = self.remoteTopic;
    if (topic.length == 0) return;
    NSURL *u = [NSURL URLWithString:[@"https://ntfy.sh/" stringByAppendingString:topic]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 8;
    r.HTTPBody = [safe dataUsingEncoding:NSUTF8StringEncoding];
    [[NSURLSession.sharedSession dataTaskWithRequest:r] resume];
}

#pragma mark - Crash capture

static void VSWriteCrash(const char *kind, const char *detail) {
    if (gInCrashHandler) _exit(1);
    gInCrashHandler = 1;
    if (gCrashFilePath[0] == 0) return;
    int fd = open(gCrashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char head[512];
    int n = snprintf(head, sizeof(head),
                     "kind=%s\nbreadcrumb=%d\ndetail=%s\nframes:\n",
                     kind, gHighestBreadcrumb, detail ?: "");
    if (n > 0) write(fd, head, (size_t)n);
    void *cb[64];
    int fr = backtrace(cb, 64);
    backtrace_symbols_fd(cb, fr, fd);
    close(fd);
}

static void VSSignalHandler(int sig) {
    char buf[32]; snprintf(buf, sizeof(buf), "signal %d", sig);
    VSWriteCrash("signal", buf);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void VSExceptionHandler(NSException *e) {
    VSWriteCrash("exception",
                 [[NSString stringWithFormat:@"%@: %@", e.name, e.reason] UTF8String]);
}

- (void)installCrashHandlers {
    NSSetUncaughtExceptionHandler(&VSExceptionHandler);
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa; memset(&sa, 0, sizeof(sa));
        sa.sa_handler = VSSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(sigs[i], &sa, NULL);
    }
    [self log:VSLogLevelInfo tag:@"log" fmt:@"crash handlers installed"];
}

- (void)drainPreviousCrashReport {
    if (!_diagDir) return;
    NSString *cp = [_diagDir stringByAppendingPathComponent:kCrashFile];
    NSString *txt = [NSString stringWithContentsOfFile:cp encoding:NSUTF8StringEncoding error:nil];
    if (txt.length == 0) return;
    [self log:VSLogLevelError tag:@"crash" fmt:@"previous run crashed:\n%@", txt];
    NSString *keep = [_diagDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"crash-%@.log",
                       @((long long)[NSDate date].timeIntervalSince1970)]];
    [NSFileManager.defaultManager moveItemAtPath:cp toPath:keep error:nil];
    if (self.remoteSinkEnabled) [self pushRemote:[@"CRASH " stringByAppendingString:txt]];
}

#pragma mark - Safe mode counter

- (NSInteger)crashStreak { return [_prefs[kStreakKey] integerValue]; }

- (void)markBootStarted {
    _prefs[kStreakKey] = @([self crashStreak] + 1);
    [self savePrefs];
}

- (void)markBootSucceeded {
    if ([self crashStreak] == 0) return;
    _prefs[kStreakKey] = @0;
    [self savePrefs];
    [self log:VSLogLevelInfo tag:@"boot" fmt:@"boot confirmed healthy, streak reset"];
}

#pragma mark - Readers

- (NSArray<NSString *> *)recentLines {
    __block NSArray *snap;
    dispatch_sync(_q, ^{ snap = [self->_ring copy]; });
    return snap;
}

- (NSString *)fullLogText {
    return [[self recentLines] componentsJoinedByString:@"\n"];
}

@end
