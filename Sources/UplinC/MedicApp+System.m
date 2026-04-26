#import "MedicApp.h"
#include <arpa/inet.h>
#include <net/if.h>
#include <string.h>

@implementation MedicApp (System)

- (BOOL)isProcessRunning:(NSString *)name {
    return [self run:@"/usr/bin/pgrep" arguments:@[@"-x", name]] == 0;
}
- (void)getTCPConnectionCount:(NSInteger *)ucConnectionCount rapportLinkLocalCount:(NSInteger *)rapportLinkLocalCount ucPeerAddresses:(NSArray<NSString *> **)ucPeerAddresses {
    *ucConnectionCount = 0;
    *rapportLinkLocalCount = 0;
    NSMutableOrderedSet<NSString *> *peers = [[NSMutableOrderedSet alloc] init];

    NSString *output = [self outputFrom:@"/usr/sbin/lsof" arguments:@[@"-nP", @"-iTCP", @"-sTCP:ESTABLISHED"]];
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        if (![line containsString:@"(ESTABLISHED)"]) {
            continue;
        }

        if ([line hasPrefix:@"Universal"]) {
            *ucConnectionCount += 1;
            NSString *peerAddress = [self peerAddressFromLsofLine:line];
            if (peerAddress.length > 0) {
                [peers addObject:peerAddress];
            }
        }

        if ([line hasPrefix:@"rapportd"] && [line containsString:@"[fe80:"]) {
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
    NSArray<NSString *> *peerAddresses = @[];
    [self getTCPConnectionCount:&ucConnectionCount rapportLinkLocalCount:&rapportLinkLocalCount ucPeerAddresses:&peerAddresses];
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

@end
