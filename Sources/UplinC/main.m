#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static const int UplinCHeartbeatPort = 54176;

@interface MedicApp : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *statusMenuItem;
@property NSMenuItem *lastCheckMenuItem;
@property NSMenuItem *logStatusMenuItem;
@property NSMenuItem *tcpStatusMenuItem;
@property NSMenuItem *heartbeatStatusMenuItem;
@property NSMenuItem *peerStatusMenuItem;
@property NSMenuItem *lastResetMenuItem;
@property NSMenuItem *logFileMenuItem;
@property NSMenuItem *autoHealMenuItem;
@property NSMenuItem *parentModeMenuItem;
@property NSMenuItem *modeAutoMenuItem;
@property NSMenuItem *modeParentMenuItem;
@property NSMenuItem *modeChildMenuItem;
@property NSMenuItem *logWatchMenuItem;
@property NSMenuItem *tcpWatchMenuItem;
@property NSTimer *healthTimer;
@property NSTask *logTask;
@property BOOL autoHealEnabled;
@property BOOL parentModeEnabled;
@property BOOL logWatchEnabled;
@property BOOL tcpWatchEnabled;
@property BOOL heartbeatPeerHasBeenSeen;
@property BOOL tcpLinkHasBeenSeen;
@property BOOL resetInProgress;
@property NSString *modePreference;
@property NSString *instanceID;
@property NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *heartbeatPeers;
@property BOOL lastUniversalControlRunning;
@property BOOL hasLastUniversalControlRunning;
@property NSInteger lastLoggedUCConnectionCount;
@property NSInteger lastLoggedRapportLinkLocalCount;
@property NSInteger lastLoggedHeartbeatPeerCount;
@property NSString *lastLoggedPeerSummary;
@property NSInteger missedHeartbeatChecks;
@property NSMutableDictionary<NSString *, NSNumber *> *missedHeartbeatByPeer;
@property NSMutableSet<NSString *> *ucPeersEverSeen;
@property int heartbeatSocket;
@property NSDate *lastResetAttempt;
@property NSDate *lastFailureLogAt;
@property NSDate *lastHeartbeatReceivedAt;
@property NSInteger failureLogHits;
@property NSInteger missedTCPChecks;
@end

@implementation MedicApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.autoHealEnabled = YES;
    self.logWatchEnabled = YES;
    self.tcpWatchEnabled = YES;
    self.heartbeatPeers = [[NSMutableDictionary alloc] init];
    self.missedHeartbeatByPeer = [[NSMutableDictionary alloc] init];
    self.ucPeersEverSeen = [[NSMutableSet alloc] init];
    self.heartbeatSocket = -1;
    self.lastResetAttempt = [NSDate distantPast];
    self.lastFailureLogAt = [NSDate distantPast];
    self.lastHeartbeatReceivedAt = [NSDate distantPast];
    [self configureIdentityAndMode];
    [self updateEffectiveParentRole];

    [self configureMenu];
    [self configureNotifications];
    [self startHeartbeatSocket];
    [self appendMedicLog:[NSString stringWithFormat:@"app_start name=UplinC id=%@ modePreference=%@ effectiveRole=%@ autoHeal=on logWatch=on tcpWatch=on heartbeat=on", self.instanceID, self.modePreference, [self effectiveRoleLabel]]];
    [self startHealthTimer];
    [self startLogWatcher];
    [self checkHealth];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self appendMedicLog:@"app_stop"];
    [self stopLogWatcher];
    [self stopHeartbeatSocket];
}

- (void)configureMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"UplinC";
    [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];

    NSMenu *menu = [[NSMenu alloc] init];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    self.lastCheckMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last check: never" action:nil keyEquivalent:@""];
    self.lastCheckMenuItem.enabled = NO;
    self.logStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Log watch: starting" action:nil keyEquivalent:@""];
    self.logStatusMenuItem.enabled = NO;
    self.tcpStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"TCP link: not seen yet" action:nil keyEquivalent:@""];
    self.tcpStatusMenuItem.enabled = NO;
    self.heartbeatStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Heartbeat: starting" action:nil keyEquivalent:@""];
    self.heartbeatStatusMenuItem.enabled = NO;
    self.peerStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Peers: none" action:nil keyEquivalent:@""];
    self.peerStatusMenuItem.enabled = NO;
    self.lastResetMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last reset: never" action:nil keyEquivalent:@""];
    self.lastResetMenuItem.enabled = NO;
    self.logFileMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open Log File" action:@selector(openLogFile:) keyEquivalent:@""];
    self.logFileMenuItem.target = self;

    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Universal Control" action:@selector(resetNow:) keyEquivalent:@"r"];
    resetItem.target = self;

    self.autoHealMenuItem = [[NSMenuItem alloc] initWithTitle:@"Auto Heal" action:@selector(toggleAutoHeal:) keyEquivalent:@""];
    self.autoHealMenuItem.target = self;
    self.parentModeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Mode: Auto" action:nil keyEquivalent:@""];
    NSMenu *modeSubmenu = [[NSMenu alloc] initWithTitle:@"Mode"];
    self.modeAutoMenuItem = [[NSMenuItem alloc] initWithTitle:@"Auto" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeAutoMenuItem.target = self;
    self.modeAutoMenuItem.representedObject = @"auto";
    self.modeParentMenuItem = [[NSMenuItem alloc] initWithTitle:@"Parent" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeParentMenuItem.target = self;
    self.modeParentMenuItem.representedObject = @"parent";
    self.modeChildMenuItem = [[NSMenuItem alloc] initWithTitle:@"Child" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeChildMenuItem.target = self;
    self.modeChildMenuItem.representedObject = @"child";
    [modeSubmenu addItem:self.modeAutoMenuItem];
    [modeSubmenu addItem:self.modeParentMenuItem];
    [modeSubmenu addItem:self.modeChildMenuItem];
    self.parentModeMenuItem.submenu = modeSubmenu;
    self.logWatchMenuItem = [[NSMenuItem alloc] initWithTitle:@"Watch UC Logs" action:@selector(toggleLogWatch:) keyEquivalent:@""];
    self.logWatchMenuItem.target = self;
    self.tcpWatchMenuItem = [[NSMenuItem alloc] initWithTitle:@"Watch TCP Link" action:@selector(toggleTCPWatch:) keyEquivalent:@""];
    self.tcpWatchMenuItem.target = self;

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;

    [menu addItem:self.statusMenuItem];
    [menu addItem:self.lastCheckMenuItem];
    [menu addItem:self.logStatusMenuItem];
    [menu addItem:self.tcpStatusMenuItem];
    [menu addItem:self.heartbeatStatusMenuItem];
    [menu addItem:self.peerStatusMenuItem];
    [menu addItem:self.lastResetMenuItem];
    [menu addItem:self.logFileMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:resetItem];
    [menu addItem:self.autoHealMenuItem];
    [menu addItem:self.parentModeMenuItem];
    [menu addItem:self.logWatchMenuItem];
    [menu addItem:self.tcpWatchMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
    [self updateToggleStates];
}

- (void)configureNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *error) {
        (void)granted;
        (void)error;
    }];
}

- (void)startHealthTimer {
    self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(checkHealth) userInfo:nil repeats:YES];
}

- (void)checkHealth {
    [self updateEffectiveParentRole];
    BOOL running = [self isProcessRunning:@"UniversalControl"];
    self.statusMenuItem.title = running ? @"UniversalControl: running" : @"UniversalControl: missing";
    self.lastCheckMenuItem.title = [NSString stringWithFormat:@"Last check: %@", [self formattedTime:[NSDate date]]];
    if (!self.hasLastUniversalControlRunning || self.lastUniversalControlRunning != running) {
        [self appendMedicLog:[NSString stringWithFormat:@"process_state UniversalControl=%@", running ? @"running" : @"missing"]];
        self.lastUniversalControlRunning = running;
        self.hasLastUniversalControlRunning = YES;
    }
    if (!self.resetInProgress) {
        [self setStatusIcon:(running ? @"link" : @"exclamationmark.triangle")
             fallbackTitle:(running ? @"UC" : @"UC!")
              description:(running ? @"Universal Control OK" : @"Universal Control missing")];
    }

    if ([self canAutoReset] && !running) {
        [self appendMedicLog:@"trigger process_missing reason=UniversalControl"];
        [self resetUniversalControl:@"UniversalControl process was missing" force:YES];
    }

    if (self.tcpWatchEnabled) {
        [self checkTCPLinkHealth];
    }
    [self checkHeartbeatHealth];
}

- (void)startLogWatcher {
    if (!self.logWatchEnabled || self.logTask != nil) {
        return;
    }

    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[
        @"stream",
        @"--style", @"compact",
        @"--predicate",
        @"process == \"UniversalControl\" OR process == \"SidecarRelay\" OR process == \"sharingd\""
    ];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    __weak MedicApp *weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) {
            return;
        }
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleLog:line ?: @""];
        });
    };

    NSError *error = nil;
    if ([task launchAndReturnError:&error]) {
        self.logTask = task;
        self.logStatusMenuItem.title = @"Log watch: running, failures 0/4";
        [self appendMedicLog:@"log_watch started"];
    } else {
        self.logWatchEnabled = NO;
        self.logStatusMenuItem.title = @"Log watch: unavailable";
        [self appendMedicLog:[NSString stringWithFormat:@"log_watch unavailable error=%@", error.localizedDescription ?: @"unknown"]];
        [self updateToggleStates];
    }
}

- (void)stopLogWatcher {
    [self.logTask terminate];
    self.logTask = nil;
    self.logStatusMenuItem.title = @"Log watch: stopped";
    [self appendMedicLog:@"log_watch stopped"];
}

- (void)handleLog:(NSString *)text {
    NSString *lower = [text lowercaseString];
    NSArray<NSString *> *failureWords = @[
        @"disconnected",
        @"connection interrupted",
        @"connection failed",
        @"connection refused",
        @"connection reset",
        @"timed out",
        @"not reachable",
        @"peer not found",
        @"device not found",
        @"receive failed",
        @"activate failed",
        @"p2pstream canceled"
    ];

    BOOL matched = NO;
    for (NSString *word in failureWords) {
        if ([lower containsString:word]) {
            matched = YES;
            break;
        }
    }
    if (!matched) {
        return;
    }

    NSDate *now = [NSDate date];
    if ([now timeIntervalSinceDate:self.lastFailureLogAt] > 120.0) {
        self.failureLogHits = 0;
    }

    self.lastFailureLogAt = now;
    self.failureLogHits += 1;
    self.logStatusMenuItem.title = [NSString stringWithFormat:@"Log watch: running, failures %ld/4", (long)self.failureLogHits];
    [self appendMedicLog:[NSString stringWithFormat:@"failure_log hit=%ld/4 line=\"%@\"", (long)self.failureLogHits, [self sanitizedSingleLine:text maxLength:500]]];
    if ([self canAutoReset] && self.failureLogHits >= 4) {
        self.failureLogHits = 0;
        self.logStatusMenuItem.title = @"Log watch: running, failures 0/4";
        [self appendMedicLog:@"trigger failure_logs count=4 windowSeconds=120"];
        [self resetUniversalControl:@"Universal Control failure logs were detected" force:NO];
    }
}

- (void)resetNow:(id)sender {
    (void)sender;
    [self appendMedicLog:@"manual_reset requested"];
    [self resetUniversalControl:@"Manual reset" force:YES];
}

- (void)toggleAutoHeal:(id)sender {
    (void)sender;
    self.autoHealEnabled = !self.autoHealEnabled;
    [self updateToggleStates];
    [self appendMedicLog:[NSString stringWithFormat:@"setting autoHeal=%@", self.autoHealEnabled ? @"on" : @"off"]];
}

- (void)selectMode:(id)sender {
    NSString *requested = nil;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        id represented = [(NSMenuItem *)sender representedObject];
        if ([represented isKindOfClass:[NSString class]]) {
            requested = represented;
        }
    }
    if (![@[@"auto", @"parent", @"child"] containsObject:requested]) {
        return;
    }
    if ([requested isEqualToString:self.modePreference]) {
        return;
    }
    self.modePreference = requested;
    [[NSUserDefaults standardUserDefaults] setObject:self.modePreference forKey:@"ModePreference"];
    [self updateEffectiveParentRole];
    [self updateToggleStates];
    [self appendMedicLog:[NSString stringWithFormat:@"setting modePreference=%@ effectiveRole=%@", self.modePreference, [self effectiveRoleLabel]]];
}

- (void)toggleLogWatch:(id)sender {
    (void)sender;
    self.logWatchEnabled = !self.logWatchEnabled;
    [self updateToggleStates];
    self.logWatchEnabled ? [self startLogWatcher] : [self stopLogWatcher];
    [self appendMedicLog:[NSString stringWithFormat:@"setting logWatch=%@", self.logWatchEnabled ? @"on" : @"off"]];
}

- (void)toggleTCPWatch:(id)sender {
    (void)sender;
    self.tcpWatchEnabled = !self.tcpWatchEnabled;
    [self updateToggleStates];
    self.tcpStatusMenuItem.title = self.tcpWatchEnabled ? @"TCP link: not seen yet" : @"TCP link: stopped";
    [self appendMedicLog:[NSString stringWithFormat:@"setting tcpWatch=%@", self.tcpWatchEnabled ? @"on" : @"off"]];
}

- (void)openLogFile:(id)sender {
    (void)sender;
    [self ensureMedicLogFileExists];
    int status = [self run:@"/usr/bin/open" arguments:@[[self medicLogPath]]];
    [self appendMedicLog:[NSString stringWithFormat:@"log_file opened status=%d", status]];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)updateToggleStates {
    self.autoHealMenuItem.state = self.autoHealEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.parentModeMenuItem.title = [NSString stringWithFormat:@"Mode: %@ (%@)", [self modePreferenceLabel], [self effectiveRoleLabel]];
    self.modeAutoMenuItem.state = [self.modePreference isEqualToString:@"auto"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.modeParentMenuItem.state = [self.modePreference isEqualToString:@"parent"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.modeChildMenuItem.state = [self.modePreference isEqualToString:@"child"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.logWatchMenuItem.state = self.logWatchEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.tcpWatchMenuItem.state = self.tcpWatchEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)canAutoReset {
    return self.autoHealEnabled && self.parentModeEnabled;
}

- (void)configureIdentityAndMode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *storedID = [defaults stringForKey:@"InstanceID"];
    if (storedID.length == 0) {
        storedID = [[NSUUID UUID] UUIDString];
        [defaults setObject:storedID forKey:@"InstanceID"];
    }
    self.instanceID = storedID;

    NSString *storedMode = [defaults stringForKey:@"ModePreference"];
    if (![@[@"auto", @"parent", @"child"] containsObject:storedMode]) {
        storedMode = @"auto";
        [defaults setObject:storedMode forKey:@"ModePreference"];
    }
    self.modePreference = storedMode;
}

- (void)updateEffectiveParentRole {
    BOOL oldValue = self.parentModeEnabled;

    if ([self.modePreference isEqualToString:@"parent"]) {
        self.parentModeEnabled = YES;
    } else if ([self.modePreference isEqualToString:@"child"]) {
        self.parentModeEnabled = NO;
    } else {
        NSArray<NSDictionary<NSString *, id> *> *peers = [self recentHeartbeatPeers];
        BOOL forcedParentSeen = NO;
        NSString *lowestAutoID = self.instanceID;

        for (NSDictionary<NSString *, id> *peer in peers) {
            NSString *mode = peer[@"mode"] ?: @"auto";
            NSString *peerID = peer[@"id"] ?: @"";
            if ([mode isEqualToString:@"parent"]) {
                forcedParentSeen = YES;
            }
            if ([mode isEqualToString:@"auto"] && peerID.length > 0 && [peerID compare:lowestAutoID] == NSOrderedAscending) {
                lowestAutoID = peerID;
            }
        }
        self.parentModeEnabled = !forcedParentSeen && [lowestAutoID isEqualToString:self.instanceID];
    }

    if (oldValue != self.parentModeEnabled) {
        [self appendMedicLog:[NSString stringWithFormat:@"effective_role changed modePreference=%@ effectiveRole=%@", self.modePreference, [self effectiveRoleLabel]]];
    }
}

- (NSString *)modePreferenceLabel {
    if ([self.modePreference isEqualToString:@"parent"]) {
        return @"Parent";
    }
    if ([self.modePreference isEqualToString:@"child"]) {
        return @"Child";
    }
    return @"Auto";
}

- (NSString *)effectiveRoleLabel {
    return self.parentModeEnabled ? @"Parent" : @"Child";
}

- (void)checkTCPLinkHealth {
    NSInteger ucConnectionCount = 0;
    NSInteger rapportLinkLocalCount = 0;
    NSArray<NSString *> *ucPeerAddresses = nil;
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucPeerAddresses:&ucPeerAddresses];
    if (ucConnectionCount != self.lastLoggedUCConnectionCount || rapportLinkLocalCount != self.lastLoggedRapportLinkLocalCount) {
        [self appendMedicLog:[NSString stringWithFormat:@"tcp_state ucConnections=%ld rapportLinkLocal=%ld seen=%@ misses=%ld", (long)ucConnectionCount, (long)rapportLinkLocalCount, self.tcpLinkHasBeenSeen ? @"yes" : @"no", (long)self.missedTCPChecks]];
        self.lastLoggedUCConnectionCount = ucConnectionCount;
        self.lastLoggedRapportLinkLocalCount = rapportLinkLocalCount;
    }

    if (ucConnectionCount > 0) {
        if (self.missedTCPChecks > 0) {
            [self appendMedicLog:[NSString stringWithFormat:@"tcp_recovered previousMisses=%ld ucConnections=%ld", (long)self.missedTCPChecks, (long)ucConnectionCount]];
        }
        self.tcpLinkHasBeenSeen = YES;
        self.missedTCPChecks = 0;
    } else if (self.tcpLinkHasBeenSeen) {
        self.missedTCPChecks += 1;
        [self appendMedicLog:[NSString stringWithFormat:@"tcp_missing miss=%ld/12", (long)self.missedTCPChecks]];
    }

    NSString *ucState = self.tcpLinkHasBeenSeen ? [NSString stringWithFormat:@"UC %ld", (long)ucConnectionCount] : @"UC unseen";
    if (self.tcpLinkHasBeenSeen && ucConnectionCount == 0) {
        ucState = [NSString stringWithFormat:@"UC miss %ld/12", (long)self.missedTCPChecks];
    }
    self.tcpStatusMenuItem.title = [NSString stringWithFormat:@"TCP link: %@, rapportd LL %ld", ucState, (long)rapportLinkLocalCount];

    if ([self canAutoReset] && self.tcpLinkHasBeenSeen && self.missedTCPChecks >= 12) {
        self.missedTCPChecks = 0;
        self.tcpLinkHasBeenSeen = NO;
        self.tcpStatusMenuItem.title = @"TCP link: reset triggered";
        [self appendMedicLog:@"trigger tcp_missing misses=12 durationSeconds=60"];
        [self resetUniversalControl:@"Universal Control TCP links disappeared for 60 seconds" force:YES];
    } else if (!self.resetInProgress && self.tcpLinkHasBeenSeen && self.missedTCPChecks > 0) {
        [self setStatusIcon:@"exclamationmark.triangle" fallbackTitle:@"UC!" description:@"Universal Control TCP links missing"];
    }
}

- (void)checkHeartbeatHealth {
    NSArray<NSString *> *peerAddresses = [self universalControlPeerAddresses];
    [self drainHeartbeatSocket];
    [self updateEffectiveParentRole];
    [self sendHeartbeatToPeerAddresses:peerAddresses];

    if ((NSInteger)peerAddresses.count != self.lastLoggedHeartbeatPeerCount) {
        [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_peers count=%ld addresses=%@", (long)peerAddresses.count, [peerAddresses componentsJoinedByString:@","]]];
        self.lastLoggedHeartbeatPeerCount = peerAddresses.count;
    }

    [self.ucPeersEverSeen addObjectsFromArray:peerAddresses];

    NSDate *now = [NSDate date];
    NSSet<NSString *> *currentTCPPeerSet = [NSSet setWithArray:peerAddresses];
    NSMutableDictionary<NSString *, NSDate *> *lastSeenByAddress = [[NSMutableDictionary alloc] init];
    NSMutableDictionary<NSString *, NSString *> *hostByAddress = [[NSMutableDictionary alloc] init];
    for (NSDictionary<NSString *, id> *peer in [self recentHeartbeatPeers]) {
        NSString *addr = peer[@"address"];
        NSDate *lastSeen = peer[@"lastSeen"];
        NSString *host = peer[@"host"];
        if ([addr isKindOfClass:[NSString class]] && addr.length > 0 && [lastSeen isKindOfClass:[NSDate class]]) {
            lastSeenByAddress[addr] = lastSeen;
            if ([host isKindOfClass:[NSString class]]) {
                hostByAddress[addr] = host;
            }
        }
    }

    NSMutableSet<NSString *> *trackedAddresses = [NSMutableSet setWithSet:self.ucPeersEverSeen];
    [trackedAddresses addObjectsFromArray:lastSeenByAddress.allKeys];

    NSString *freshestAddress = nil;
    NSTimeInterval freshestAge = 0.0;
    NSString *freshestHost = nil;
    NSInteger freshCount = 0;
    NSInteger maxPeerMiss = 0;
    NSString *staleHealAddress = nil;
    NSString *staleHealHost = nil;
    NSInteger staleHealMiss = 0;

    for (NSString *addr in trackedAddresses) {
        NSDate *lastSeen = lastSeenByAddress[addr];
        NSTimeInterval age = lastSeen ? [now timeIntervalSinceDate:lastSeen] : -1.0;
        NSInteger prevMiss = [self.missedHeartbeatByPeer[addr] integerValue];
        NSInteger miss = prevMiss;

        if (age >= 0.0 && age <= 15.0) {
            miss = 0;
            self.missedHeartbeatByPeer[addr] = @(0);
            freshCount += 1;
            if (freshestAddress == nil || age < freshestAge) {
                freshestAddress = addr;
                freshestAge = age;
                freshestHost = hostByAddress[addr] ?: addr;
            }
        } else {
            miss = prevMiss + 1;
            self.missedHeartbeatByPeer[addr] = @(miss);
        }

        if (miss > maxPeerMiss) {
            maxPeerMiss = miss;
        }

        BOOL tcpStillPresent = [currentTCPPeerSet containsObject:addr];
        if ([self.ucPeersEverSeen containsObject:addr] && !tcpStillPresent && miss >= 6 && miss > staleHealMiss) {
            staleHealAddress = addr;
            staleHealHost = hostByAddress[addr] ?: addr;
            staleHealMiss = miss;
        }
    }

    self.missedHeartbeatChecks = maxPeerMiss;

    if (freshestAddress != nil) {
        NSString *header;
        if (freshCount >= 2) {
            header = [NSString stringWithFormat:@"Heartbeat: %@+%ld %.0fs ago, miss %ld", freshestHost, (long)(freshCount - 1), freshestAge, (long)maxPeerMiss];
        } else {
            header = [NSString stringWithFormat:@"Heartbeat: %@ %.0fs ago, miss %ld", freshestHost, freshestAge, (long)maxPeerMiss];
        }
        if (header.length > 160) {
            header = [[header substringToIndex:157] stringByAppendingString:@"..."];
        }
        self.heartbeatStatusMenuItem.title = header;
    } else if (self.heartbeatPeerHasBeenSeen || self.ucPeersEverSeen.count > 0) {
        NSString *staleHost = staleHealHost ?: @"peer";
        if (staleHealAddress != nil) {
            self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: %@ stale, miss %ld", staleHost, (long)maxPeerMiss];
        } else {
            self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: stale, miss %ld", (long)maxPeerMiss];
        }
    } else {
        self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: waiting, peers %ld", (long)peerAddresses.count];
    }

    [self updatePeerStatusWithUCPeerAddresses:peerAddresses];

    if ([self canAutoReset] && staleHealAddress != nil) {
        NSString *compact = [self compactAddress:staleHealAddress];
        [self appendMedicLog:[NSString stringWithFormat:@"trigger heartbeat_missing peerHost=%@ peerAddress=%@ misses=%ld tcpAlsoMissing=yes", staleHealHost ?: @"unknown", compact, (long)staleHealMiss]];
        self.missedHeartbeatByPeer[staleHealAddress] = @(0);
        self.missedHeartbeatChecks = 0;
        [self resetUniversalControl:[NSString stringWithFormat:@"UplinC heartbeat and TCP link disappeared (peer %@)", staleHealHost ?: compact] force:YES];
    }
}

- (void)resetUniversalControl:(NSString *)reason force:(BOOL)force {
    NSDate *now = [NSDate date];
    if (!force && [now timeIntervalSinceDate:self.lastResetAttempt] < 300.0) {
        [self appendMedicLog:[NSString stringWithFormat:@"reset_suppressed cooldown reason=\"%@\" secondsSinceLast=%.1f", reason, [now timeIntervalSinceDate:self.lastResetAttempt]]];
        return;
    }
    self.lastResetAttempt = now;
    self.resetInProgress = YES;
    self.statusMenuItem.title = [NSString stringWithFormat:@"Resetting: %@", reason];
    [self setStatusIcon:@"arrow.triangle.2.circlepath" fallbackTitle:@"UC..." description:@"Universal Control restarting"];
    [self appendMedicLog:[NSString stringWithFormat:@"reset_start force=%@ reason=\"%@\"", force ? @"yes" : @"no", reason]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int killUC = [self run:@"/usr/bin/killall" arguments:@[@"UniversalControl"]];
        int killSidecar = [self run:@"/usr/bin/killall" arguments:@[@"SidecarRelay"]];
        int killSharing = [self run:@"/usr/bin/killall" arguments:@[@"sharingd"]];
        [NSThread sleepForTimeInterval:2.0];
        int openStatus = [self run:@"/usr/bin/open" arguments:@[@"-gj", @"/System/Library/CoreServices/UniversalControl.app"]];
        [self appendMedicLog:[NSString stringWithFormat:@"reset_commands killUniversalControl=%d killSidecarRelay=%d killSharingd=%d openUniversalControl=%d", killUC, killSidecar, killSharing, openStatus]];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterMediumStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            self.lastResetMenuItem.title = [NSString stringWithFormat:@"Last reset: %@", [formatter stringFromDate:[NSDate date]]];
            self.statusMenuItem.title = @"Reset complete";
            self.resetInProgress = NO;
            [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];
            [self appendMedicLog:[NSString stringWithFormat:@"reset_complete reason=\"%@\"", reason]];
            [self notifyResetComplete:reason];
        });
    });
}

- (void)startHeartbeatSocket {
    self.heartbeatSocket = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (self.heartbeatSocket < 0) {
        self.heartbeatStatusMenuItem.title = @"Heartbeat: socket failed";
        [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_socket failed errno=%d", errno]];
        return;
    }

    int yes = 1;
    setsockopt(self.heartbeatSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int flags = fcntl(self.heartbeatSocket, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(self.heartbeatSocket, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(UplinCHeartbeatPort);
    address.sin6_addr = in6addr_any;

    if (bind(self.heartbeatSocket, (struct sockaddr *)&address, sizeof(address)) < 0) {
        [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_bind failed port=%d errno=%d", UplinCHeartbeatPort, errno]];
        close(self.heartbeatSocket);
        self.heartbeatSocket = -1;
        self.heartbeatStatusMenuItem.title = @"Heartbeat: bind failed";
        return;
    }

    self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: UDP %d", UplinCHeartbeatPort];
    [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_socket started port=%d", UplinCHeartbeatPort]];
}

- (void)stopHeartbeatSocket {
    if (self.heartbeatSocket >= 0) {
        close(self.heartbeatSocket);
        self.heartbeatSocket = -1;
        [self appendMedicLog:@"heartbeat_socket stopped"];
    }
}

- (void)drainHeartbeatSocket {
    if (self.heartbeatSocket < 0) {
        return;
    }

    while (YES) {
        char buffer[512];
        struct sockaddr_in6 sender;
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(self.heartbeatSocket, buffer, sizeof(buffer) - 1, 0, (struct sockaddr *)&sender, &senderLength);
        if (received <= 0) {
            break;
        }

        buffer[received] = '\0';
        NSString *payload = [NSString stringWithUTF8String:buffer] ?: @"";
        if (![payload hasPrefix:@"UPLINC "]) {
            continue;
        }

        struct in6_addr canonicalAddr = sender.sin6_addr;
        uint32_t canonicalScope = sender.sin6_scope_id;
        if (IN6_IS_ADDR_LINKLOCAL(&canonicalAddr)) {
            uint16_t embedded = (uint16_t)((canonicalAddr.s6_addr[2] << 8) | canonicalAddr.s6_addr[3]);
            if (embedded != 0 && canonicalScope == 0) {
                canonicalScope = embedded;
            }
            canonicalAddr.s6_addr[2] = 0;
            canonicalAddr.s6_addr[3] = 0;
        }
        NSString *senderAddressString = [self formatIPv6Address:&canonicalAddr scopeID:canonicalScope];
        if (senderAddressString.length == 0) {
            senderAddressString = @"unknown";
        }
        NSDictionary<NSString *, NSString *> *fields = [self heartbeatFieldsFromPayload:payload];
        NSString *peerID = fields[@"id"] ?: senderAddressString;
        NSString *peerHost = fields[@"host"] ?: senderAddressString;
        NSString *peerMode = fields[@"mode"] ?: @"unknown";
        NSString *peerEffective = fields[@"effective"] ?: @"unknown";

        NSMutableDictionary<NSString *, id> *peer = self.heartbeatPeers[peerID];
        if (peer == nil) {
            peer = [[NSMutableDictionary alloc] init];
            self.heartbeatPeers[peerID] = peer;
        }
        peer[@"id"] = peerID;
        peer[@"host"] = peerHost;
        peer[@"mode"] = peerMode;
        peer[@"effective"] = peerEffective;
        peer[@"address"] = senderAddressString;
        peer[@"lastSeen"] = [NSDate date];

        self.heartbeatPeerHasBeenSeen = YES;
        self.lastHeartbeatReceivedAt = [NSDate date];
        self.missedHeartbeatChecks = 0;
        [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_received from=%@ id=%@ host=%@ mode=%@ effective=%@ payload=\"%@\"", senderAddressString, peerID, peerHost, peerMode, peerEffective, [self sanitizedSingleLine:payload maxLength:160]]];
    }
}

- (void)sendHeartbeatToPeerAddresses:(NSArray<NSString *> *)peerAddresses {
    if (self.heartbeatSocket < 0 || peerAddresses.count == 0) {
        return;
    }

    NSString *host = [self sanitizedToken:([[NSHost currentHost] localizedName] ?: [[NSHost currentHost] name] ?: @"unknown")];
    NSString *payload = [NSString stringWithFormat:@"UPLINC 1 id=%@ host=%@ mode=%@ effective=%@ time=%.0f", self.instanceID, host, self.modePreference, self.parentModeEnabled ? @"parent" : @"child", [[NSDate date] timeIntervalSince1970]];
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];

    for (NSString *peerAddress in peerAddresses) {
        struct in6_addr addr;
        uint32_t scopeID = 0;
        if (![self parseIPv6Address:peerAddress into:&addr scopeID:&scopeID]) {
            [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_send skipped invalidAddress=%@", peerAddress]];
            continue;
        }

        struct sockaddr_in6 destination;
        memset(&destination, 0, sizeof(destination));
        destination.sin6_len = sizeof(destination);
        destination.sin6_family = AF_INET6;
        destination.sin6_port = htons(UplinCHeartbeatPort);
        destination.sin6_addr = addr;
        destination.sin6_scope_id = scopeID;

        ssize_t sent = sendto(self.heartbeatSocket, payloadData.bytes, payloadData.length, 0, (struct sockaddr *)&destination, sizeof(destination));
        if (sent < 0) {
            [self appendMedicLog:[NSString stringWithFormat:@"heartbeat_send failed peer=%@ scope=%u errno=%d", peerAddress, scopeID, errno]];
        }
    }
}

- (NSDictionary<NSString *, NSString *> *)heartbeatFieldsFromPayload:(NSString *)payload {
    NSMutableDictionary<NSString *, NSString *> *fields = [[NSMutableDictionary alloc] init];
    NSArray<NSString *> *parts = [payload componentsSeparatedByString:@" "];
    for (NSString *part in parts) {
        NSRange equals = [part rangeOfString:@"="];
        if (equals.location == NSNotFound || equals.location == 0) {
            continue;
        }

        NSString *key = [part substringToIndex:equals.location];
        NSString *value = [part substringFromIndex:equals.location + equals.length];
        if (key.length > 0 && value.length > 0) {
            fields[key] = value;
        }
    }
    return fields;
}

- (NSArray<NSDictionary<NSString *, id> *> *)recentHeartbeatPeers {
    NSMutableArray<NSDictionary<NSString *, id> *> *peers = [[NSMutableArray alloc] init];
    NSDate *now = [NSDate date];

    for (NSMutableDictionary<NSString *, id> *peer in self.heartbeatPeers.allValues) {
        NSDate *lastSeen = peer[@"lastSeen"];
        if (![lastSeen isKindOfClass:[NSDate class]]) {
            continue;
        }
        if ([now timeIntervalSinceDate:lastSeen] <= 30.0) {
            [peers addObject:[peer copy]];
        }
    }
    return peers;
}

- (void)updatePeerStatusWithUCPeerAddresses:(NSArray<NSString *> *)ucPeerAddresses {
    NSArray<NSDictionary<NSString *, id> *> *peers = [self recentHeartbeatPeers];
    NSMutableArray<NSString *> *compactUCAddresses = [[NSMutableArray alloc] init];
    for (NSString *address in ucPeerAddresses) {
        [compactUCAddresses addObject:[self compactAddress:address]];
    }
    NSString *ucSummary = compactUCAddresses.count > 0 ? [compactUCAddresses componentsJoinedByString:@","] : @"none";
    NSString *summary = nil;
    NSString *fullSummary = nil;

    if (peers.count == 0) {
        summary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC none", ucSummary];
        fullSummary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC none", [ucPeerAddresses componentsJoinedByString:@","]];
    } else {
        NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
        NSMutableArray<NSString *> *fullParts = [[NSMutableArray alloc] init];
        NSDate *now = [NSDate date];
        for (NSDictionary<NSString *, id> *peer in peers) {
            NSString *host = peer[@"host"] ?: @"unknown";
            NSString *mode = peer[@"mode"] ?: @"?";
            NSString *effective = peer[@"effective"] ?: @"?";
            NSString *fullAddress = peer[@"address"] ?: @"";
            NSString *address = [self compactAddress:fullAddress];
            NSDate *lastSeen = peer[@"lastSeen"];
            NSTimeInterval age = [lastSeen isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:lastSeen] : 0;
            [parts addObject:[NSString stringWithFormat:@"%@/%@->%@/%@ %.0fs", host, mode, effective, address, age]];
            [fullParts addObject:[NSString stringWithFormat:@"%@/%@->%@/%@ %.0fs", host, mode, effective, fullAddress, age]];
        }
        summary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC %@", ucSummary, [parts componentsJoinedByString:@"; "]];
        fullSummary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC %@", [ucPeerAddresses componentsJoinedByString:@","], [fullParts componentsJoinedByString:@"; "]];
    }

    if (summary.length > 160) {
        summary = [[summary substringToIndex:157] stringByAppendingString:@"..."];
    }
    self.peerStatusMenuItem.title = summary;

    if (![summary isEqualToString:self.lastLoggedPeerSummary]) {
        [self appendMedicLog:[NSString stringWithFormat:@"peer_summary %@", fullSummary ?: summary]];
        self.lastLoggedPeerSummary = summary;
    }
    [self updateToggleStates];
}

- (NSString *)compactAddress:(NSString *)address {
    if (address.length <= 18) {
        return address;
    }
    return [NSString stringWithFormat:@"...%@", [address substringFromIndex:address.length - 14]];
}

- (NSString *)sanitizedToken:(NSString *)value {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._-"];
    NSMutableString *result = [[NSMutableString alloc] init];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
        } else {
            [result appendString:@"_"];
        }
    }
    return result.length > 0 ? result : @"unknown";
}

- (void)setStatusIcon:(NSString *)symbolName fallbackTitle:(NSString *)fallbackTitle description:(NSString *)description {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:description];
    if (image == nil) {
        self.statusItem.button.image = nil;
        self.statusItem.button.title = fallbackTitle;
        return;
    }

    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
    image = [image imageWithSymbolConfiguration:configuration] ?: image;
    image.template = YES;

    self.statusItem.button.title = @"";
    self.statusItem.button.image = image;
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip = description;
}

- (NSString *)formattedTime:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterMediumStyle;
    formatter.dateStyle = NSDateFormatterNoStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)medicLogPath {
    NSString *logsDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    return [logsDirectory stringByAppendingPathComponent:@"UplinC.log"];
}

- (void)appendMedicLog:(NSString *)message {
    @synchronized (self) {
        NSString *logsDirectory = [[self medicLogPath] stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:logsDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [self logTimestamp], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = [self medicLogPath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
            return;
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            return;
        }
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        [self rotateMedicLogIfNeeded];
    }
}

- (void)ensureMedicLogFileExists {
    NSString *logsDirectory = [[self medicLogPath] stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self medicLogPath]]) {
        [@"" writeToFile:[self medicLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (void)rotateMedicLogIfNeeded {
    NSString *path = [self medicLogPath];
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes fileSize];
    if (size < 1024 * 1024) {
        return;
    }

    NSString *oldPath = [path stringByAppendingString:@".1"];
    [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:path toPath:oldPath error:nil];
}

- (NSString *)logTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSZZZZZ";
    return [formatter stringFromDate:[NSDate date]];
}

- (NSString *)sanitizedSingleLine:(NSString *)text maxLength:(NSUInteger)maxLength {
    NSString *singleLine = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (singleLine.length <= maxLength) {
        return singleLine;
    }
    return [[singleLine substringToIndex:maxLength] stringByAppendingString:@"..."];
}

- (void)notifyResetComplete:(NSString *)reason {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Universal Control restarted";
    content.body = reason;
    content.sound = [UNNotificationSound defaultSound];

    NSString *identifier = [NSString stringWithFormat:@"uc-reset-%@", [[NSUUID UUID] UUIDString]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (BOOL)isProcessRunning:(NSString *)name {
    return [self run:@"/usr/bin/pgrep" arguments:@[@"-x", name]] == 0;
}

- (void)getTCPConnectionCount:(NSInteger *)ucConnectionCount rapportLinkLocalCount:(NSInteger *)rapportLinkLocalCount ucPeerAddresses:(NSArray<NSString *> **)ucPeerAddresses {
    *ucConnectionCount = 0;
    *rapportLinkLocalCount = 0;
    NSMutableOrderedSet<NSString *> *peers = [[NSMutableOrderedSet alloc] init];

    NSString *output = [self outputFrom:@"/usr/sbin/lsof" arguments:@[@"-nP", @"-iTCP", @"-sTCP:ESTABLISHED"]];
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        if (![line containsString:@"(ESTABLISHED)"]) {
            continue;
        }

        if ([line hasPrefix:@"Universal"]) {
            *ucConnectionCount += 1;
            NSString *peerAddress = [self peerAddressFromLsofLine:line];
            if (peerAddress.length > 0) {
                [peers addObject:peerAddress];
            }
        }

        if ([line hasPrefix:@"rapportd"] && [line containsString:@"[fe80:"]) {
            *rapportLinkLocalCount += 1;
        }
    }
    if (ucPeerAddresses != NULL) {
        *ucPeerAddresses = peers.array;
    }
}

- (NSArray<NSString *> *)universalControlPeerAddresses {
    NSInteger ucConnectionCount = 0;
    NSInteger rapportLinkLocalCount = 0;
    NSArray<NSString *> *peerAddresses = @[];
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucPeerAddresses:&peerAddresses];
    return peerAddresses;
}

- (NSString *)peerAddressFromLsofLine:(NSString *)line {
    NSRange arrow = [line rangeOfString:@"->["];
    if (arrow.location == NSNotFound) {
        return nil;
    }

    NSUInteger addressStart = arrow.location + arrow.length;
    NSRange closeBracket = [line rangeOfString:@"]" options:0 range:NSMakeRange(addressStart, line.length - addressStart)];
    if (closeBracket.location == NSNotFound || closeBracket.location <= addressStart) {
        return nil;
    }

    NSString *raw = [line substringWithRange:NSMakeRange(addressStart, closeBracket.location - addressStart)];
    return [self canonicalIPv6String:raw] ?: raw;
}

- (BOOL)parseIPv6Address:(NSString *)addressString into:(struct in6_addr *)outAddr scopeID:(uint32_t *)outScopeID {
    if (addressString.length == 0 || outAddr == NULL || outScopeID == NULL) {
        return NO;
    }

    NSString *hostPart = addressString;
    uint32_t scope = 0;
    NSRange percent = [addressString rangeOfString:@"%"];
    if (percent.location != NSNotFound) {
        hostPart = [addressString substringToIndex:percent.location];
        NSString *scopePart = [addressString substringFromIndex:percent.location + 1];
        int parsed = 0;
        NSScanner *scanner = [NSScanner scannerWithString:scopePart];
        if ([scanner scanInt:&parsed] && scanner.atEnd && parsed > 0) {
            scope = (uint32_t)parsed;
        } else {
            unsigned int idx = if_nametoindex(scopePart.UTF8String);
            scope = idx;
        }
    }

    struct in6_addr addr;
    memset(&addr, 0, sizeof(addr));
    if (inet_pton(AF_INET6, hostPart.UTF8String, &addr) != 1) {
        return NO;
    }

    if (IN6_IS_ADDR_LINKLOCAL(&addr)) {
        uint16_t embedded = (uint16_t)((addr.s6_addr[2] << 8) | addr.s6_addr[3]);
        if (embedded != 0 && scope == 0) {
            scope = embedded;
        }
        addr.s6_addr[2] = 0;
        addr.s6_addr[3] = 0;
    }

    *outAddr = addr;
    *outScopeID = scope;
    return YES;
}

- (NSString *)formatIPv6Address:(const struct in6_addr *)addr scopeID:(uint32_t)scopeID {
    char buf[INET6_ADDRSTRLEN];
    if (inet_ntop(AF_INET6, addr, buf, sizeof(buf)) == NULL) {
        return @"";
    }
    NSString *base = [NSString stringWithUTF8String:buf] ?: @"";
    if (scopeID > 0 && IN6_IS_ADDR_LINKLOCAL(addr)) {
        return [NSString stringWithFormat:@"%@%%%u", base, scopeID];
    }
    return base;
}

- (NSString *)canonicalIPv6String:(NSString *)addressString {
    struct in6_addr addr;
    uint32_t scope = 0;
    if (![self parseIPv6Address:addressString into:&addr scopeID:&scope]) {
        return nil;
    }
    return [self formatIPv6Address:&addr scopeID:scope];
}

- (int)run:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return -1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

- (NSString *)outputFrom:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return @"";
    }
    [task waitUntilExit];

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
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
