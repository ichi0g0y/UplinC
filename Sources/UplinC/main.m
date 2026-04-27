#import "MedicApp.h"

const int UplinCHeartbeatPort = 54176;

@implementation MedicApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.logWatchEnabled = YES;
    self.tcpWatchEnabled = YES;
    self.heartbeatPeers = [[NSMutableDictionary alloc] init];
    self.ucPeersEverSeen = [[NSMutableSet alloc] init];
    self.bonjourPeers = [[NSMutableDictionary alloc] init];
    self.bonjourPeerAddresses = [[NSMutableDictionary alloc] init];
    self.heartbeatSocket = -1;
    self.lastResetAttempt = [NSDate distantPast];
    self.lastFailureLogAt = [NSDate distantPast];
    self.lastHeartbeatReceivedAt = [NSDate distantPast];
    [self configureIdentityAndMode];
    [self updateEffectiveParentRole];

    [self configureMenu];
    [self configureNotifications];
    [self startHeartbeatSocket];
    [self startBonjour];
    [self appendMedicLog:[NSString stringWithFormat:@"app_start name=UplinC id=%@ modePreference=%@ effectiveRole=%@ autoHeal=%@ notifications=%@ logWatch=on tcpWatch=on heartbeat=on", self.instanceID, self.modePreference, [self effectiveRoleLabel], self.autoHealEnabled ? @"on" : @"off", self.notificationsEnabled ? @"on" : @"off"]];
    [self startHealthTimer];
    [self startHeartbeatTimer];
    [self startLogWatcher];
    [self checkHealth];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self appendMedicLog:@"app_stop"];
    [self stopLogWatcher];
    [self stopBonjour];
    [self stopHeartbeatSocket];
}

- (void)configureNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *error) {
        (void)granted;
        (void)error;
    }];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        MedicApp *delegate = [[MedicApp alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
