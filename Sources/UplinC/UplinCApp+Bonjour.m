#import "UplinCApp.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

@implementation UplinCApp (Bonjour)

- (void)startHeartbeatSocket {
    self.heartbeatSocket = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (self.heartbeatSocket < 0) {
        self.heartbeatStatusMenuItem.title = @"Heartbeat: socket failed";
        [self appendLog:[NSString stringWithFormat:@"heartbeat_socket failed errno=%d", errno]];
        return;
    }

    int yes = 1;
    setsockopt(self.heartbeatSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int no = 0;
    setsockopt(self.heartbeatSocket, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
    int flags = fcntl(self.heartbeatSocket, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(self.heartbeatSocket, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(UplinCHeartbeatPort);
    address.sin6_addr = in6addr_any;

    if (bind(self.heartbeatSocket, (struct sockaddr *)&address, sizeof(address)) < 0) {
        [self appendLog:[NSString stringWithFormat:@"heartbeat_bind failed port=%d errno=%d", UplinCHeartbeatPort, errno]];
        close(self.heartbeatSocket);
        self.heartbeatSocket = -1;
        self.heartbeatStatusMenuItem.title = @"Heartbeat: bind failed";
        return;
    }

    self.heartbeatStatusMenuItem.title = [NSString stringWithFormat:@"Heartbeat: UDP %d", UplinCHeartbeatPort];
    [self appendLog:[NSString stringWithFormat:@"heartbeat_socket started port=%d", UplinCHeartbeatPort]];
}

- (void)stopHeartbeatSocket {
    if (self.heartbeatSocket >= 0) {
        close(self.heartbeatSocket);
        self.heartbeatSocket = -1;
        [self appendLog:@"heartbeat_socket stopped"];
    }
}

- (void)startBonjour {
    if (self.instanceID.length == 0) {
        return;
    }

    self.bonjourService = [[NSNetService alloc] initWithDomain:@"local."
                                                          type:@"_uplinc._udp."
                                                          name:self.instanceID
                                                          port:UplinCHeartbeatPort];
    self.bonjourService.delegate = self;
    [self.bonjourService publish];

    self.bonjourBrowser = [[NSNetServiceBrowser alloc] init];
    self.bonjourBrowser.delegate = self;
    [self.bonjourBrowser searchForServicesOfType:@"_uplinc._udp." inDomain:@"local."];
    [self appendLog:[NSString stringWithFormat:@"bonjour_start name=%@", self.instanceID]];
}

- (void)stopBonjour {
    [self.bonjourService stop];
    [self.bonjourBrowser stop];
    self.bonjourService = nil;
    self.bonjourBrowser = nil;
    [self.bonjourPeers removeAllObjects];
    [self.bonjourPeerAddresses removeAllObjects];
    [self appendLog:@"bonjour_stop"];
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    [self appendLog:[NSString stringWithFormat:@"bonjour_published name=%@ port=%ld", sender.name, (long)sender.port]];
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    [self appendLog:[NSString stringWithFormat:@"bonjour_publish_failed name=%@ error=%@", sender.name, errorDict[NSNetServicesErrorCode]]];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSArray<NSData *> *addrs = sender.addresses ?: @[];
    NSMutableArray<NSData *> *kept = [[NSMutableArray alloc] init];
    for (NSData *data in addrs) {
        if (data.length < sizeof(struct sockaddr)) {
            continue;
        }
        const struct sockaddr *sa = (const struct sockaddr *)data.bytes;
        if (sa->sa_family != AF_INET6 && sa->sa_family != AF_INET) {
            continue;
        }
        [kept addObject:data];
    }
    self.bonjourPeerAddresses[sender.name] = kept;
    [self appendLog:[NSString stringWithFormat:@"bonjour_resolved name=%@ count=%lu", sender.name, (unsigned long)kept.count]];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    [self appendLog:[NSString stringWithFormat:@"bonjour_resolve_failed name=%@ error=%@", sender.name, errorDict[NSNetServicesErrorCode]]];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    (void)browser;
    (void)moreComing;
    if ([service.name isEqualToString:self.instanceID]) {
        return;
    }
    if (self.bonjourPeers[service.name] != nil) {
        return;
    }
    service.delegate = self;
    self.bonjourPeers[service.name] = service;
    [service resolveWithTimeout:10.0];
    [self appendLog:[NSString stringWithFormat:@"bonjour_found name=%@", service.name]];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
    (void)browser;
    (void)moreComing;
    [self.bonjourPeers removeObjectForKey:service.name];
    [self.bonjourPeerAddresses removeObjectForKey:service.name];
    [self appendLog:[NSString stringWithFormat:@"bonjour_removed name=%@", service.name]];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    (void)browser;
    [self appendLog:[NSString stringWithFormat:@"bonjour_browse_failed error=%@", errorDict[NSNetServicesErrorCode]]];
}

- (NSInteger)sendHeartbeatViaBonjour {
    if (self.heartbeatSocket < 0 || self.bonjourPeerAddresses.count == 0) {
        return 0;
    }

    NSString *host = [self sanitizedToken:([[NSHost currentHost] localizedName] ?: [[NSHost currentHost] name] ?: @"unknown")];
    NSString *payloadString = [NSString stringWithFormat:@"UPLINC 2 id=%@ host=%@ time=%.0f", self.instanceID, host, [[NSDate date] timeIntervalSince1970]];
    NSData *payloadData = [payloadString dataUsingEncoding:NSUTF8StringEncoding];

    NSInteger sentCount = 0;
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
            struct sockaddr_in6 dest;
            memset(&dest, 0, sizeof(dest));
            memcpy(&dest, addrData.bytes, MIN(addrData.length, sizeof(dest)));
            dest.sin6_port = htons(UplinCHeartbeatPort);
            ssize_t sent = sendto(self.heartbeatSocket, payloadData.bytes, payloadData.length, 0, (struct sockaddr *)&dest, sizeof(dest));
            if (sent < 0) {
                [self appendLog:[NSString stringWithFormat:@"heartbeat_bonjour_send failed peer=%@ errno=%d", peerName, errno]];
            } else {
                sentCount += 1;
            }
        }
    }
    return sentCount;
}

- (void)drainHeartbeatSocket {
    if (self.heartbeatSocket < 0) {
        return;
    }

    while (YES) {
        char buffer[512];
        struct sockaddr_in6 sender;
        socklen_t senderLength = sizeof(sender);
        ssize_t received = recvfrom(self.heartbeatSocket, buffer, sizeof(buffer) - 1, 0, (struct sockaddr *)&sender, &senderLength);
        if (received <= 0) {
            break;
        }

        buffer[received] = '\0';
        NSString *payload = [NSString stringWithUTF8String:buffer] ?: @"";
        NSString *senderAddressString = [self canonicalizedAddressFromSockaddr:(struct sockaddr *)&sender];
        if (senderAddressString.length == 0) {
            senderAddressString = @"unknown";
        }

        if ([payload hasPrefix:@"UPLINCRST "]) {
            NSDictionary<NSString *, NSString *> *resetFields = [self heartbeatFieldsFromPayload:payload];
            NSString *peerHost = resetFields[@"host"] ?: senderAddressString;
            [self handleRemoteResetPayload:payload fromAddress:senderAddressString senderHost:peerHost];
            continue;
        }
        if (![payload hasPrefix:@"UPLINC "]) {
            continue;
        }

        NSDictionary<NSString *, NSString *> *fields = [self heartbeatFieldsFromPayload:payload];
        NSString *peerID = fields[@"id"] ?: senderAddressString;
        NSString *peerHost = fields[@"host"] ?: senderAddressString;

        NSMutableDictionary<NSString *, id> *peer = self.heartbeatPeers[peerID];
        if (peer == nil) {
            peer = [[NSMutableDictionary alloc] init];
            self.heartbeatPeers[peerID] = peer;
        }
        peer[@"id"] = peerID;
        peer[@"host"] = peerHost;
        peer[@"address"] = senderAddressString;
        peer[@"lastSeen"] = [NSDate date];

        self.heartbeatPeerHasBeenSeen = YES;
        self.lastHeartbeatReceivedAt = [NSDate date];
        self.missedHeartbeatChecks = 0;
        [self appendLog:[NSString stringWithFormat:@"heartbeat_received from=%@ id=%@ host=%@ payload=\"%@\"", senderAddressString, peerID, peerHost, [self sanitizedSingleLine:payload maxLength:160]]];
    }
}

@end
