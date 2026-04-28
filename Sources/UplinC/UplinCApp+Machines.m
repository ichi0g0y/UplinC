#import "UplinCApp.h"
#include <net/if.h>

static const NSTimeInterval kUCPeerDisplayTTLSeconds = 600.0;
static const NSTimeInterval kOnlineThresholdSeconds = 10.0;

@implementation UplinCApp (Machines)

- (NSArray<NSDictionary<NSString *, id> *> *)allKnownMachines {
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *machines = [[NSMutableArray alloc] init];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *machineByAddress = [[NSMutableDictionary alloc] init];
    NSDate *now = [NSDate date];

    for (NSMutableDictionary<NSString *, id> *peer in self.heartbeatPeers.allValues) {
        NSDate *lastSeen = peer[@"lastSeen"];
        NSString *peerID = peer[@"id"];
        if (![lastSeen isKindOfClass:[NSDate class]] || ![peerID isKindOfClass:[NSString class]] || peerID.length == 0) {
            continue;
        }

        NSMutableSet<NSString *> *addresses = [[NSMutableSet alloc] init];
        NSString *senderAddress = peer[@"address"];
        if ([senderAddress isKindOfClass:[NSString class]] && senderAddress.length > 0) {
            NSString *canonical = [self canonicalIPv6String:senderAddress] ?: senderAddress;
            [addresses addObject:canonical];
        }
        NSArray<NSData *> *bonjourAddrs = self.bonjourPeerAddresses[peerID];
        for (NSData *data in bonjourAddrs) {
            if (data.length < sizeof(struct sockaddr)) {
                continue;
            }
            const struct sockaddr *sa = (const struct sockaddr *)data.bytes;
            NSString *canonical = [self canonicalizedAddressFromSockaddr:sa];
            if (canonical.length > 0) {
                [addresses addObject:canonical];
            }
        }

        BOOL bonjourAlive = (self.bonjourPeers[peerID] != nil) && (self.bonjourPeerAddresses[peerID].count > 0);
        NSDate *machineLastSeen = bonjourAlive ? now : lastSeen;

        NSMutableDictionary<NSString *, id> *machine = [[NSMutableDictionary alloc] init];
        machine[@"id"] = peerID;
        NSString *host = peer[@"host"];
        machine[@"host"] = ([host isKindOfClass:[NSString class]] && host.length > 0) ? host : peerID;
        machine[@"addresses"] = addresses;
        machine[@"lastSeen"] = machineLastSeen;
        machine[@"online"] = @([now timeIntervalSinceDate:machineLastSeen] <= kOnlineThresholdSeconds);
        machine[@"hbSeeded"] = @YES;

        NSMutableDictionary<NSString *, id> *heartbeat = [[NSMutableDictionary alloc] init];
        heartbeat[@"lastSeen"] = lastSeen;
        NSDictionary *scopes = peer[@"scopesLastSeen"];
        if ([scopes isKindOfClass:[NSDictionary class]]) {
            heartbeat[@"scopesLastSeen"] = scopes;
        }
        machine[@"heartbeat"] = heartbeat;

        [machines addObject:machine];
        for (NSString *address in addresses) {
            machineByAddress[address] = machine;
        }
    }

    NSSet<NSString *> *seededPeerIDs = [NSSet setWithArray:self.heartbeatPeers.allKeys];
    for (NSString *bonjourName in self.bonjourPeers) {
        if (bonjourName.length == 0 || [seededPeerIDs containsObject:bonjourName]) {
            continue;
        }
        NSArray<NSData *> *bonjourAddrs = self.bonjourPeerAddresses[bonjourName];
        if (bonjourAddrs.count == 0) {
            continue;
        }
        NSMutableSet<NSString *> *addresses = [[NSMutableSet alloc] init];
        for (NSData *data in bonjourAddrs) {
            if (data.length < sizeof(struct sockaddr)) {
                continue;
            }
            const struct sockaddr *sa = (const struct sockaddr *)data.bytes;
            NSString *canonical = [self canonicalizedAddressFromSockaddr:sa];
            if (canonical.length > 0) {
                [addresses addObject:canonical];
            }
        }
        if (addresses.count == 0) {
            continue;
        }

        NSString *resolvedHost = nil;
        for (NSString *addr in addresses) {
            NSString *cached = self.resolvedHostnamesByAddress[addr];
            if (cached.length > 0) {
                resolvedHost = cached;
                break;
            }
        }
        if (resolvedHost.length == 0) {
            for (NSString *addr in addresses) {
                [self resolveHostnameForAddressIfNeeded:addr];
            }
        }

        NSMutableDictionary<NSString *, id> *machine = [[NSMutableDictionary alloc] init];
        machine[@"id"] = bonjourName;
        machine[@"host"] = resolvedHost.length > 0
            ? resolvedHost
            : [bonjourName substringToIndex:MIN((NSUInteger)8, bonjourName.length)];
        machine[@"addresses"] = addresses;
        machine[@"lastSeen"] = now;
        machine[@"online"] = @YES;
        machine[@"hbSeeded"] = @YES;
        [machines addObject:machine];
        for (NSString *addr in addresses) {
            machineByAddress[addr] = machine;
        }
    }

    NSDate *displayCutoff = [now dateByAddingTimeInterval:-kUCPeerDisplayTTLSeconds];
    for (NSString *address in self.ucPeersLastSeen) {
        NSDate *ucLastSeen = self.ucPeersLastSeen[address];
        if (![ucLastSeen isKindOfClass:[NSDate class]] || [ucLastSeen compare:displayCutoff] == NSOrderedAscending) {
            continue;
        }

        NSMutableDictionary<NSString *, id> *machine = machineByAddress[address];
        if (machine == nil) {
            machine = [[NSMutableDictionary alloc] init];
            machine[@"id"] = address;
            NSString *resolvedHost = self.resolvedHostnamesByAddress[address];
            if (resolvedHost.length > 0) {
                machine[@"host"] = resolvedHost;
            } else {
                machine[@"host"] = [self compactAddress:address];
                [self resolveHostnameForAddressIfNeeded:address];
            }
            NSMutableSet<NSString *> *addresses = [[NSMutableSet alloc] init];
            [addresses addObject:address];
            machine[@"addresses"] = addresses;
            machine[@"lastSeen"] = ucLastSeen;
            machine[@"online"] = @([now timeIntervalSinceDate:ucLastSeen] <= kOnlineThresholdSeconds);
            [machines addObject:machine];
            machineByAddress[address] = machine;
        }

        NSMutableDictionary<NSString *, id> *uc = machine[@"uc"];
        if (![uc isKindOfClass:[NSMutableDictionary class]]) {
            uc = [[NSMutableDictionary alloc] init];
            machine[@"uc"] = uc;
        }
        NSDate *prevUCLastSeen = uc[@"lastSeen"];
        if (![prevUCLastSeen isKindOfClass:[NSDate class]] || [ucLastSeen compare:prevUCLastSeen] == NSOrderedDescending) {
            uc[@"lastSeen"] = ucLastSeen;
        }

        struct in6_addr parsed;
        uint32_t parsedScope = 0;
        if ([self parseIPv6Address:address into:&parsed scopeID:&parsedScope] && parsedScope > 0) {
            NSMutableSet<NSNumber *> *scopes = uc[@"scopes"];
            if (![scopes isKindOfClass:[NSMutableSet class]]) {
                scopes = [[NSMutableSet alloc] init];
                uc[@"scopes"] = scopes;
            }
            [scopes addObject:@(parsedScope)];
        }

        NSDate *machineLastSeen = machine[@"lastSeen"];
        if (![machineLastSeen isKindOfClass:[NSDate class]] || [ucLastSeen compare:machineLastSeen] == NSOrderedDescending) {
            machine[@"lastSeen"] = ucLastSeen;
            machine[@"online"] = @([now timeIntervalSinceDate:ucLastSeen] <= kOnlineThresholdSeconds);
        }
    }

    [self foldOrphanLinkLocalUCIntoSingleHBMachine:machines now:now];

    [machines sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL onlineA = [a[@"online"] boolValue];
        BOOL onlineB = [b[@"online"] boolValue];
        if (onlineA != onlineB) {
            return onlineA ? NSOrderedAscending : NSOrderedDescending;
        }
        NSString *hostA = ([a[@"host"] isKindOfClass:[NSString class]]) ? a[@"host"] : @"";
        NSString *hostB = ([b[@"host"] isKindOfClass:[NSString class]]) ? b[@"host"] : @"";
        return [hostA localizedCaseInsensitiveCompare:hostB];
    }];

    return machines;
}

- (BOOL)addressesContainLinkLocal:(NSSet<NSString *> *)addresses {
    for (NSString *address in addresses) {
        if ([address.lowercaseString hasPrefix:@"fe80:"]) {
            return YES;
        }
    }
    return NO;
}

- (void)foldOrphanLinkLocalUCIntoSingleHBMachine:(NSMutableArray<NSMutableDictionary<NSString *, id> *> *)machines
                                              now:(NSDate *)now {
    NSMutableDictionary<NSString *, id> *primary = nil;
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *foldable = [[NSMutableArray alloc] init];
    for (NSMutableDictionary<NSString *, id> *machine in machines) {
        if ([machine[@"hbSeeded"] boolValue]) {
            if (primary != nil) {
                self.lastMachineFoldState = nil;
                return;
            }
            primary = machine;
        } else if ([self addressesContainLinkLocal:machine[@"addresses"]]) {
            [foldable addObject:machine];
        }
    }
    if (primary == nil || foldable.count == 0) {
        self.lastMachineFoldState = nil;
        return;
    }

    NSMutableSet<NSString *> *primaryAddresses = primary[@"addresses"];
    NSMutableDictionary<NSString *, id> *primaryUC = primary[@"uc"];
    if (![primaryUC isKindOfClass:[NSMutableDictionary class]]) {
        primaryUC = [[NSMutableDictionary alloc] init];
        primary[@"uc"] = primaryUC;
    }
    NSMutableSet<NSNumber *> *primaryUCScopes = primaryUC[@"scopes"];
    if (![primaryUCScopes isKindOfClass:[NSMutableSet class]]) {
        primaryUCScopes = [[NSMutableSet alloc] init];
        primaryUC[@"scopes"] = primaryUCScopes;
    }

    for (NSMutableDictionary<NSString *, id> *orphan in foldable) {
        NSSet<NSString *> *orphanAddresses = orphan[@"addresses"];
        if ([orphanAddresses isKindOfClass:[NSSet class]]) {
            [primaryAddresses unionSet:orphanAddresses];
        }
        NSDictionary<NSString *, id> *orphanUC = orphan[@"uc"];
        if ([orphanUC isKindOfClass:[NSDictionary class]]) {
            NSDate *orphanUCLastSeen = orphanUC[@"lastSeen"];
            NSDate *primaryUCLastSeen = primaryUC[@"lastSeen"];
            if ([orphanUCLastSeen isKindOfClass:[NSDate class]] &&
                (![primaryUCLastSeen isKindOfClass:[NSDate class]] ||
                 [orphanUCLastSeen compare:primaryUCLastSeen] == NSOrderedDescending)) {
                primaryUC[@"lastSeen"] = orphanUCLastSeen;
            }
            NSSet<NSNumber *> *orphanScopes = orphanUC[@"scopes"];
            if ([orphanScopes isKindOfClass:[NSSet class]]) {
                [primaryUCScopes unionSet:orphanScopes];
            }
        }
        NSDate *orphanLastSeen = orphan[@"lastSeen"];
        NSDate *primaryLastSeen = primary[@"lastSeen"];
        if ([orphanLastSeen isKindOfClass:[NSDate class]] &&
            (![primaryLastSeen isKindOfClass:[NSDate class]] ||
             [orphanLastSeen compare:primaryLastSeen] == NSOrderedDescending)) {
            primary[@"lastSeen"] = orphanLastSeen;
            primary[@"online"] = @([now timeIntervalSinceDate:orphanLastSeen] <= kOnlineThresholdSeconds);
        }
    }
    [machines removeObjectsInArray:foldable];
    NSString *currentState = [NSString stringWithFormat:@"%@:%lu", primary[@"host"], (unsigned long)foldable.count];
    if (![currentState isEqualToString:self.lastMachineFoldState]) {
        [self appendLog:[NSString stringWithFormat:@"machines_heuristic_fold count=%lu primary=%@",
                         (unsigned long)foldable.count, primary[@"host"]]];
        self.lastMachineFoldState = currentState;
    }
}

@end
