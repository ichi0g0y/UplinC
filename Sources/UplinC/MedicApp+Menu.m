#import "MedicApp.h"

@implementation MedicApp (Menu)

- (void)configureMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"UplinC";
    [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];

    NSMenu *menu = [[NSMenu alloc] init];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    self.lastCheckMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last check: never" action:nil keyEquivalent:@""];
    self.lastCheckMenuItem.enabled = NO;
    self.logStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Log watch: starting" action:nil keyEquivalent:@""];
    self.logStatusMenuItem.enabled = NO;
    self.tcpStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"TCP link: not seen yet" action:nil keyEquivalent:@""];
    self.tcpStatusMenuItem.enabled = NO;
    self.heartbeatStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Heartbeat: starting" action:nil keyEquivalent:@""];
    self.heartbeatStatusMenuItem.enabled = NO;
    NSString *bundleVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *versionTitle = bundleVersion.length > 0 ? [NSString stringWithFormat:@"UplinC v%@", bundleVersion] : @"UplinC";
    self.versionMenuItem = [[NSMenuItem alloc] initWithTitle:versionTitle action:nil keyEquivalent:@""];
    self.versionMenuItem.enabled = NO;
    self.machinesSubmenu = [[NSMenu alloc] initWithTitle:@"Machines"];
    self.machinesSubmenu.autoenablesItems = NO;
    self.machinesMenuItem = [[NSMenuItem alloc] initWithTitle:@"Machines" action:nil keyEquivalent:@""];
    self.machinesMenuItem.submenu = self.machinesSubmenu;
    self.lastResetMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last reset: never" action:nil keyEquivalent:@""];
    self.lastResetMenuItem.enabled = NO;
    self.logFileMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open Log File" action:@selector(openLogFile:) keyEquivalent:@""];
    self.logFileMenuItem.target = self;

    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Universal Control" action:@selector(resetNow:) keyEquivalent:@"r"];
    resetItem.target = self;

    self.autoHealMenuItem = [[NSMenuItem alloc] initWithTitle:@"Auto Heal" action:@selector(toggleAutoHeal:) keyEquivalent:@""];
    self.autoHealMenuItem.target = self;
    self.parentModeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Mode: Auto" action:nil keyEquivalent:@""];
    NSMenu *modeSubmenu = [[NSMenu alloc] initWithTitle:@"Mode"];
    self.modeAutoMenuItem = [[NSMenuItem alloc] initWithTitle:@"Auto" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeAutoMenuItem.target = self;
    self.modeAutoMenuItem.representedObject = @"auto";
    self.modeParentMenuItem = [[NSMenuItem alloc] initWithTitle:@"Parent" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeParentMenuItem.target = self;
    self.modeParentMenuItem.representedObject = @"parent";
    self.modeChildMenuItem = [[NSMenuItem alloc] initWithTitle:@"Child" action:@selector(selectMode:) keyEquivalent:@""];
    self.modeChildMenuItem.target = self;
    self.modeChildMenuItem.representedObject = @"child";
    [modeSubmenu addItem:self.modeAutoMenuItem];
    [modeSubmenu addItem:self.modeParentMenuItem];
    [modeSubmenu addItem:self.modeChildMenuItem];
    self.parentModeMenuItem.submenu = modeSubmenu;
    self.logWatchMenuItem = [[NSMenuItem alloc] initWithTitle:@"Watch UC Logs" action:@selector(toggleLogWatch:) keyEquivalent:@""];
    self.logWatchMenuItem.target = self;
    self.tcpWatchMenuItem = [[NSMenuItem alloc] initWithTitle:@"Watch TCP Link" action:@selector(toggleTCPWatch:) keyEquivalent:@""];
    self.tcpWatchMenuItem.target = self;

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;

    [menu addItem:self.versionMenuItem];
    [menu addItem:self.statusMenuItem];
    [menu addItem:self.lastCheckMenuItem];
    [menu addItem:self.logStatusMenuItem];
    [menu addItem:self.tcpStatusMenuItem];
    [menu addItem:self.heartbeatStatusMenuItem];
    [menu addItem:self.lastResetMenuItem];
    [menu addItem:self.machinesMenuItem];
    [menu addItem:self.logFileMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:resetItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.parentModeMenuItem];
    [menu addItem:self.autoHealMenuItem];
    [menu addItem:self.logWatchMenuItem];
    [menu addItem:self.tcpWatchMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
    [self rebuildMachinesSubmenu];
    [self updateToggleStates];
}

- (void)resetNow:(id)sender {
    (void)sender;
    [self appendMedicLog:@"manual_reset requested"];
    [self resetUniversalControl:@"Manual reset" force:YES];
}

- (void)toggleAutoHeal:(id)sender {
    (void)sender;
    self.autoHealEnabled = !self.autoHealEnabled;
    [self updateToggleStates];
    [self appendMedicLog:[NSString stringWithFormat:@"setting autoHeal=%@", self.autoHealEnabled ? @"on" : @"off"]];
}

- (void)selectMode:(id)sender {
    NSString *requested = nil;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        id represented = [(NSMenuItem *)sender representedObject];
        if ([represented isKindOfClass:[NSString class]]) {
            requested = represented;
        }
    }
    if (![@[@"auto", @"parent", @"child"] containsObject:requested]) {
        return;
    }
    if ([requested isEqualToString:self.modePreference]) {
        return;
    }
    self.modePreference = requested;
    [[NSUserDefaults standardUserDefaults] setObject:self.modePreference forKey:@"ModePreference"];
    [self updateEffectiveParentRole];
    [self updateToggleStates];
    [self sendHeartbeatViaBonjour];
    [self appendMedicLog:[NSString stringWithFormat:@"setting modePreference=%@ effectiveRole=%@", self.modePreference, [self effectiveRoleLabel]]];
}

- (void)toggleLogWatch:(id)sender {
    (void)sender;
    self.logWatchEnabled = !self.logWatchEnabled;
    [self updateToggleStates];
    self.logWatchEnabled ? [self startLogWatcher] : [self stopLogWatcher];
    [self appendMedicLog:[NSString stringWithFormat:@"setting logWatch=%@", self.logWatchEnabled ? @"on" : @"off"]];
}

- (void)toggleTCPWatch:(id)sender {
    (void)sender;
    self.tcpWatchEnabled = !self.tcpWatchEnabled;
    [self updateToggleStates];
    self.tcpStatusMenuItem.title = self.tcpWatchEnabled ? @"TCP link: not seen yet" : @"TCP link: stopped";
    [self appendMedicLog:[NSString stringWithFormat:@"setting tcpWatch=%@", self.tcpWatchEnabled ? @"on" : @"off"]];
}

- (void)openLogFile:(id)sender {
    (void)sender;
    [self ensureMedicLogFileExists];
    int status = [self run:@"/usr/bin/open" arguments:@[[self medicLogPath]]];
    [self appendMedicLog:[NSString stringWithFormat:@"log_file opened status=%d", status]];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)updateToggleStates {
    self.autoHealMenuItem.state = self.autoHealEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.parentModeMenuItem.title = [NSString stringWithFormat:@"Mode: %@ (%@)", [self modePreferenceLabel], [self effectiveRoleLabel]];
    self.modeAutoMenuItem.state = [self.modePreference isEqualToString:@"auto"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.modeParentMenuItem.state = [self.modePreference isEqualToString:@"parent"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.modeChildMenuItem.state = [self.modePreference isEqualToString:@"child"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.logWatchMenuItem.state = self.logWatchEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.tcpWatchMenuItem.state = self.tcpWatchEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

@end
