//  VSWatchdog.m

#import "VSWatchdog.h"
#import "VSLog.h"
#import <pthread.h>

#pragma mark - Main-thread breadcrumb ring

// Single writer (the main thread, inside VSMark) + one racy reader (the monitor
// queue, only when a stall is already suspected). A torn read at worst mislabels
// one diagnostic line, so no lock is warranted on the hot path. VS_TRAIL is a
// power of two so the index masks cleanly and a uint32_t wrap stays in bounds.
#define VS_TRAIL 16u
static const char * volatile gTrailMsg[VS_TRAIL];
static double       volatile gTrailAt [VS_TRAIL];
static volatile uint32_t     gTrailIdx;   // total marks; newest slot = (idx-1) & mask

void VSMark(const char *section) {
    if (!section || !pthread_main_np()) return;
    uint32_t i = gTrailIdx;                       // main-thread-only writer
    gTrailMsg[i & (VS_TRAIL - 1)] = section;
    gTrailAt [i & (VS_TRAIL - 1)] = CFAbsoluteTimeGetCurrent();
    gTrailIdx = i + 1;
}

#pragma mark - Monitor

@implementation VSWatchdog

static dispatch_source_t gTimer;    // retained for the life of the process (ARC static)
static dispatch_queue_t  gMon;
static double volatile    gLastPong;
static BOOL               gStalling;      // monitor-queue only
static double             gStallBegan;    // monitor-queue only
static double             gLastStallLog;  // monitor-queue only

static const double kStallThreshold = 4.0;   // seconds of silence before we shout

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLastPong = CFAbsoluteTimeGetCurrent();
        VSMark("boot");

        gMon = dispatch_queue_create("vessel.watchdog", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gMon);
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                                  NSEC_PER_SEC, (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gTimer, ^{ [VSWatchdog tick]; });
        dispatch_resume(gTimer);
        VSLogI(@"watchdog", @"main-thread monitor armed (stall threshold %.0fs)", kStallThreshold);
    });
}

/// Runs on gMon every second. Posts a ping to the main queue (which only runs
/// once the main thread is free) and judges liveness by how stale the last answer
/// is — independent of the breadcrumbs, which are used purely for attribution.
+ (void)tick {
    double now = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_main_queue(), ^{ gLastPong = CFAbsoluteTimeGetCurrent(); });

    double idle = now - gLastPong;
    if (idle >= kStallThreshold) {
        if (!gStalling) {
            gStalling = YES;
            gStallBegan = gLastPong;      // best estimate of when it wedged
            gLastStallLog = now;
            [self reportStall:idle ongoing:NO];
        } else if (now - gLastStallLog >= 5.0) {
            gLastStallLog = now;
            [self reportStall:idle ongoing:YES];   // heartbeat while still frozen
        }
    } else if (gStalling) {
        gStalling = NO;
        VSLogW(@"watchdog", @"main thread RECOVERED after ~%.1fs", now - gStallBegan);
    }
}

+ (void)reportStall:(double)idle ongoing:(BOOL)ongoing {
    double now = CFAbsoluteTimeGetCurrent();
    uint32_t idx = gTrailIdx;
    NSMutableString *trail = [NSMutableString string];
    int shown = 0;
    for (uint32_t n = 0; n < VS_TRAIL && n < idx && shown < 6; n++, shown++) {
        uint32_t k = (idx - 1 - n) & (VS_TRAIL - 1);
        const char *m = gTrailMsg[k];
        if (!m) break;
        [trail appendFormat:@"\n    - %s (%.1fs ago)", m, now - gTrailAt[k]];
    }
    VSLogE(@"watchdog",
           @"MAIN THREAD STALLED ~%.1fs%@ — last main-thread activity:%@",
           idle, ongoing ? @" (still frozen)" : @"",
           trail.length ? trail : @"\n    - (none recorded — stall is outside Vessel's hooks)");
}

@end
