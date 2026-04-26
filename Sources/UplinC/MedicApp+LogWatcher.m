#import "MedicApp.h"

@implementation MedicApp (LogWatcher)

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

@end
