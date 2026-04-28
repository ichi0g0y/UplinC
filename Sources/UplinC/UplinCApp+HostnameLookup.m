#import "UplinCApp.h"
#include <netdb.h>
#include <string.h>
#include <sys/socket.h>

static const NSTimeInterval kHostnameLookupCooldownSeconds = 300.0;

@implementation UplinCApp (HostnameLookup)

- (NSString *)cleanResolvedHostname:(NSString *)raw {
    if (raw.length == 0) {
        return nil;
    }
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasSuffix:@".local."]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 7];
    } else if ([trimmed hasSuffix:@".local"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 6];
    } else if ([trimmed hasSuffix:@"."]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    return trimmed.length > 0 ? trimmed : nil;
}

- (void)resolveHostnameForAddressIfNeeded:(NSString *)address {
    if (address.length == 0) {
        return;
    }
    if (self.resolvedHostnamesByAddress[address] != nil) {
        return;
    }
    NSDate *lastAttempt = self.hostnameLookupAttemptedAt[address];
    if (lastAttempt != nil && [[NSDate date] timeIntervalSinceDate:lastAttempt] < kHostnameLookupCooldownSeconds) {
        return;
    }
    self.hostnameLookupAttemptedAt[address] = [NSDate date];

    NSString *captured = [address copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        struct in6_addr addr;
        uint32_t scope = 0;
        if (![strongSelf parseIPv6Address:captured into:&addr scopeID:&scope]) {
            return;
        }
        struct sockaddr_in6 sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin6_len = sizeof(sa);
        sa.sin6_family = AF_INET6;
        sa.sin6_addr = addr;
        sa.sin6_scope_id = scope;

        char hostname[NI_MAXHOST] = {0};
        int rc = getnameinfo((struct sockaddr *)&sa, sizeof(sa), hostname, sizeof(hostname), NULL, 0, NI_NAMEREQD);
        NSString *resolved = nil;
        if (rc == 0) {
            NSString *raw = [NSString stringWithUTF8String:hostname] ?: @"";
            resolved = [strongSelf cleanResolvedHostname:raw];
        }
        if (resolved.length == 0) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) mainSelf = weakSelf;
            if (mainSelf == nil) {
                return;
            }
            mainSelf.resolvedHostnamesByAddress[captured] = resolved;
            [mainSelf appendLog:[NSString stringWithFormat:@"hostname_resolved address=%@ host=%@", captured, resolved]];
        });
    });
}

@end
