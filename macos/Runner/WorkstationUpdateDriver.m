#import <Cocoa/Cocoa.h>
#import "WorkstationUpdateDriver.h"

@implementation WorkstationUpdateDriver

// The manual check's update prompt already records the user's decision to install.
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    if (self.prepareUpdate == nil) {
        reply(SPUUserUpdateChoiceSkip);
        return;
    }
    self.prepareUpdate(^(BOOL ready) {
        reply(ready ? SPUUserUpdateChoiceInstall : SPUUserUpdateChoiceSkip);
        if (!ready) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"更新暂缓";
            alert.informativeText = @"请回到工作台查看提示，然后重新检查更新。";
            [alert runModal];
        }
    });
}

@end
