//  VSLog.h — diagnostics: ring buffer, boot breadcrumbs, crash capture, optional remote sink.
//
//  Design notes
//  ------------
//  * Logs are written under the REAL data root (captured before any path
//    redirection), never inside a container. They must survive container
//    switches and "reset all" so post-mortem diagnosis stays possible.
//  * Boot breadcrumbs are the primary debugging tool: if Instagram dies during
//    init, the highest breadcrumb reached names the guilty module.
//  * The remote sink is OFF until explicitly enabled. Every line is passed
//    through VSRedact() first, which drops anything that looks like a secret.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VSLogLevel) {
    VSLogLevelDebug = 0,
    VSLogLevelInfo  = 1,
    VSLogLevelWarn  = 2,
    VSLogLevelError = 3,
};

/// Ordered boot steps. Keep contiguous and never renumber: the values end up in
/// logs and in the crash breadcrumb file, and are compared across builds.
typedef NS_ENUM(NSInteger, VSBootStep) {
    VSBootStepConstructor   = 1,
    VSBootStepPathsResolved = 2,
    VSBootStepStoreLoaded   = 3,
    VSBootStepHomeHooked    = 4,
    VSBootStepKeychainHooked= 5,
    VSBootStepDefaultsHooked= 6,
    VSBootStepCookiesHooked = 7,
    VSBootStepDeviceHooked  = 8,
    VSBootStepLocationHooked= 9,
    VSBootStepLocaleHooked  = 10,
    VSBootStepSelfTestDone  = 11,
    VSBootStepUIScheduled   = 12,
    VSBootStepUIAttached    = 13,
};

/// Strips values that must never leave the device (cookies, tokens, passwords,
/// long base64/hex blobs). Used on every line before it reaches the remote sink.
NSString *VSRedact(NSString *line);

@interface VSLog : NSObject

@property (class, readonly) VSLog *shared;

/// Absolute path of the current session log file (real data root, not container).
@property (nonatomic, readonly, copy) NSString *logFilePath;
/// Remote sink switch. Persisted outside containers. NO by default.
@property (nonatomic, assign) BOOL remoteSinkEnabled;
/// Unguessable ntfy.sh topic, generated once and persisted.
@property (nonatomic, readonly, copy) NSString *remoteTopic;

/// Must be called first, with a tweak-owned directory under the REAL
/// (pre-redirection) home — in practice +[VSPaths vesselRoot]. Logs land in
/// <realRoot>/diag so they survive container switches and "reset all".
- (void)bootstrapWithRealDataRoot:(NSString *)realRoot;

- (void)log:(VSLogLevel)level tag:(NSString *)tag fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(3, 4);
- (void)breadcrumb:(VSBootStep)step note:(NSString *)note;

/// Installs NSSetUncaughtExceptionHandler + fatal signal handlers.
- (void)installCrashHandlers;
/// Reads any crash file left by the previous run, logs it, then deletes it.
- (void)drainPreviousCrashReport;

/// Consecutive-boot-crash counter driving VSSafeMode.
- (NSInteger)crashStreak;
- (void)markBootStarted;
- (void)markBootSucceeded;

/// Newest-last snapshot of the in-memory ring buffer (for the Diagnostics UI).
- (NSArray<NSString *> *)recentLines;
- (NSString *)fullLogText;

@end

// The parameter is deliberately named _t and not `tag`: a macro parameter named
// `tag` is also substituted in the selector keyword `tag:`, expanding
// `tag:tag` into `@"boot":@"boot"` — a syntax error at every call site.
#define VSLogD(_t, ...) [[VSLog shared] log:VSLogLevelDebug tag:_t fmt:__VA_ARGS__]
#define VSLogI(_t, ...) [[VSLog shared] log:VSLogLevelInfo  tag:_t fmt:__VA_ARGS__]
#define VSLogW(_t, ...) [[VSLog shared] log:VSLogLevelWarn  tag:_t fmt:__VA_ARGS__]
#define VSLogE(_t, ...) [[VSLog shared] log:VSLogLevelError tag:_t fmt:__VA_ARGS__]
