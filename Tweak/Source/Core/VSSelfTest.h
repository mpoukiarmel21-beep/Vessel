//  VSSelfTest.h — runtime proof that the invariants actually hold on device.
//
//  I cannot run this project on the phone myself, so the phone has to report
//  back. Every boot, the self-test re-proves the properties the whole design
//  rests on and writes a PASS/FAIL report next to the logs:
//
//    * a VSStore survives a write + reopen, and recovers from a corrupt primary
//      (the "my account disappeared" class of bug),
//    * a generated identity round-trips through its plist form unchanged,
//    * identities never reuse an identifier across containers,
//    * a container's claimed model agrees with the screen geometry Instagram
//      reads from UIScreen (the User-Agent consistency check),
//    * the active container exists on disk and is recorded on disk, not just in
//      memory.
//
//  Layer checks (filesystem / keychain / defaults / cookies) are added to this
//  same report as those hooks land. Nothing here mutates real state: the store
//  tests run in <diag>/selftest and clean up after themselves.

#import <Foundation/Foundation.h>

@interface VSSelfTest : NSObject

/// Runs every check and logs a one-line summary. Called from VSBootstrap after
/// the container bootstrap. Never throws; a failing check is a logged FAIL, not
/// a crash — a self-test that could take Instagram down would be worse than no
/// self-test at all.
+ (void)runAtBoot;

/// Full report of the last run, newest first line "N passed, M failed".
/// Displayed by VSDiagnosticsVC and written to <diag>/selftest.txt.
+ (NSString *)lastReport;

@end
