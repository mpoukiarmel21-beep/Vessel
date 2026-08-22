//  VSHookNetwork.h — layer 8: a LOG-ONLY HTTP probe. Changes no behaviour.
//
//  Why this exists
//  ---------------
//  Three builds were spent guessing at the signup hang because the journal could
//  not see it. VSWatchdog only detects a frozen MAIN THREAD, and the failure is
//  not a freeze: the UI stays responsive, so the watchdog is silent and the log
//  ends ten seconds after boot with nothing about the broken step in it. A step
//  that "does nothing" is either a request that never came back or a request that
//  came back refused, and neither is visible anywhere today.
//
//  So this records, for every NSURLSession task the app creates:
//      → seq  METHOD path            (at creation)
//      ← seq  status (duration)      (at completion)
//  A step that hangs is then a → with no matching ←, or a ← carrying 4xx. That is
//  the difference between "the coordinator did not advance" and a cause.
//
//  What it deliberately does NOT record
//  -----------------------------------
//  No headers, no bodies, no cookies, no query string, no host userinfo — only the
//  HTTP method, the URL PATH and the status code. Paths and key names are the
//  ceiling for instrumentation in this project; a value never reaches the journal,
//  which is what keeps the export safe to paste and safe to push to the sink.
//
//  It installs nothing that can change a result: every replacement calls the
//  original, the completion-handler wrapper invokes the app's handler with the
//  untouched arguments, and a delegate whose class does not already implement
//  -URLSession:task:didCompleteWithError: is left alone rather than given one.
//  Switchable off from Diagnostics like the isolation layers (VSLayerNetwork).

#import <Foundation/Foundation.h>

@interface VSHookNetwork : NSObject

/// Swizzles the NSURLSession task factories and, as they appear, the session
/// delegates' completion callback. Safe to call once at boot; returns NO only if
/// the concrete NSURLSession class could not be resolved.
+ (BOOL)install;

@property (class, readonly) BOOL isInstalled;

/// Requests created but never completed, newest first, as "METHOD path (age)".
/// This is the answer to "which call is the step waiting on?" — empty in a healthy
/// session, one line long when a step is stuck. Capped, paths only.
+ (NSString *)pendingDescription;

@end
