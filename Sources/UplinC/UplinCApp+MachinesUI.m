#import "UplinCApp.h"
#include <net/if.h>

static const NSTimeInterval kHeartbeatScopeFreshSecondsUI = 15.0;

@implementation UplinCApp (MachinesUI)

- (NSImage *)smallTemplateSymbolNamed:(NSString *)symbolName {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    if (image == nil) {
        return nil;
    }
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
    image = [image imageWithSymbolConfiguration:config] ?: image;
    image.template = YES;
    return image;
}

- (void)copyAddressFromMenuItem:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) {
        return;
    }
    NSString *address = ((NSMenuItem *)sender).representedObject;
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return;
    }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:address forType:NSPasteboardTypeString];
    [self appendLog:[NSString stringWithFormat:@"address_copied %@", address]];
}

- (NSArray<NSString *> *)interfaceNamesForScopeKeys:(NSArray<NSNumber *> *)scopeKeys {
    NSMutableArray<NSString *> *names = [[NSMutableArray alloc] init];
    for (NSNumber *scopeKey in scopeKeys) {
        char ifname[IF_NAMESIZE];
        if (if_indextoname(scopeKey.unsignedIntValue, ifname) != NULL) {
            [names addObject:[NSString stringWithUTF8String:ifname]];
        }
    }
    return names;
}

- (void)appendHeartbeatDetailRowsTo:(NSMenu *)details
                          heartbeat:(NSDictionary *)heartbeat
                           isOnline:(BOOL)isOnline
                                now:(NSDate *)now {
    NSDate *hbLastSeen = heartbeat[@"lastSeen"];
    NSTimeInterval hbAge = [hbLastSeen isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:hbLastSeen] : 0;
    NSString *hbAgeText = [self formatPeerAge:hbAge];

    NSDictionary<NSNumber *, NSDate *> *scopes = heartbeat[@"scopesLastSeen"];
    NSMutableArray<NSNumber *> *freshScopeKeys = [[NSMutableArray alloc] init];
    if ([scopes isKindOfClass:[NSDictionary class]]) {
        NSArray<NSNumber *> *scopeKeys = [scopes.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *scopeKey in scopeKeys) {
            NSDate *scopeLastSeen = scopes[scopeKey];
            if (![scopeLastSeen isKindOfClass:[NSDate class]]) {
                continue;
            }
            if (isOnline && [now timeIntervalSinceDate:scopeLastSeen] > kHeartbeatScopeFreshSecondsUI) {
                continue;
            }
            [freshScopeKeys addObject:scopeKey];
        }
    }
    NSArray<NSString *> *names = [self interfaceNamesForScopeKeys:freshScopeKeys];
    NSString *line = names.count > 0
        ? [NSString stringWithFormat:@"Heartbeat: %@ — %@", [names componentsJoinedByString:@", "], hbAgeText]
        : [NSString stringWithFormat:@"Heartbeat: %@", hbAgeText];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line action:nil keyEquivalent:@""];
    item.image = [self smallTemplateSymbolNamed:@"waveform.path.ecg"];
    [details addItem:item];
}

- (void)appendUCDetailRowTo:(NSMenu *)details
                          uc:(NSDictionary *)uc
                         now:(NSDate *)now {
    NSDate *ucLastSeen = uc[@"lastSeen"];
    NSTimeInterval ucAge = [ucLastSeen isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:ucLastSeen] : 0;
    NSString *ucAgeText = [self formatPeerAge:ucAge];

    NSSet<NSNumber *> *scopes = uc[@"scopes"];
    NSArray<NSString *> *names = @[];
    if ([scopes isKindOfClass:[NSSet class]]) {
        NSArray<NSNumber *> *scopeKeys = [scopes.allObjects sortedArrayUsingSelector:@selector(compare:)];
        names = [self interfaceNamesForScopeKeys:scopeKeys];
    }
    NSString *line = names.count > 0
        ? [NSString stringWithFormat:@"Universal Control: %@ — %@", [names componentsJoinedByString:@", "], ucAgeText]
        : [NSString stringWithFormat:@"Universal Control: %@", ucAgeText];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line action:nil keyEquivalent:@""];
    item.image = [self smallTemplateSymbolNamed:@"display.2"];
    [details addItem:item];
}

- (void)appendAddressRowsTo:(NSMenu *)details addresses:(NSArray<NSString *> *)sortedAddresses {
    if (sortedAddresses.count == 0) {
        return;
    }
    [details addItem:[NSMenuItem separatorItem]];
    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"Addresses" action:nil keyEquivalent:@""];
    [details addItem:header];
    for (NSString *address in sortedAddresses) {
        NSMenuItem *addrItem = [[NSMenuItem alloc] initWithTitle:address
                                                          action:@selector(copyAddressFromMenuItem:)
                                                   keyEquivalent:@""];
        addrItem.target = self;
        addrItem.representedObject = address;
        addrItem.toolTip = @"Click to copy";
        addrItem.image = [self smallTemplateSymbolNamed:@"doc.on.clipboard"];
        [details addItem:addrItem];
    }
}

- (void)rebuildMachinesSubmenu {
    NSArray<NSDictionary<NSString *, id> *> *machines = [self allKnownMachines];
    [self.machinesSubmenu removeAllItems];

    if (machines.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No peers" action:nil keyEquivalent:@""];
        [self.machinesSubmenu addItem:empty];
        self.machinesMenuItem.title = @"Machines";
        self.machinesMenuItem.image = nil;
        return;
    }

    NSDate *now = [NSDate date];
    NSInteger onlineCount = 0;

    for (NSDictionary<NSString *, id> *machine in machines) {
        BOOL isOnline = [machine[@"online"] boolValue];
        if (isOnline) {
            onlineCount += 1;
        }
        NSDictionary *heartbeat = machine[@"heartbeat"];
        NSDictionary *uc = machine[@"uc"];
        BOOL hasHB = [heartbeat isKindOfClass:[NSDictionary class]];
        BOOL hasUC = [uc isKindOfClass:[NSDictionary class]];

        NSString *host = machine[@"host"];
        if (![host isKindOfClass:[NSString class]] || host.length == 0) {
            host = @"unknown";
        }

        NSDate *lastSeen = machine[@"lastSeen"];
        NSTimeInterval age = [lastSeen isKindOfClass:[NSDate class]] ? [now timeIntervalSinceDate:lastSeen] : 0;
        NSString *ageText = [self formatPeerAge:age];

        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:host action:nil keyEquivalent:@""];
        parent.image = [self machineIndicatorImageWithHeartbeat:hasHB
                                              universalControl:hasUC
                                                        online:isOnline];

        NSSet<NSString *> *addressSet = machine[@"addresses"];
        NSArray<NSString *> *sortedAddresses = nil;
        if ([addressSet isKindOfClass:[NSSet class]] && addressSet.count > 0) {
            sortedAddresses = [addressSet.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        }

        NSMenu *details = [[NSMenu alloc] initWithTitle:host];
        details.autoenablesItems = NO;

        NSString *statusLine = isOnline
            ? [NSString stringWithFormat:@"Status: Online — %@", ageText]
            : [NSString stringWithFormat:@"Status: Offline — last seen %@", ageText];
        NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusLine action:nil keyEquivalent:@""];
        statusItem.image = [self smallTemplateSymbolNamed:isOnline ? @"circle.fill" : @"circle"];
        [details addItem:statusItem];

        if (hasHB) {
            [self appendHeartbeatDetailRowsTo:details heartbeat:heartbeat isOnline:isOnline now:now];
        }
        if (hasUC) {
            [self appendUCDetailRowTo:details uc:uc now:now];
        }
        [self appendAddressRowsTo:details addresses:sortedAddresses];

        parent.submenu = details;
        [self.machinesSubmenu addItem:parent];
    }

    self.machinesMenuItem.title = [NSString stringWithFormat:@"Machines: %lu (%ld online)", (unsigned long)machines.count, (long)onlineCount];
}

@end
