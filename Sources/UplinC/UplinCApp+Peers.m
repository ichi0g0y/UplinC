#import "UplinCApp.h"
#include <net/if.h>

@implementation UplinCApp (Peers)

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
        if ([now timeIntervalSinceDate:lastSeen] <= 10.0) {
            [peers addObject:[peer copy]];
        }
    }
    return peers;
}

- (NSString *)formatPeerAge:(NSTimeInterval)age {
    if (age < 0.0) {
        age = 0.0;
    }
    if (age < 60.0) {
        return [NSString stringWithFormat:@"%.0fs ago", age];
    }
    if (age < 3600.0) {
        return [NSString stringWithFormat:@"%.0fm ago", age / 60.0];
    }
    if (age < 86400.0) {
        long hours = (long)(age / 3600.0);
        long minutes = ((long)age % 3600) / 60;
        if (minutes == 0) {
            return [NSString stringWithFormat:@"%ldh ago", hours];
        }
        return [NSString stringWithFormat:@"%ldh %ldm ago", hours, minutes];
    }
    long days = (long)(age / 86400.0);
    return [NSString stringWithFormat:@"%ldd ago", days];
}

- (void)updatePeerStatusWithUCPeerAddresses:(NSArray<NSString *> *)ucPeerAddresses {
    NSArray<NSDictionary<NSString *, id> *> *peers = [self recentHeartbeatPeers];
    NSMutableArray<NSString *> *compactUCAddresses = [[NSMutableArray alloc] init];
    NSMutableSet<NSNumber *> *currentUCScopes = [[NSMutableSet alloc] init];
    for (NSString *address in ucPeerAddresses) {
        [compactUCAddresses addObject:[self compactAddress:address]];
        struct in6_addr parsedAddr;
        uint32_t parsedScope = 0;
        if ([self parseIPv6Address:address into:&parsedAddr scopeID:&parsedScope] && parsedScope > 0) {
            [currentUCScopes addObject:@(parsedScope)];
        }
    }
    [self.ucInterfaceScopes setSet:currentUCScopes];
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
            NSString *fullAddress = peer[@"address"] ?: @"";
            NSString *address = [self compactAddress:fullAddress];
            NSDate *lastSeen = peer[@"lastSeen"];
            NSTimeInterval age = [lastSeen isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:lastSeen] : 0;
            [parts addObject:[NSString stringWithFormat:@"%@/%@ %.0fs", host, address, age]];
            [fullParts addObject:[NSString stringWithFormat:@"%@/%@ %.0fs", host, fullAddress, age]];
        }
        summary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC %@", ucSummary, [parts componentsJoinedByString:@"; "]];
        fullSummary = [NSString stringWithFormat:@"Peers: UC %@ | UplinC %@", [ucPeerAddresses componentsJoinedByString:@","], [fullParts componentsJoinedByString:@"; "]];
    }

    if (![summary isEqualToString:self.lastLoggedPeerSummary]) {
        [self appendLog:[NSString stringWithFormat:@"peer_summary %@", fullSummary ?: summary]];
        self.lastLoggedPeerSummary = summary;
    }
    [self updateToggleStates];
}

@end
