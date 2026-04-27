#import "UplinCApp.h"

@implementation UplinCApp (Mode)

- (BOOL)canAutoReset {
    return self.autoHealEnabled;
}

- (void)configureIdentity {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *storedID = [defaults stringForKey:@"InstanceID"];
    if (storedID.length == 0) {
        storedID = [[NSUUID UUID] UUIDString];
        [defaults setObject:storedID forKey:@"InstanceID"];
    }
    self.instanceID = storedID;

    if ([defaults objectForKey:@"AutoHealEnabled"] == nil) {
        [defaults setBool:YES forKey:@"AutoHealEnabled"];
    }
    self.autoHealEnabled = [defaults boolForKey:@"AutoHealEnabled"];

    if ([defaults objectForKey:@"NotificationsEnabled"] == nil) {
        [defaults setBool:YES forKey:@"NotificationsEnabled"];
    }
    self.notificationsEnabled = [defaults boolForKey:@"NotificationsEnabled"];

    if ([defaults objectForKey:@"SyncResetEnabled"] == nil) {
        [defaults setBool:YES forKey:@"SyncResetEnabled"];
    }
    self.syncResetEnabled = [defaults boolForKey:@"SyncResetEnabled"];
}

@end
