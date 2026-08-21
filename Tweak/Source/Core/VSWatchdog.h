//  VSWatchdog.h — main-thread stall detector (pure diagnostic).
//
//  A spinning Instagram progress indicator does NOT prove the main thread is
//  alive: CoreAnimation keeps a spinner turning on the render server even when
//  the main thread is wedged. So "ça tourne à l'infini" is, most often, a
//  MAIN-THREAD hang — and the one thing that turns a reproducible hang into a
//  fixable bug is knowing *where* the main thread was when it stopped answering.
//
//  This watchdog does two cheap things:
//    1. Every second it asks the main queue to timestamp itself. If that answer
//       goes stale for >= 4 s, the main thread is stalled and it logs a WARN.
//    2. Hot hooks drop a VSMark("module:op") breadcrumb whenever they run ON the
//       main thread. On a stall the watchdog prints the last few, so the guilty
//       module names itself instead of us guessing and disabling layers blindly.
//
//  It NEVER suspends or touches another thread's memory — a diagnostic that can
//  crash the host is worse than the bug it chases.

#import <Foundation/Foundation.h>

/// Records a main-thread breadcrumb for post-mortem attribution. No-op off the
/// main thread; a couple of stores into a fixed ring otherwise — cheap enough for
/// hot paths. `section` MUST be a string literal (stored by pointer, never
/// copied), e.g. VSMark("keychain:broad-copy").
void VSMark(const char *section);

@interface VSWatchdog : NSObject
/// Arms the background monitor. Idempotent. Call once, early, from the main thread.
+ (void)start;
@end
