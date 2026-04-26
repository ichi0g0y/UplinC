#import "MedicApp.h"

@implementation MedicApp (Mode)

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

@end
