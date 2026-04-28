#import "UplinCApp.h"

static const NSTimeInterval kHeartbeatStaleSeconds = 15.0;
static const NSInteger kHeartbeatTriggerMisses = 6;
static const NSInteger kTCPMissesUntilReset = 12;
static const NSInteger kProcessMissesUntilReset = 2;
static const NSTimeInterval kPostResetGraceSeconds = 60.0;
static const NSTimeInterval kPostWakeGraceSeconds = 90.0;
static const NSTimeInterval kHealthTickSeconds = 5.0;
static const NSTimeInterval kResetExitPollIntervalSeconds = 0.2;
static const NSTimeInterval kResetExitPollTimeoutSeconds = 3.0;

@implementation UplinCApp (Health)

- (void)startHealthTimer {
    self.healthTimer = [NSTimer timerWithTimeInterval:5.0 target:self selector:@selector(checkHealth) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.healthTimer forMode:NSRunLoopCommonModes];
}

- (BOOL)isInResetGrace {
    if (self.resetGraceUntil == nil) {
        return NO;
    }
    return [[NSDate date] timeIntervalSinceDate:self.resetGraceUntil] < 0.0;
}

- (BOOL)isInPostWakeGrace {
    if (self.wakeAt == nil) {
        return NO;
    }
    return [[NSDate date] timeIntervalSinceDate:self.wakeAt] < kPostWakeGraceSeconds;
}

- (void)clearTransientHealthCounters {
    self.failureLogHits = 0;
    self.failureLogScore = 0.0;
    [self.failureLogEvents removeAllObjects];
    [self.recentLogMessageHashes removeAllObjects];
    self.missedTCPChecks = 0;
    self.missedHeartbeatChecks = 0;
    self.missedProcessChecks = 0;
    self.tcpLinkHasBeenSeen = NO;
    self.heartbeatPeerHasBeenSeen = NO;
    self.logStatusMenuItem.title = self.logTask != nil ? @"Log watch: running, failures 0.0/4.0" : self.logStatusMenuItem.title;
}

- (void)handleSystemDidWake:(NSNotification *)note {
    (void)note;
    self.wakeAt = [NSDate date];
    [self clearTransientHealthCounters];
    [self appendLog:[NSString stringWithFormat:@"system_wake graceSeconds=%.0f", kPostWakeGraceSeconds]];
}

- (void)handleSystemWillSleep:(NSNotification *)note {
    (void)note;
    [self appendLog:@"system_sleep"];
}

- (void)startHeartbeatTimer {
    self.heartbeatTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(heartbeatTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
}

- (void)heartbeatTick {
    [self drainHeartbeatSocket];
    [self sendHeartbeatViaBonjour];
    [self refreshBonjourResolutionsIfNeeded];
    NSDate *now = [NSDate date];
    if (self.lastHeartbeatPruneAt == nil || [now timeIntervalSinceDate:self.lastHeartbeatPruneAt] > 60.0) {
        [self pruneStaleHeartbeatPeers];
        self.lastHeartbeatPruneAt = now;
    }
}

- (void)checkHealth {
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

    BOOL inGrace = [self isInResetGrace] || [self isInPostWakeGrace];
    if (![self canAutoReset] || inGrace) {
        self.missedProcessChecks = 0;
    } else if (running) {
        if (self.missedProcessChecks > 0) {
            [self appendLog:[NSString stringWithFormat:@"process_recovered previousMisses=%ld", (long)self.missedProcessChecks]];
        }
        self.missedProcessChecks = 0;
    } else {
        self.missedProcessChecks += 1;
        [self appendLog:[NSString stringWithFormat:@"process_missing miss=%ld/%ld", (long)self.missedProcessChecks, (long)kProcessMissesUntilReset]];
        if (self.missedProcessChecks >= kProcessMissesUntilReset) {
            NSInteger triggeredMisses = self.missedProcessChecks;
            self.missedProcessChecks = 0;
            [self appendLog:[NSString stringWithFormat:@"trigger process_missing reason=UniversalControl misses=%ld durationSeconds=%ld", (long)triggeredMisses, (long)(triggeredMisses * (NSInteger)kHealthTickSeconds)]];
            [self resetUniversalControl:@"UniversalControl process was missing" force:YES weak:NO manual:NO broadcast:YES];
        }
    }

    if (self.tcpWatchEnabled) {
        [self checkTCPLinkHealth];
    }
    [self checkHeartbeatHealth];
    [self recordDiagnosticTick];
}

- (void)checkTCPLinkHealth {
    NSInteger ucConnectionCount = 0;
    NSInteger rapportLinkLocalCount = 0;
    NSInteger ucIncompleteCount = 0;
    NSArray<NSString *> *ucPeerAddresses = nil;
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucIncompleteCount:&ucIncompleteCount ucPeerAddresses:&ucPeerAddresses];
    if (ucConnectionCount != self.lastLoggedUCConnectionCount || rapportLinkLocalCount != self.lastLoggedRapportLinkLocalCount) {
        [self appendLog:[NSString stringWithFormat:@"tcp_state ucConnections=%ld rapportLinkLocal=%ld ucIncomplete=%ld seen=%@ misses=%ld", (long)ucConnectionCount, (long)rapportLinkLocalCount, (long)ucIncompleteCount, self.tcpLinkHasBeenSeen ? @"yes" : @"no", (long)self.missedTCPChecks]];
        self.lastLoggedUCConnectionCount = ucConnectionCount;
        self.lastLoggedRapportLinkLocalCount = rapportLinkLocalCount;
    }

    BOOL inGrace = [self isInResetGrace] || [self isInPostWakeGrace];
    if (ucConnectionCount > 0) {
        if (self.missedTCPChecks > 0) {
            [self appendLog:[NSString stringWithFormat:@"tcp_recovered previousMisses=%ld ucConnections=%ld", (long)self.missedTCPChecks, (long)ucConnectionCount]];
        }
        self.tcpLinkHasBeenSeen = YES;
        self.missedTCPChecks = 0;
    } else if (self.tcpLinkHasBeenSeen && !inGrace && ucIncompleteCount == 0) {
        self.missedTCPChecks += 1;
        [self appendLog:[NSString stringWithFormat:@"tcp_missing miss=%ld/%ld", (long)self.missedTCPChecks, (long)kTCPMissesUntilReset]];
    }

    NSString *ucState = self.tcpLinkHasBeenSeen ? [NSString stringWithFormat:@"UC %ld", (long)ucConnectionCount] : @"UC unseen";
    if (self.tcpLinkHasBeenSeen && ucConnectionCount == 0) {
        ucState = [NSString stringWithFormat:@"UC miss %ld/%ld", (long)self.missedTCPChecks, (long)kTCPMissesUntilReset];
    }
    self.tcpStatusMenuItem.title = [NSString stringWithFormat:@"TCP link: %@, rapportd LL %ld", ucState, (long)rapportLinkLocalCount];

    if ([self canAutoReset] && !inGrace && self.tcpLinkHasBeenSeen && self.missedTCPChecks >= kTCPMissesUntilReset) {
        self.missedTCPChecks = 0;
        self.tcpLinkHasBeenSeen = NO;
        self.tcpStatusMenuItem.title = @"TCP link: reset triggered";
        [self appendLog:[NSString stringWithFormat:@"trigger tcp_missing misses=%ld durationSeconds=%ld", (long)kTCPMissesUntilReset, (long)(kTCPMissesUntilReset * 5)]];
        [self resetUniversalControl:@"Universal Control TCP links disappeared for 60 seconds" force:YES weak:NO manual:NO broadcast:YES];
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

    for (NSString *peerAddress in peerAddresses) {
        [self noteUCPeerSeen:peerAddress];
    }

    NSDate *now = [NSDate date];
    NSArray<NSDictionary<NSString *, id> *> *recent = [self recentHeartbeatPeers];

    BOOL inGrace = [self isInResetGrace] || [self isInPostWakeGrace];
    NSString *freshestHost = nil;
    NSTimeInterval freshestAge = -1.0;
    NSInteger freshCount = 0;
    for (NSDictionary<NSString *, id> *peer in recent) {
        NSDate *lastSeen = peer[@"lastSeen"];
        if (![lastSeen isKindOfClass:[NSDate class]]) {
            continue;
        }
        NSTimeInterval age = [now timeIntervalSinceDate:lastSeen];
        if (age > kHeartbeatStaleSeconds) {
            continue;
        }
        freshCount += 1;
        if (freshestAge < 0.0 || age < freshestAge) {
            freshestAge = age;
            freshestHost = peer[@"host"] ?: @"peer";
        }
    }

    NSTimeInterval globalAge = [[NSDate date] timeIntervalSinceDate:self.lastHeartbeatReceivedAt];
    if (self.heartbeatPeerHasBeenSeen && globalAge > kHeartbeatStaleSeconds && !inGrace) {
        self.missedHeartbeatChecks += 1;
    } else if (self.heartbeatPeerHasBeenSeen && globalAge <= kHeartbeatStaleSeconds) {
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

    if ([self canAutoReset] && !inGrace && self.heartbeatPeerHasBeenSeen && self.missedHeartbeatChecks >= kHeartbeatTriggerMisses && self.ucPeersEverSeen.count > 0 && peerAddresses.count == 0) {
        self.missedHeartbeatChecks = 0;
        [self appendLog:[NSString stringWithFormat:@"trigger heartbeat_missing misses=%ld tcpAlsoMissing=yes ucPeersEverSeen=%lu", (long)kHeartbeatTriggerMisses, (unsigned long)self.ucPeersEverSeen.count]];
        [self resetUniversalControl:@"UplinC heartbeat and TCP link disappeared" force:YES weak:NO manual:NO broadcast:YES];
    }
}

- (void)resetUniversalControl:(NSString *)reason force:(BOOL)force weak:(BOOL)isWeak manual:(BOOL)manual broadcast:(BOOL)broadcast {
    NSDate *now = [NSDate date];
    if (!force && [now timeIntervalSinceDate:self.lastWeakResetAttempt] < 300.0) {
        [self appendLog:[NSString stringWithFormat:@"reset_suppressed cooldown reason=\"%@\" secondsSinceLast=%.1f", reason, [now timeIntervalSinceDate:self.lastWeakResetAttempt]]];
        return;
    }
    if (self.resetInProgress) {
        [self appendLog:[NSString stringWithFormat:@"reset_suppressed in_progress reason=\"%@\"", reason]];
        return;
    }
    if (broadcast) {
        [self sendResetCommandViaBonjour:reason];
    }
    if (isWeak) {
        self.lastWeakResetAttempt = now;
    } else {
        self.lastResetAttempt = now;
    }
    self.resetInProgress = YES;
    self.statusMenuItem.title = [NSString stringWithFormat:@"Resetting: %@", reason];
    [self setStatusIcon:@"arrow.triangle.2.circlepath" fallbackTitle:@"UC..." description:@"Universal Control restarting"];
    [self appendLog:[NSString stringWithFormat:@"reset_start force=%@ weak=%@ reason=\"%@\"", force ? @"yes" : @"no", isWeak ? @"yes" : @"no", reason]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int killUC = [self run:@"/usr/bin/killall" arguments:@[@"UniversalControl"]];
        int killSidecar = [self run:@"/usr/bin/killall" arguments:@[@"SidecarRelay"]];
        int killSharing = [self run:@"/usr/bin/killall" arguments:@[@"sharingd"]];

        NSDate *waitStart = [NSDate date];
        NSDate *deadline = [waitStart dateByAddingTimeInterval:kResetExitPollTimeoutSeconds];
        NSInteger pollAttempts = 0;
        BOOL exited = NO;
        while ([deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:kResetExitPollIntervalSeconds];
            pollAttempts += 1;
            if (![self isProcessRunning:@"UniversalControl"]) {
                exited = YES;
                break;
            }
        }
        NSTimeInterval waitMs = [[NSDate date] timeIntervalSinceDate:waitStart] * 1000.0;
        [self appendLog:[NSString stringWithFormat:@"reset_wait_exit exited=%@ attempts=%ld waitMs=%.0f", exited ? @"yes" : @"no", (long)pollAttempts, waitMs]];

        int openStatus = [self run:@"/usr/bin/open" arguments:@[@"-gj", @"/System/Library/CoreServices/UniversalControl.app"]];
        [self appendLog:[NSString stringWithFormat:@"reset_commands killUniversalControl=%d killSidecarRelay=%d killSharingd=%d openUniversalControl=%d", killUC, killSidecar, killSharing, openStatus]];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterMediumStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
            self.lastResetMenuItem.title = [NSString stringWithFormat:@"Last reset: %@", [formatter stringFromDate:[NSDate date]]];
            self.statusMenuItem.title = @"Reset complete";
            self.resetInProgress = NO;
            self.resetGraceUntil = [NSDate dateWithTimeIntervalSinceNow:kPostResetGraceSeconds];
            [self clearTransientHealthCounters];
            [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];
            [self appendLog:[NSString stringWithFormat:@"reset_complete reason=\"%@\" graceSeconds=%.0f", reason, kPostResetGraceSeconds]];
            [self notifyResetComplete:reason manual:manual];
        });
    });
}

@end
