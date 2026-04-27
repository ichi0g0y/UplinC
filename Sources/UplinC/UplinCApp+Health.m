#import "UplinCApp.h"

@implementation UplinCApp (Health)

- (void)startHealthTimer {
    self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(checkHealth) userInfo:nil repeats:YES];
}

- (void)startHeartbeatTimer {
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(heartbeatTick) userInfo:nil repeats:YES];
}

- (void)heartbeatTick {
    [self drainHeartbeatSocket];
    [self updateEffectiveParentRole];
    [self sendHeartbeatViaBonjour];
    [self rebuildMachinesSubmenu];
}

- (void)checkHealth {
    [self updateEffectiveParentRole];
    BOOL running = [self isProcessRunning:@"UniversalControl"];
    self.statusMenuItem.title = running ? @"UniversalControl: running" : @"UniversalControl: missing";
    self.lastCheckMenuItem.title = [NSString stringWithFormat:@"Last check: %@", [self formattedTime:[NSDate date]]];
    if (!self.hasLastUniversalControlRunning || self.lastUniversalControlRunning != running) {
        [self appendLog:[NSString stringWithFormat:@"process_state UniversalControl=%@", running ? @"running" : @"missing"]];
        self.lastUniversalControlRunning = running;
        self.hasLastUniversalControlRunning = YES;
    }
    if (!self.resetInProgress) {
        [self setStatusIcon:(running ? @"link" : @"exclamationmark.triangle")
             fallbackTitle:(running ? @"UC" : @"UC!")
              description:(running ? @"Universal Control OK" : @"Universal Control missing")];
    }

    if ([self canAutoReset] && !running) {
        [self appendLog:@"trigger process_missing reason=UniversalControl"];
        [self resetUniversalControl:@"UniversalControl process was missing" force:YES manual:NO];
    }

    if (self.tcpWatchEnabled) {
        [self checkTCPLinkHealth];
    }
    [self checkHeartbeatHealth];
}

- (void)checkTCPLinkHealth {
    NSInteger ucConnectionCount = 0;
    NSInteger rapportLinkLocalCount = 0;
    NSArray<NSString *> *ucPeerAddresses = nil;
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucPeerAddresses:&ucPeerAddresses];
    if (ucConnectionCount != self.lastLoggedUCConnectionCount || rapportLinkLocalCount != self.lastLoggedRapportLinkLocalCount) {
        [self appendLog:[NSString stringWithFormat:@"tcp_state ucConnections=%ld rapportLinkLocal=%ld seen=%@ misses=%ld", (long)ucConnectionCount, (long)rapportLinkLocalCount, self.tcpLinkHasBeenSeen ? @"yes" : @"no", (long)self.missedTCPChecks]];
        self.lastLoggedUCConnectionCount = ucConnectionCount;
        self.lastLoggedRapportLinkLocalCount = rapportLinkLocalCount;
    }

    if (ucConnectionCount > 0) {
        if (self.missedTCPChecks > 0) {
            [self appendLog:[NSString stringWithFormat:@"tcp_recovered previousMisses=%ld ucConnections=%ld", (long)self.missedTCPChecks, (long)ucConnectionCount]];
        }
        self.tcpLinkHasBeenSeen = YES;
        self.missedTCPChecks = 0;
    } else if (self.tcpLinkHasBeenSeen) {
        self.missedTCPChecks += 1;
        [self appendLog:[NSString stringWithFormat:@"tcp_missing miss=%ld/12", (long)self.missedTCPChecks]];
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
        [self appendLog:@"trigger tcp_missing misses=12 durationSeconds=60"];
        [self resetUniversalControl:@"Universal Control TCP links disappeared for 60 seconds" force:YES manual:NO];
    } else if (!self.resetInProgress && self.tcpLinkHasBeenSeen && self.missedTCPChecks > 0) {
        [self setStatusIcon:@"exclamationmark.triangle" fallbackTitle:@"UC!" description:@"Universal Control TCP links missing"];
    }
}

- (void)checkHeartbeatHealth {
    NSArray<NSString *> *peerAddresses = [self universalControlPeerAddresses];

    if ((NSInteger)peerAddresses.count != self.lastLoggedHeartbeatPeerCount) {
        [self appendLog:[NSString stringWithFormat:@"heartbeat_peers count=%ld addresses=%@", (long)peerAddresses.count, [peerAddresses componentsJoinedByString:@","]]];
        self.lastLoggedHeartbeatPeerCount = peerAddresses.count;
    }

    [self.ucPeersEverSeen addObjectsFromArray:peerAddresses];

    NSDate *now = [NSDate date];
    NSArray<NSDictionary<NSString *, id> *> *recent = [self recentHeartbeatPeers];

    NSString *freshestHost = nil;
    NSTimeInterval freshestAge = -1.0;
    NSInteger freshCount = 0;
    for (NSDictionary<NSString *, id> *peer in recent) {
        NSDate *lastSeen = peer[@"lastSeen"];
        if (![lastSeen isKindOfClass:[NSDate class]]) {
            continue;
        }
        NSTimeInterval age = [now timeIntervalSinceDate:lastSeen];
        if (age > 15.0) {
            continue;
        }
        freshCount += 1;
        if (freshestAge < 0.0 || age < freshestAge) {
            freshestAge = age;
            freshestHost = peer[@"host"] ?: @"peer";
        }
    }

    NSTimeInterval globalAge = [[NSDate date] timeIntervalSinceDate:self.lastHeartbeatReceivedAt];
    if (self.heartbeatPeerHasBeenSeen && globalAge > 15.0) {
        self.missedHeartbeatChecks += 1;
    } else if (self.heartbeatPeerHasBeenSeen) {
        self.missedHeartbeatChecks = 0;
    }

    if (freshestHost != nil) {
        NSString *header;
        if (freshCount >= 2) {
            header = [NSString stringWithFormat:@"Heartbeat: %@+%ld %.0fs ago, miss %ld", freshestHost, (long)(freshCount - 1), freshestAge, (long)self.missedHeartbeatChecks];
        } else {
            header = [NSString stringWithFormat:@"Heartbeat: %@ %.0fs ago, miss %ld", freshestHost, freshestAge, (long)self.missedHeartbeatChecks];
        }
        if (header.length > 160) {
            header = [[header substringToIndex:157] stringByAppendingString:@"..."];
        }
        self.heartbeatStatusMenuItem.title = header;
    } else if (self.heartbeatPeerHasBeenSeen) {
        self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: stale, miss %ld", (long)self.missedHeartbeatChecks];
    } else {
        self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: waiting, peers %ld bonjour %lu", (long)peerAddresses.count, (unsigned long)self.bonjourPeerAddresses.count];
    }

    [self updatePeerStatusWithUCPeerAddresses:peerAddresses];

    if ([self canAutoReset] && self.heartbeatPeerHasBeenSeen && self.missedHeartbeatChecks >= 6 && self.ucPeersEverSeen.count > 0 && peerAddresses.count == 0) {
        self.missedHeartbeatChecks = 0;
        [self appendLog:[NSString stringWithFormat:@"trigger heartbeat_missing misses=6 tcpAlsoMissing=yes ucPeersEverSeen=%lu", (unsigned long)self.ucPeersEverSeen.count]];
        [self resetUniversalControl:@"UplinC heartbeat and TCP link disappeared" force:YES manual:NO];
    }
}

- (void)resetUniversalControl:(NSString *)reason force:(BOOL)force manual:(BOOL)manual {
    NSDate *now = [NSDate date];
    if (!force && [now timeIntervalSinceDate:self.lastResetAttempt] < 300.0) {
        [self appendLog:[NSString stringWithFormat:@"reset_suppressed cooldown reason=\"%@\" secondsSinceLast=%.1f", reason, [now timeIntervalSinceDate:self.lastResetAttempt]]];
        return;
    }
    self.lastResetAttempt = now;
    self.resetInProgress = YES;
    self.statusMenuItem.title = [NSString stringWithFormat:@"Resetting: %@", reason];
    [self setStatusIcon:@"arrow.triangle.2.circlepath" fallbackTitle:@"UC..." description:@"Universal Control restarting"];
    [self appendLog:[NSString stringWithFormat:@"reset_start force=%@ reason=\"%@\"", force ? @"yes" : @"no", reason]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int killUC = [self run:@"/usr/bin/killall" arguments:@[@"UniversalControl"]];
        int killSidecar = [self run:@"/usr/bin/killall" arguments:@[@"SidecarRelay"]];
        int killSharing = [self run:@"/usr/bin/killall" arguments:@[@"sharingd"]];
        [NSThread sleepForTimeInterval:2.0];
        int openStatus = [self run:@"/usr/bin/open" arguments:@[@"-gj", @"/System/Library/CoreServices/UniversalControl.app"]];
        [self appendLog:[NSString stringWithFormat:@"reset_commands killUniversalControl=%d killSidecarRelay=%d killSharingd=%d openUniversalControl=%d", killUC, killSidecar, killSharing, openStatus]];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterMediumStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            self.lastResetMenuItem.title = [NSString stringWithFormat:@"Last reset: %@", [formatter stringFromDate:[NSDate date]]];
            self.statusMenuItem.title = @"Reset complete";
            self.resetInProgress = NO;
            [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];
            [self appendLog:[NSString stringWithFormat:@"reset_complete reason=\"%@\"", reason]];
            [self notifyResetComplete:reason manual:manual];
        });
    });
}

@end
