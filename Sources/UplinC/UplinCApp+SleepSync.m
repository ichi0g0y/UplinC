#import "UplinCApp.h"
#include <errno.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>

#include <CoreServices/CoreServices.h>
#include <IOKit/IOKitLib.h>

#ifndef kAESleep
#define kAESleep ((AEEventID)'slep')
#endif

@implementation UplinCApp (SleepSync)

- (void)handleSystemWillSleep:(NSNotification *)note {
    (void)note;
    [self appendLog:@"system_sleep"];
    if ([[NSDate date] compare:self.suppressSleepBroadcastUntil] == NSOrderedAscending) {
        [self appendLog:@"sleep_broadcast_suppressed reason=window_active mode=system"];
        return;
    }
    [self sendSleepCommandViaBonjour:@"system"];
}

- (void)handleScreensDidSleep:(NSNotification *)note {
    (void)note;
    [self appendLog:@"displays_sleep"];
    if ([[NSDate date] compare:self.suppressDisplaysSleepBroadcastUntil] == NSOrderedAscending) {
        [self appendLog:@"sleep_broadcast_suppressed reason=window_active mode=displays"];
        return;
    }
    [self sendSleepCommandViaBonjour:@"displays"];
}

- (void)sendSleepCommandViaBonjour:(NSString *)mode {
    NSString *normalizedMode = ([mode isEqualToString:@"displays"]) ? @"displays" : @"system";
    BOOL gateEnabled = [normalizedMode isEqualToString:@"system"]
        ? self.sleepSyncEnabled
        : self.sleepDisplaysSyncEnabled;

    if (!gateEnabled) {
        [self appendLog:[NSString stringWithFormat:@"sleep_broadcast_skipped reason=disabled mode=%@", normalizedMode]];
        return;
    }
    if (self.heartbeatSocket < 0) {
        [self appendLog:[NSString stringWithFormat:@"sleep_broadcast_skipped reason=no_socket mode=%@", normalizedMode]];
        return;
    }
    if (self.bonjourPeerAddresses.count == 0) {
        [self appendLog:[NSString stringWithFormat:@"sleep_broadcast_skipped reason=no_bonjour_peers mode=%@", normalizedMode]];
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
            [destinations addObject:addrData];
        }
    }
    if (destinations.count == 0) {
        [self appendLog:[NSString stringWithFormat:@"sleep_broadcast_skipped reason=no_destinations mode=%@", normalizedMode]];
        return;
    }

    NSString *host = [self sanitizedToken:([[NSHost currentHost] localizedName] ?: [[NSHost currentHost] name] ?: @"unknown")];
    NSString *nonce = [[NSUUID UUID] UUIDString];
    NSString *payloadString = [NSString stringWithFormat:@"UPLINCSLP 1 id=%@ host=%@ mode=%@ nonce=%@ time=%.0f",
                                self.instanceID, host, normalizedMode, nonce, [[NSDate date] timeIntervalSince1970]];
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
                    [self appendLog:[NSString stringWithFormat:@"sleep_broadcast_send_failed nonce=%@ mode=%@ attempt=%lu errno=%d",
                                     nonce, normalizedMode, (unsigned long)(attempt + 1), errno]];
                }
            }
            [self appendLog:[NSString stringWithFormat:@"sleep_broadcast nonce=%@ mode=%@ peers=%lu attempt=%lu",
                             nonce, normalizedMode, (unsigned long)destinations.count, (unsigned long)(attempt + 1)]];
        });
    }
}

- (void)handleRemoteSleepPayload:(NSString *)payload fromAddress:(NSString *)senderAddressString senderHost:(NSString *)senderHost {
    NSDictionary<NSString *, NSString *> *fields = [self heartbeatFieldsFromPayload:payload];
    NSString *peerID = fields[@"id"];
    NSString *nonce = fields[@"nonce"];
    NSString *timestamp = fields[@"time"];
    NSString *mode = fields[@"mode"];
    if (peerID.length == 0 || nonce.length == 0 || timestamp.length == 0 || mode.length == 0) {
        [self appendLog:@"remote_sleep_rejected reason=invalid_payload"];
        return;
    }
    if (![mode isEqualToString:@"system"] && ![mode isEqualToString:@"displays"]) {
        [self appendLog:[NSString stringWithFormat:@"remote_sleep_rejected reason=unknown_mode mode=%@", mode]];
        return;
    }
    if ([peerID isEqualToString:self.instanceID]) {
        [self appendLog:@"remote_sleep_rejected reason=self"];
        return;
    }

    NSString *canonicalSender = [self canonicalIPv6String:senderAddressString];
    BOOL knownBonjourPeer = NO;
    if (canonicalSender.length > 0) {
        for (NSString *peerName in self.bonjourPeerAddresses) {
            NSArray<NSData *> *addrs = self.bonjourPeerAddresses[peerName];
            for (NSData *addrData in addrs) {
                if (addrData.length < sizeof(struct sockaddr_in6)) {
                    continue;
                }
                NSString *addr = [self canonicalizedAddressFromSockaddr:(const struct sockaddr *)addrData.bytes];
                NSString *canonical = [self canonicalIPv6String:addr];
                if (canonical.length > 0 && [canonical isEqualToString:canonicalSender]) {
                    knownBonjourPeer = YES;
                    break;
                }
            }
            if (knownBonjourPeer) {
                break;
            }
        }
    }
    if (!knownBonjourPeer) {
        [self appendLog:[NSString stringWithFormat:@"remote_sleep_rejected reason=untrusted_sender from=%@ mode=%@",
                         senderAddressString ?: @"unknown", mode]];
        return;
    }

    BOOL gateEnabled = [mode isEqualToString:@"system"]
        ? self.sleepSyncEnabled
        : self.sleepDisplaysSyncEnabled;
    if (!gateEnabled) {
        [self appendLog:[NSString stringWithFormat:@"remote_sleep_rejected reason=disabled mode=%@", mode]];
        return;
    }

    NSDate *now = [NSDate date];
    NSTimeInterval packetTime = [timestamp doubleValue];
    NSTimeInterval skew = [now timeIntervalSince1970] - packetTime;
    if (fabs(skew) > 30.0) {
        [self appendLog:[NSString stringWithFormat:@"remote_sleep_rejected reason=stale skew=%+.1f mode=%@", skew, mode]];
        return;
    }

    NSDate *cutoff = [now dateByAddingTimeInterval:-300.0];
    NSMutableArray<NSString *> *expired = [[NSMutableArray alloc] init];
    for (NSString *seen in self.recentRemoteSleepNonces) {
        NSDate *seenAt = self.recentRemoteSleepNonceAt[seen];
        if (![seenAt isKindOfClass:[NSDate class]] || [seenAt compare:cutoff] == NSOrderedAscending) {
            [expired addObject:seen];
        }
    }
    if (expired.count > 0) {
        for (NSString *seen in expired) {
            [self.recentRemoteSleepNonces removeObject:seen];
            [self.recentRemoteSleepNonceAt removeObjectForKey:seen];
        }
    }
    if ([self.recentRemoteSleepNonces containsObject:nonce]) {
        return;
    }

    [self.recentRemoteSleepNonces addObject:nonce];
    self.recentRemoteSleepNonceAt[nonce] = now;
    while (self.recentRemoteSleepNonces.count > 256) {
        NSString *oldest = self.recentRemoteSleepNonces[0];
        [self.recentRemoteSleepNonces removeObjectAtIndex:0];
        [self.recentRemoteSleepNonceAt removeObjectForKey:oldest];
    }

    NSString *peerHost = senderHost.length > 0 ? senderHost : senderAddressString;
    [self appendLog:[NSString stringWithFormat:@"remote_sleep_received from=%@ peer=%@ nonce=%@ mode=%@",
                     senderAddressString, peerHost, nonce, mode]];

    if ([mode isEqualToString:@"system"]) {
        [self performLocalSystemSleep];
    } else {
        [self performLocalDisplaysSleep];
    }
}

- (void)performLocalSystemSleep {
    self.suppressSleepBroadcastUntil = [NSDate dateWithTimeIntervalSinceNow:10.0];

    AEAddressDesc targetDesc;
    static const ProcessSerialNumber kPSNOfSystemProcess = { 0, kSystemProcess };
    AppleEvent eventReply = { typeNull, NULL };
    AppleEvent eventToSend = { typeNull, NULL };

    OSStatus err = AECreateDesc(typeProcessSerialNumber, &kPSNOfSystemProcess,
                                 sizeof(kPSNOfSystemProcess), &targetDesc);
    if (err != noErr) {
        [self appendLog:[NSString stringWithFormat:@"local_system_sleep_failed stage=create_desc err=%d", (int)err]];
        return;
    }

    err = AECreateAppleEvent(kCoreEventClass, kAESleep, &targetDesc,
                              kAutoGenerateReturnID, kAnyTransactionID, &eventToSend);
    AEDisposeDesc(&targetDesc);
    if (err != noErr) {
        [self appendLog:[NSString stringWithFormat:@"local_system_sleep_failed stage=create_event err=%d", (int)err]];
        return;
    }

    err = AESendMessage(&eventToSend, &eventReply, kAENormalPriority, kAEDefaultTimeout);
    AEDisposeDesc(&eventToSend);
    if (err == noErr) {
        AEDisposeDesc(&eventReply);
        [self appendLog:@"local_system_sleep_sent"];
    } else {
        [self appendLog:[NSString stringWithFormat:@"local_system_sleep_failed stage=send err=%d", (int)err]];
    }
}

- (void)performLocalDisplaysSleep {
    self.suppressDisplaysSleepBroadcastUntil = [NSDate dateWithTimeIntervalSinceNow:10.0];

    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault,
                                                         "IOService:/IOResources/IODisplayWrangler");
    if (entry == IO_OBJECT_NULL) {
        entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("IODisplayWrangler"));
    }
    if (entry == IO_OBJECT_NULL) {
        [self appendLog:@"local_displays_sleep_failed reason=no_wrangler"];
        return;
    }

    kern_return_t kr = IORegistryEntrySetCFProperty(entry, CFSTR("IORequestIdle"), kCFBooleanTrue);
    IOObjectRelease(entry);
    if (kr == KERN_SUCCESS) {
        [self appendLog:@"local_displays_sleep_sent"];
    } else {
        [self appendLog:[NSString stringWithFormat:@"local_displays_sleep_failed stage=set_property kr=0x%x", kr]];
    }
}

@end
