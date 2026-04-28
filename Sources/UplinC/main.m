#import "UplinCApp.h"

const int UplinCHeartbeatPort = 54176;

@implementation UplinCApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.logWatchEnabled = YES;
    self.tcpWatchEnabled = YES;
    self.heartbeatPeers = [[NSMutableDictionary alloc] init];
    [self loadUCPeersFromDefaults];
    self.ucInterfaceScopes = [[NSMutableSet alloc] init];
    self.recentRemoteResetNonces = [[NSMutableOrderedSet alloc] init];
    self.recentRemoteResetNonceAt = [[NSMutableDictionary alloc] init];
    self.bonjourPeers = [[NSMutableDictionary alloc] init];
    self.bonjourPeerAddresses = [[NSMutableDictionary alloc] init];
    self.resolvedHostnamesByAddress = [[NSMutableDictionary alloc] init];
    self.hostnameLookupAttemptedAt = [[NSMutableDictionary alloc] init];
    self.heartbeatSocket = -1;
    self.lastResetAttempt = [NSDate distantPast];
    self.lastWeakResetAttempt = [NSDate distantPast];
    self.lastFailureLogAt = [NSDate distantPast];
    self.lastHeartbeatReceivedAt = [NSDate distantPast];
    self.resetGraceUntil = [NSDate distantPast];
    self.wakeAt = [NSDate distantPast];
    self.failureLogEvents = [[NSMutableArray alloc] init];
    self.failureLogScore = 0.0;
    self.recentLogMessageHashes = [[NSMutableDictionary alloc] init];
    self.lastFailureLogLine = nil;
    self.diagPgrepSamples = [[NSMutableArray alloc] init];
    self.diagTCPSamples = [[NSMutableArray alloc] init];
    self.diagHeartbeatPeerSamples = [[NSMutableArray alloc] init];
    [self configureIdentity];

    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter addObserver:self selector:@selector(handleSystemDidWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(handleSystemWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];

    [self configureMenu];
    [self configureNotifications];
    [self startHeartbeatSocket];
    [self startBonjour];
    [self appendLog:[NSString stringWithFormat:@"app_start name=UplinC id=%@ autoHeal=%@ notifications=%@ syncReset=%@ logWatch=on tcpWatch=on heartbeat=on", self.instanceID, self.autoHealEnabled ? @"on" : @"off", self.notificationsEnabled ? @"on" : @"off", self.syncResetEnabled ? @"on" : @"off"]];
    [self startHealthTimer];
    [self startHeartbeatTimer];
    [self startLogWatcher];
    [self checkHealth];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self appendLog:@"app_stop"];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
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
        UplinCApp *delegate = [[UplinCApp alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
