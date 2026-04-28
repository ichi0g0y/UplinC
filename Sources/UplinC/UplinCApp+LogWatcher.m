#import "UplinCApp.h"

static const double kStrongMarkerWeight = 1.0;
static const double kWeakMarkerCriticalWeight = 2.5;
static const double kWeakMarkerHeavyWeight = 1.0;
static const double kWeakMarkerLightWeight = 0.5;
static const NSTimeInterval kDuplicateSuppressionSeconds = 5.0;
static const NSTimeInterval kFailureLogWindowSeconds = 120.0;
static const double kFailureLogTriggerScore = 4.0;
static const NSUInteger kRecentLogHashesPruneAt = 64;

static NSArray<NSString *> *UCStrongMarkers(void) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[
            @"crashed",
            @"died",
            @"panic",
            @"fatal error",
            @"assertion failed"
        ];
    });
    return markers;
}

static NSArray<NSString *> *UCWeakMarkersCritical(void) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[
            @"reset source device"
        ];
    });
    return markers;
}

static NSArray<NSString *> *UCWeakMarkers(void) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[
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
            @"p2pstream canceled",
            @"p2pdirectlink canceled",
            @"kcancelederr",
            @"ehostunreach",
            @"etimedout"
        ];
    });
    return markers;
}

static NSArray<NSString *> *UCSeverityTokens(void) {
    static NSArray<NSString *> *tokens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokens = @[@"error", @"fail", @"fatal"];
    });
    return tokens;
}

static NSString *UCDupSuppressionKey(NSString *lower) {
    if (lower.length == 0) {
        return @"";
    }
    static NSRegularExpression *timestampRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timestampRE = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d{4}-\\d{2}-\\d{2}[ t]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:[+-]\\d{4})?\\s+"
                                                                options:0
                                                                  error:nil];
    });
    NSString *stripped = [timestampRE stringByReplacingMatchesInString:lower
                                                              options:0
                                                                range:NSMakeRange(0, lower.length)
                                                         withTemplate:@""];
    return stripped;
}

@implementation UplinCApp (LogWatcher)

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

    __weak UplinCApp *weakSelf = self;
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
        self.logStatusMenuItem.title = @"Log watch: running, failures 0.0/4.0";
        [self appendLog:@"log_watch started"];
    } else {
        self.logWatchEnabled = NO;
        self.logStatusMenuItem.title = @"Log watch: unavailable";
        [self appendLog:[NSString stringWithFormat:@"log_watch unavailable error=%@", error.localizedDescription ?: @"unknown"]];
        [self updateToggleStates];
    }
}

- (void)stopLogWatcher {
    [self.logTask terminate];
    self.logTask = nil;
    self.logStatusMenuItem.title = @"Log watch: stopped";
    [self appendLog:@"log_watch stopped"];
}

- (void)pruneFailureLogWindow {
    NSDate *now = [NSDate date];
    while (self.failureLogEvents.count > 0) {
        NSDictionary *oldest = self.failureLogEvents.firstObject;
        NSDate *oldestAt = oldest[@"at"];
        if (oldestAt != nil && [now timeIntervalSinceDate:oldestAt] > kFailureLogWindowSeconds) {
            [self.failureLogEvents removeObjectAtIndex:0];
        } else {
            break;
        }
    }
    double score = 0.0;
    for (NSDictionary *evt in self.failureLogEvents) {
        score += [evt[@"weight"] doubleValue];
    }
    if (score != self.failureLogScore) {
        self.failureLogScore = score;
        self.failureLogHits = (NSInteger)floor(score);
        if (self.logTask != nil) {
            self.logStatusMenuItem.title = [NSString stringWithFormat:@"Log watch: running, failures %.1f/%.1f", score, kFailureLogTriggerScore];
        }
    }
}

- (void)handleLog:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }
    NSString *lower = [trimmed lowercaseString];

    double weight = 0.0;
    BOOL strongHit = NO;
    for (NSString *marker in UCStrongMarkers()) {
        if ([lower containsString:marker]) {
            weight = kStrongMarkerWeight;
            strongHit = YES;
            break;
        }
    }
    if (!strongHit) {
        for (NSString *marker in UCWeakMarkersCritical()) {
            if ([lower containsString:marker]) {
                weight = kWeakMarkerCriticalWeight;
                strongHit = YES;
                break;
            }
        }
    }
    if (!strongHit) {
        for (NSString *marker in UCWeakMarkers()) {
            if (![lower containsString:marker]) {
                continue;
            }
            BOOL severityCo = NO;
            for (NSString *token in UCSeverityTokens()) {
                if ([lower containsString:token]) {
                    severityCo = YES;
                    break;
                }
            }
            weight = severityCo ? kWeakMarkerHeavyWeight : kWeakMarkerLightWeight;
            break;
        }
    }
    if (weight <= 0.0) {
        return;
    }

    NSDate *now = [NSDate date];
    NSString *sanitized = [self sanitizedSingleLine:trimmed maxLength:500];

    if ([self isInResetGrace] || [self isInPostWakeGrace]) {
        [self.failureLogEvents removeAllObjects];
        self.failureLogScore = 0.0;
        self.failureLogHits = 0;
        self.lastFailureLogAt = now;
        self.lastFailureLogLine = sanitized;
        self.logStatusMenuItem.title = @"Log watch: running, failures 0.0/4.0";
        [self appendLog:[NSString stringWithFormat:@"failure_log ignored=grace weight=%.1f line=\"%@\"", weight, sanitized]];
        return;
    }

    NSString *dupKeyRaw = UCDupSuppressionKey(lower);
    NSString *dupKey = [self sanitizedSingleLine:dupKeyRaw maxLength:200];
    NSDate *previousHit = self.recentLogMessageHashes[dupKey];
    if (previousHit != nil && [now timeIntervalSinceDate:previousHit] < kDuplicateSuppressionSeconds) {
        self.recentLogMessageHashes[dupKey] = now;
        [self appendLog:[NSString stringWithFormat:@"failure_log dup_suppressed weight=%.1f line=\"%@\"", weight, sanitized]];
        return;
    }
    self.recentLogMessageHashes[dupKey] = now;
    if (self.recentLogMessageHashes.count > kRecentLogHashesPruneAt) {
        NSMutableArray<NSString *> *expired = [NSMutableArray array];
        for (NSString *key in self.recentLogMessageHashes) {
            NSDate *seenAt = self.recentLogMessageHashes[key];
            if ([now timeIntervalSinceDate:seenAt] >= kDuplicateSuppressionSeconds) {
                [expired addObject:key];
            }
        }
        [self.recentLogMessageHashes removeObjectsForKeys:expired];
    }

    NSMutableDictionary<NSString *, id> *event = [NSMutableDictionary dictionary];
    event[@"at"] = now;
    event[@"weight"] = @(weight);
    event[@"text"] = sanitized;
    [self.failureLogEvents addObject:event];
    self.lastFailureLogAt = now;
    self.lastFailureLogLine = sanitized;

    [self pruneFailureLogWindow];
    double score = self.failureLogScore;
    self.logStatusMenuItem.title = [NSString stringWithFormat:@"Log watch: running, failures %.1f/%.1f", score, kFailureLogTriggerScore];
    [self appendLog:[NSString stringWithFormat:@"failure_log weight=%.1f score=%.1f/%.1f line=\"%@\"", weight, score, kFailureLogTriggerScore, sanitized]];

    if ([self canAutoReset] && score >= kFailureLogTriggerScore) {
        [self.failureLogEvents removeAllObjects];
        self.failureLogScore = 0.0;
        self.failureLogHits = 0;
        self.logStatusMenuItem.title = @"Log watch: running, failures 0.0/4.0";
        [self appendLog:[NSString stringWithFormat:@"trigger failure_logs score=%.1f windowSeconds=%.0f", score, kFailureLogWindowSeconds]];
        [self resetUniversalControl:@"Universal Control failure logs were detected" force:NO weak:YES manual:NO broadcast:YES];
    }
}

@end
