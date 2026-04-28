#import "UplinCApp.h"
#include <errno.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>

@implementation UplinCApp (SyncReset)

- (NSString *)canonicalizedAddressFromSockaddr:(const struct sockaddr *)sa {
    if (sa == NULL || sa->sa_family != AF_INET6) {
        return @"";
    }

    const struct sockaddr_in6 *sender = (const struct sockaddr_in6 *)sa;
    struct in6_addr canonicalAddr = sender->sin6_addr;
    uint32_t canonicalScope = sender->sin6_scope_id;
    if (IN6_IS_ADDR_LINKLOCAL(&canonicalAddr)) {
        uint16_t embedded = (uint16_t)((canonicalAddr.s6_addr[2] << 8) | canonicalAddr.s6_addr[3]);
        if (embedded != 0 && canonicalScope == 0) {
            canonicalScope = embedded;
        }
        canonicalAddr.s6_addr[2] = 0;
        canonicalAddr.s6_addr[3] = 0;
    }
    return [self formatIPv6Address:&canonicalAddr scopeID:canonicalScope];
}

- (void)sendResetCommandViaBonjour:(NSString *)reason {
    if (self.heartbeatSocket < 0) {
        [self appendLog:@"remote_reset_skipped reason=no_socket"];
        return;
    }
    if (!self.syncResetEnabled) {
        [self appendLog:@"remote_reset_skipped reason=disabled"];
        return;
    }
    if (self.bonjourPeerAddresses.count == 0) {
        [self appendLog:@"remote_reset_skipped reason=no_bonjour_peers"];
        return;
    }

    NSMutableArray<NSData *> *destinations = [[NSMutableArray alloc] init];
    for (NSString *peerName in [self.bonjourPeerAddresses.allKeys copy]) {
        NSArray<NSData *> *addrs = self.bonjourPeerAddresses[peerName];
        for (NSData *addrData in addrs) {
            if (addrData.length < sizeof(struct sockaddr_in6)) {
                continue;
            }
            const struct sockaddr *sa = (const struct sockaddr *)addrData.bytes;
            if (sa->sa_family != AF_INET6) {
                continue;
            }
            NSString *address = [self canonicalizedAddressFromSockaddr:sa];
            NSString *canonical = [self canonicalIPv6String:address];
            if (canonical.length == 0 || ![self.ucPeersEverSeen containsObject:canonical]) {
                continue;
            }
            [destinations addObject:addrData];
        }
    }

    if (destinations.count == 0) {
        [self appendLog:@"remote_reset_skipped reason=no_uc_peers"];
        return;
    }

    NSString *host = [self sanitizedToken:([[NSHost currentHost] localizedName] ?: [[NSHost currentHost] name] ?: @"unknown")];
    NSString *nonce = [[NSUUID UUID] UUIDString];
    NSString *safeReason = [self sanitizedToken:reason ?: @"unknown"];
    NSString *payloadString = [NSString stringWithFormat:@"UPLINCRST 1 id=%@ host=%@ nonce=%@ reason=%@ time=%.0f", self.instanceID, host, nonce, safeReason, [[NSDate date] timeIntervalSince1970]];
    NSData *payloadData = [payloadString dataUsingEncoding:NSUTF8StringEncoding];

    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt * 250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            for (NSData *addrData in destinations) {
                struct sockaddr_in6 dest;
                memset(&dest, 0, sizeof(dest));
                memcpy(&dest, addrData.bytes, MIN(addrData.length, sizeof(dest)));
                dest.sin6_port = htons(UplinCHeartbeatPort);
                ssize_t sent = sendto(self.heartbeatSocket, payloadData.bytes, payloadData.length, 0, (struct sockaddr *)&dest, sizeof(dest));
                if (sent < 0) {
                    [self appendLog:[NSString stringWithFormat:@"remote_reset_send_failed nonce=%@ attempt=%lu errno=%d", nonce, (unsigned long)(attempt + 1), errno]];
                }
            }
            [self appendLog:[NSString stringWithFormat:@"remote_reset_broadcast nonce=%@ peers=%lu attempt=%lu", nonce, (unsigned long)destinations.count, (unsigned long)(attempt + 1)]];
        });
    }
}

- (void)handleRemoteResetPayload:(NSString *)payload fromAddress:(NSString *)senderAddressString senderHost:(NSString *)senderHost {
    if (!self.syncResetEnabled) {
        [self appendLog:@"remote_reset_rejected reason=disabled"];
        return;
    }

    NSDictionary<NSString *, NSString *> *fields = [self heartbeatFieldsFromPayload:payload];
    NSString *peerID = fields[@"id"];
    NSString *nonce = fields[@"nonce"];
    NSString *timestamp = fields[@"time"];
    if (peerID.length == 0 || nonce.length == 0 || timestamp.length == 0) {
        [self appendLog:@"remote_reset_rejected reason=invalid_payload"];
        return;
    }
    if ([peerID isEqualToString:self.instanceID]) {
        [self appendLog:@"remote_reset_rejected reason=self"];
        return;
    }

    NSString *canonicalSender = [self canonicalIPv6String:senderAddressString];
    if (canonicalSender.length == 0 || ![self.ucPeersEverSeen containsObject:canonicalSender]) {
        [self appendLog:[NSString stringWithFormat:@"remote_reset_rejected reason=not_uc_peer from=%@", senderAddressString ?: @"unknown"]];
        return;
    }

    NSDate *now = [NSDate date];
    NSTimeInterval packetTime = [timestamp doubleValue];
    NSTimeInterval skew = [now timeIntervalSince1970] - packetTime;
    if (fabs(skew) > 30.0) {
        [self appendLog:[NSString stringWithFormat:@"remote_reset_rejected reason=stale skew=%+.1f", skew]];
        return;
    }
    if (![self.lastResetAttempt isEqualToDate:[NSDate distantPast]]) {
        NSTimeInterval since = [self.lastResetAttempt timeIntervalSince1970] - packetTime;
        if (since > 300.0) {
            [self appendLog:[NSString stringWithFormat:@"remote_reset_rejected reason=replay_floor since=%.1f", since]];
            return;
        }
    }

    NSDate *cutoff = [now dateByAddingTimeInterval:-300.0];
    NSMutableArray<NSString *> *expired = [[NSMutableArray alloc] init];
    for (NSString *seen in self.recentRemoteResetNonces) {
        NSDate *seenAt = self.recentRemoteResetNonceAt[seen];
        if (![seenAt isKindOfClass:[NSDate class]] || [seenAt compare:cutoff] == NSOrderedAscending) {
            [expired addObject:seen];
        }
    }
    if (expired.count > 0) {
        for (NSString *seen in expired) {
            [self.recentRemoteResetNonces removeObject:seen];
            [self.recentRemoteResetNonceAt removeObjectForKey:seen];
        }
        [self appendLog:[NSString stringWithFormat:@"remote_reset_dedup_prune removed=%lu retained=%lu", (unsigned long)expired.count, (unsigned long)self.recentRemoteResetNonces.count]];
    }

    if ([self.recentRemoteResetNonces containsObject:nonce]) {
        return;
    }
    if (self.resetInProgress) {
        [self appendLog:@"remote_reset_rejected reason=reset_in_progress"];
        return;
    }

    [self.recentRemoteResetNonces addObject:nonce];
    self.recentRemoteResetNonceAt[nonce] = now;
    while (self.recentRemoteResetNonces.count > 256) {
        NSString *oldest = self.recentRemoteResetNonces[0];
        [self.recentRemoteResetNonces removeObjectAtIndex:0];
        [self.recentRemoteResetNonceAt removeObjectForKey:oldest];
    }

    NSString *peerHost = senderHost.length > 0 ? senderHost : canonicalSender;
    NSString *remoteReason = fields[@"reason"] ?: @"unknown";
    [self appendLog:[NSString stringWithFormat:@"remote_reset_received from=%@ peer=%@ nonce=%@ reason=%@", canonicalSender, peerHost, nonce, remoteReason]];
    [self resetUniversalControl:[NSString stringWithFormat:@"Remote reset from %@", peerHost] force:YES weak:NO manual:NO broadcast:NO];
}

@end
