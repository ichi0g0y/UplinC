#import "UplinCApp.h"

static const NSUInteger kDiagSampleCapacity = 12;

@implementation UplinCApp (Diagnostic)

static void AppendSample(NSMutableArray<NSNumber *> *buffer, NSNumber *sample) {
    if (buffer == nil) {
        return;
    }
    [buffer addObject:sample];
    while (buffer.count > kDiagSampleCapacity) {
        [buffer removeObjectAtIndex:0];
    }
}

static NSString *PgrepSparkline(NSArray<NSNumber *> *samples) {
    if (samples.count == 0) {
        return @"-";
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:samples.count];
    for (NSNumber *value in samples) {
        [out appendString:value.boolValue ? @"o" : @"x"];
    }
    return out;
}

static NSString *IntegerSparkline(NSArray<NSNumber *> *samples) {
    if (samples.count == 0) {
        return @"-";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:samples.count];
    for (NSNumber *value in samples) {
        [parts addObject:[NSString stringWithFormat:@"%ld", (long)value.integerValue]];
    }
    return [parts componentsJoinedByString:@" "];
}

- (void)recordDiagnosticTick {
    BOOL pgrep = [self isProcessRunning:@"UniversalControl"];
    AppendSample(self.diagPgrepSamples, @(pgrep ? 1 : 0));
    AppendSample(self.diagTCPSamples, @(self.lastLoggedUCConnectionCount));
    NSArray<NSDictionary<NSString *, id> *> *recent = [self recentHeartbeatPeers];
    AppendSample(self.diagHeartbeatPeerSamples, @((NSInteger)recent.count));
}

- (void)rebuildDiagnosticSubmenu {
    if (self.diagnosticSubmenu == nil) {
        return;
    }
    [self pruneFailureLogWindow];
    self.diagPgrepItem.title = [NSString stringWithFormat:@"pgrep UC: %@", PgrepSparkline(self.diagPgrepSamples)];
    self.diagTCPItem.title = [NSString stringWithFormat:@"TCP UC: %@", IntegerSparkline(self.diagTCPSamples)];
    self.diagHeartbeatItem.title = [NSString stringWithFormat:@"HB peers: %@", IntegerSparkline(self.diagHeartbeatPeerSamples)];
    self.diagFailureScoreItem.title = [NSString stringWithFormat:@"Failure score: %.1f/4.0 (window 120s)", self.failureLogScore];
    NSString *last = self.lastFailureLogLine;
    if (last == nil || last.length == 0) {
        last = @"none";
    }
    if (last.length > 80) {
        last = [[last substringToIndex:77] stringByAppendingString:@"..."];
    }
    self.diagRecentLineItem.title = [NSString stringWithFormat:@"Last: %@", last];
}

@end
