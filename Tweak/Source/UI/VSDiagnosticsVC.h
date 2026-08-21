//  VSDiagnosticsVC.h — the phone reporting back (ARCHITECTURE §6, "Diagnostics").
//
//  I cannot run Instagram on the device myself, so this screen is how the device
//  tells me what happened: the boot breadcrumbs and log ring buffer, the self-test
//  PASS/FAIL report, and an opt-in remote sink (ntfy.sh topic) that is OFF by
//  default. Copy/share always run the text through VSRedact() first, so nothing
//  secret can leave the device even by a manual export.

#import <UIKit/UIKit.h>

@interface VSDiagnosticsVC : UIViewController
@end
