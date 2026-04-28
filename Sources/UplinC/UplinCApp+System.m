#import "UplinCApp.h"
#include <arpa/inet.h>
#include <net/if.h>
#include <string.h>

@implementation UplinCApp (System)

- (BOOL)isProcessRunning:(NSString *)name {
    return [self run:@"/usr/bin/pgrep" arguments:@[@"-x", name]] == 0;
}
- (void)getTCPConnectionCount:(NSInteger *)ucConnectionCount rapportLinkLocalCount:(NSInteger *)rapportLinkLocalCount ucIncompleteCount:(NSInteger *)ucIncompleteCount ucPeerAddresses:(NSArray<NSString *> **)ucPeerAddresses {
    *ucConnectionCount = 0;
    *rapportLinkLocalCount = 0;
    if (ucIncompleteCount != NULL) {
        *ucIncompleteCount = 0;
    }
    NSMutableOrderedSet<NSString *> *peers = [[NSMutableOrderedSet alloc] init];

    NSString *output = [self outputFrom:@"/usr/sbin/lsof" arguments:@[@"-nP", @"-iTCP"]];
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        BOOL isUC = [line hasPrefix:@"Universal"];
        BOOL isRapport = [line hasPrefix:@"rapportd"];
        if (!isUC && !isRapport) {
            continue;
        }

        if (isUC) {
            if ([line containsString:@"(ESTABLISHED)"]) {
                *ucConnectionCount += 1;
                NSString *peerAddress = [self peerAddressFromLsofLine:line];
                if (peerAddress.length > 0) {
                    [peers addObject:peerAddress];
                }
            } else if ([line containsString:@"(SYN_SENT)"] || [line containsString:@"(SYN_RCVD)"]) {
                if (ucIncompleteCount != NULL) {
                    *ucIncompleteCount += 1;
                }
            }
            continue;
        }

        if (isRapport && [line containsString:@"(ESTABLISHED)"] && [line containsString:@"[fe80:"]) {
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
    NSInteger ucIncompleteCount = 0;
    NSArray<NSString *> *peerAddresses = @[];
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucIncompleteCount:&ucIncompleteCount ucPeerAddresses:&peerAddresses];
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

static NSString *const kUCPeersLastSeenDefaultsKey = @"UCPeersLastSeen";
static const NSTimeInterval kUCPeersTTLSeconds = 30.0 * 24.0 * 3600.0;
static const NSTimeInterval kUCPeersPersistDebounceSeconds = 60.0;

- (NSInteger)pruneExpiredUCPeersAtDate:(NSDate *)now {
    NSDate *cutoff = [now dateByAddingTimeInterval:-kUCPeersTTLSeconds];
    NSMutableArray<NSString *> *expired = [[NSMutableArray alloc] init];
    for (NSString *key in self.ucPeersLastSeen) {
        NSDate *when = self.ucPeersLastSeen[key];
        if (![when isKindOfClass:[NSDate class]] || [when compare:cutoff] == NSOrderedAscending) {
            [expired addObject:key];
        }
    }
    for (NSString *key in expired) {
        [self.ucPeersLastSeen removeObjectForKey:key];
        [self.ucPeersEverSeen removeObject:key];
    }
    return (NSInteger)expired.count;
}

- (void)loadUCPeersFromDefaults {
    self.ucPeersEverSeen = [[NSMutableSet alloc] init];
    self.ucPeersLastSeen = [[NSMutableDictionary alloc] init];
    self.ucPeersLastPersistedAt = nil;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id raw = [defaults objectForKey:kUCPeersLastSeenDefaultsKey];
    if (raw == nil) {
        return;
    }
    if (![raw isKindOfClass:[NSDictionary class]]) {
        [self appendLog:[NSString stringWithFormat:@"persistence_load_fail reason=type_mismatch class=%@", NSStringFromClass([raw class])]];
        [defaults removeObjectForKey:kUCPeersLastSeenDefaultsKey];
        return;
    }

    NSDictionary *dict = (NSDictionary *)raw;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kUCPeersTTLSeconds];
    NSInteger loaded = 0;
    NSInteger pruned = 0;
    for (id key in dict) {
        if (![key isKindOfClass:[NSString class]] || [(NSString *)key length] == 0) {
            continue;
        }
        id value = dict[key];
        NSDate *when = nil;
        if ([value isKindOfClass:[NSNumber class]]) {
            when = [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
        } else if ([value isKindOfClass:[NSDate class]]) {
            when = (NSDate *)value;
        }
        if (![when isKindOfClass:[NSDate class]]) {
            continue;
        }
        if ([when compare:cutoff] == NSOrderedAscending) {
            pruned += 1;
            continue;
        }
        [self.ucPeersEverSeen addObject:key];
        self.ucPeersLastSeen[key] = when;
        loaded += 1;
    }
    [self appendLog:[NSString stringWithFormat:@"persistence_load loaded=%ld pruned=%ld ttlDays=30", (long)loaded, (long)pruned]];
    if (pruned > 0) {
        [self saveUCPeersToDefaults];
        self.ucPeersLastPersistedAt = [NSDate date];
    }
}

- (void)saveUCPeersToDefaults {
    NSMutableDictionary<NSString *, NSNumber *> *plist = [[NSMutableDictionary alloc] init];
    for (NSString *key in self.ucPeersLastSeen) {
        NSDate *when = self.ucPeersLastSeen[key];
        if (![when isKindOfClass:[NSDate class]]) {
            continue;
        }
        plist[key] = @([when timeIntervalSince1970]);
    }
    [[NSUserDefaults standardUserDefaults] setObject:plist forKey:kUCPeersLastSeenDefaultsKey];
}

- (void)noteUCPeerSeen:(NSString *)canonicalAddress {
    if (canonicalAddress.length == 0) {
        return;
    }
    NSDate *now = [NSDate date];
    NSInteger pruned = [self pruneExpiredUCPeersAtDate:now];
    BOOL isNew = ![self.ucPeersEverSeen containsObject:canonicalAddress];
    [self.ucPeersEverSeen addObject:canonicalAddress];
    self.ucPeersLastSeen[canonicalAddress] = now;

    NSTimeInterval sinceLastWrite = self.ucPeersLastPersistedAt
        ? [now timeIntervalSinceDate:self.ucPeersLastPersistedAt]
        : DBL_MAX;
    if (isNew || pruned > 0 || sinceLastWrite > kUCPeersPersistDebounceSeconds) {
        [self saveUCPeersToDefaults];
        self.ucPeersLastPersistedAt = now;
        if (isNew) {
            [self appendLog:[NSString stringWithFormat:@"uc_peer_remembered address=%@ total=%lu", canonicalAddress, (unsigned long)self.ucPeersEverSeen.count]];
        }
        if (pruned > 0) {
            [self appendLog:[NSString stringWithFormat:@"uc_peer_prune removed=%ld ttlDays=30", (long)pruned]];
        }
    }
}

@end
