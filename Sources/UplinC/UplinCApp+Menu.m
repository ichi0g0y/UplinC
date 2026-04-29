#import "UplinCApp.h"
#import "UplinCToggleMenuItemView.h"
#import <ServiceManagement/ServiceManagement.h>

static NSMenuItem *uc_makeToggleItem(NSString *title, id target, SEL action) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    UplinCToggleMenuItemView *view = [[UplinCToggleMenuItemView alloc] initWithTitle:title
                                                                              target:target
                                                                              action:action];
    item.view = view;
    return item;
}

static inline void uc_setToggle(NSMenuItem *item, BOOL on) {
    item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ([item.view isKindOfClass:[UplinCToggleMenuItemView class]]) {
        [(UplinCToggleMenuItemView *)item.view setOn:on];
    }
}

@implementation UplinCApp (Menu)

- (void)configureMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"UplinC";
    [self setStatusIcon:@"link" fallbackTitle:@"UC" description:@"Universal Control OK"];

    NSMenu *menu = [[NSMenu alloc] init];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    self.lastCheckMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last check: never" action:nil keyEquivalent:@""];
    self.logStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Log watch: starting" action:nil keyEquivalent:@""];
    self.tcpStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"TCP link: not seen yet" action:nil keyEquivalent:@""];
    self.heartbeatStatusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Heartbeat: starting" action:nil keyEquivalent:@""];
    NSString *bundleVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *versionTitle = bundleVersion.length > 0 ? [NSString stringWithFormat:@"UplinC v%@", bundleVersion] : @"UplinC";
    self.versionMenuItem = [[NSMenuItem alloc] initWithTitle:versionTitle action:nil keyEquivalent:@""];
    self.machinesSubmenu = [[NSMenu alloc] initWithTitle:@"Machines"];
    self.machinesSubmenu.autoenablesItems = NO;
    self.machinesMenuItem = [[NSMenuItem alloc] initWithTitle:@"Machines" action:nil keyEquivalent:@""];
    self.machinesMenuItem.submenu = self.machinesSubmenu;
    self.lastResetMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last reset: never" action:nil keyEquivalent:@""];

    self.statusSubmenu = [[NSMenu alloc] initWithTitle:@"Status"];
    self.statusSubmenu.autoenablesItems = NO;
    [self.statusSubmenu addItem:self.statusMenuItem];
    [self.statusSubmenu addItem:self.lastCheckMenuItem];
    [self.statusSubmenu addItem:self.logStatusMenuItem];
    [self.statusSubmenu addItem:self.tcpStatusMenuItem];
    [self.statusSubmenu addItem:self.heartbeatStatusMenuItem];
    [self.statusSubmenu addItem:self.lastResetMenuItem];
    self.statusSubmenuItem = [[NSMenuItem alloc] initWithTitle:@"Status" action:nil keyEquivalent:@""];
    self.statusSubmenuItem.submenu = self.statusSubmenu;
    self.diagnosticSubmenu = [[NSMenu alloc] initWithTitle:@"Diagnostic"];
    self.diagnosticSubmenu.autoenablesItems = NO;
    self.diagPgrepItem = [[NSMenuItem alloc] initWithTitle:@"pgrep UC: -" action:nil keyEquivalent:@""];
    self.diagPgrepItem.enabled = NO;
    self.diagTCPItem = [[NSMenuItem alloc] initWithTitle:@"TCP UC: -" action:nil keyEquivalent:@""];
    self.diagTCPItem.enabled = NO;
    self.diagHeartbeatItem = [[NSMenuItem alloc] initWithTitle:@"HB peers: -" action:nil keyEquivalent:@""];
    self.diagHeartbeatItem.enabled = NO;
    self.diagFailureScoreItem = [[NSMenuItem alloc] initWithTitle:@"Failure score: 0.0/4.0 (window 120s)" action:nil keyEquivalent:@""];
    self.diagFailureScoreItem.enabled = NO;
    self.diagRecentLineItem = [[NSMenuItem alloc] initWithTitle:@"Last: none" action:nil keyEquivalent:@""];
    self.diagRecentLineItem.enabled = NO;
    [self.diagnosticSubmenu addItem:self.diagPgrepItem];
    [self.diagnosticSubmenu addItem:self.diagTCPItem];
    [self.diagnosticSubmenu addItem:self.diagHeartbeatItem];
    [self.diagnosticSubmenu addItem:[NSMenuItem separatorItem]];
    [self.diagnosticSubmenu addItem:self.diagFailureScoreItem];
    [self.diagnosticSubmenu addItem:self.diagRecentLineItem];
    self.diagnosticMenuItem = [[NSMenuItem alloc] initWithTitle:@"Diagnostic" action:nil keyEquivalent:@""];
    self.diagnosticMenuItem.submenu = self.diagnosticSubmenu;
    self.logFileMenuItem = [[NSMenuItem alloc] initWithTitle:@"Open Log File" action:@selector(openLogFile:) keyEquivalent:@""];
    self.logFileMenuItem.target = self;
    self.aboutMenuItem = [[NSMenuItem alloc] initWithTitle:@"About UplinC..." action:@selector(showAboutDialog:) keyEquivalent:@""];
    self.aboutMenuItem.target = self;

    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Universal Control" action:@selector(resetNow:) keyEquivalent:@"r"];
    resetItem.target = self;

    self.autoHealMenuItem          = uc_makeToggleItem(@"Auto Heal",           self, @selector(toggleAutoHeal:));
    self.notificationsMenuItem     = uc_makeToggleItem(@"Notifications",       self, @selector(toggleNotifications:));
    self.syncResetMenuItem         = uc_makeToggleItem(@"Sync Reset",          self, @selector(toggleSyncReset:));
    self.sleepSyncMenuItem         = uc_makeToggleItem(@"Sync Sleep",          self, @selector(toggleSleepSync:));
    self.sleepDisplaysSyncMenuItem = uc_makeToggleItem(@"Sync Sleep Displays", self, @selector(toggleSleepDisplaysSync:));
    self.logWatchMenuItem          = uc_makeToggleItem(@"Watch UC Logs",       self, @selector(toggleLogWatch:));
    self.tcpWatchMenuItem          = uc_makeToggleItem(@"Watch TCP Link",      self, @selector(toggleTCPWatch:));
    self.launchAtLoginMenuItem     = uc_makeToggleItem(@"Launch at Login",     self, @selector(toggleLaunchAtLogin:));

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;

    [menu addItem:self.machinesMenuItem];
    [menu addItem:self.diagnosticMenuItem];
    [menu addItem:self.statusSubmenuItem];
    [menu addItem:self.logFileMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:resetItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.autoHealMenuItem];
    [menu addItem:self.notificationsMenuItem];
    [menu addItem:self.syncResetMenuItem];
    [menu addItem:self.sleepSyncMenuItem];
    [menu addItem:self.sleepDisplaysSyncMenuItem];
    [menu addItem:self.logWatchMenuItem];
    [menu addItem:self.tcpWatchMenuItem];
    [menu addItem:self.launchAtLoginMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.versionMenuItem];
    [menu addItem:self.aboutMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:quitItem];
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self recordDiagnosticTick];
    [self rebuildDiagnosticSubmenu];
    [self rebuildMachinesSubmenu];
    [self updateToggleStates];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.statusItem.menu) {
        return;
    }
    [self rebuildDiagnosticSubmenu];
    [self rebuildMachinesSubmenu];
}

- (void)resetNow:(id)sender {
    (void)sender;
    [self appendLog:@"manual_reset requested"];
    [self resetUniversalControl:@"Manual reset" force:YES weak:NO manual:YES broadcast:YES];
}

- (void)toggleAutoHeal:(id)sender {
    (void)sender;
    self.autoHealEnabled = !self.autoHealEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.autoHealEnabled forKey:@"AutoHealEnabled"];
    [self updateToggleStates];
    [self appendLog:[NSString stringWithFormat:@"setting autoHeal=%@", self.autoHealEnabled ? @"on" : @"off"]];
}

- (void)toggleNotifications:(id)sender {
    (void)sender;
    self.notificationsEnabled = !self.notificationsEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.notificationsEnabled forKey:@"NotificationsEnabled"];
    [self updateToggleStates];
    [self appendLog:[NSString stringWithFormat:@"setting notifications=%@", self.notificationsEnabled ? @"on" : @"off"]];
}

- (void)toggleSyncReset:(id)sender {
    (void)sender;
    self.syncResetEnabled = !self.syncResetEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.syncResetEnabled forKey:@"SyncResetEnabled"];
    [self updateToggleStates];
    [self appendLog:[NSString stringWithFormat:@"setting syncReset=%@", self.syncResetEnabled ? @"on" : @"off"]];
}

- (void)toggleSleepSync:(id)sender {
    (void)sender;
    self.sleepSyncEnabled = !self.sleepSyncEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.sleepSyncEnabled forKey:@"SleepSyncEnabled"];
    [self updateToggleStates];
    [self appendLog:[NSString stringWithFormat:@"setting sleepSync=%@", self.sleepSyncEnabled ? @"on" : @"off"]];
}

- (void)toggleSleepDisplaysSync:(id)sender {
    (void)sender;
    self.sleepDisplaysSyncEnabled = !self.sleepDisplaysSyncEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.sleepDisplaysSyncEnabled forKey:@"SleepDisplaysSyncEnabled"];
    [self updateToggleStates];
    [self appendLog:[NSString stringWithFormat:@"setting sleepDisplaysSync=%@", self.sleepDisplaysSyncEnabled ? @"on" : @"off"]];
}

- (void)toggleLogWatch:(id)sender {
    (void)sender;
    self.logWatchEnabled = !self.logWatchEnabled;
    [self updateToggleStates];
    self.logWatchEnabled ? [self startLogWatcher] : [self stopLogWatcher];
    [self appendLog:[NSString stringWithFormat:@"setting logWatch=%@", self.logWatchEnabled ? @"on" : @"off"]];
}

- (void)toggleTCPWatch:(id)sender {
    (void)sender;
    self.tcpWatchEnabled = !self.tcpWatchEnabled;
    [self updateToggleStates];
    self.tcpStatusMenuItem.title = self.tcpWatchEnabled ? @"TCP link: not seen yet" : @"TCP link: stopped";
    [self appendLog:[NSString stringWithFormat:@"setting tcpWatch=%@", self.tcpWatchEnabled ? @"on" : @"off"]];
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    BOOL wasEnabled = (service.status == SMAppServiceStatusEnabled);
    NSError *error = nil;
    BOOL ok = wasEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    BOOL nowEnabled = (service.status == SMAppServiceStatusEnabled);
    if (!ok || error) {
        [self appendLog:[NSString stringWithFormat:@"launchAtLogin %@ failed: %@",
            wasEnabled ? @"unregister" : @"register",
            error.localizedDescription ?: @"unknown error"]];
    } else {
        [self appendLog:[NSString stringWithFormat:@"setting launchAtLogin=%@", nowEnabled ? @"on" : @"off"]];
    }
    [self updateToggleStates];
}

- (void)openLogFile:(id)sender {
    (void)sender;
    [self ensureLogFileExists];
    int status = [self run:@"/usr/bin/open" arguments:@[[self logPath]]];
    [self appendLog:[NSString stringWithFormat:@"log_file opened status=%d", status]];
}

- (void)showAboutDialog:(id)sender {
    (void)sender;
    NSString *bundleVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *projectURLString = @"https://github.com/ichi0g0y/UplinC";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"UplinC v%@", bundleVersion];
    alert.informativeText = @"Universal Control monitor and recovery utility for macOS.\n\nWatches Universal Control health, exchanges UDP heartbeats with paired Macs, and triggers a coordinated reset when a session goes stale.";

    NSImage *appIcon = [NSApp applicationIconImage];
    if (appIcon != nil) {
        alert.icon = appIcon;
    }

    NSTextField *linkField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 22)];
    linkField.editable = NO;
    linkField.bordered = NO;
    linkField.drawsBackground = NO;
    linkField.selectable = YES;
    linkField.allowsEditingTextAttributes = YES;
    NSMutableAttributedString *attrs = [[NSMutableAttributedString alloc] initWithString:projectURLString];
    NSURL *url = [NSURL URLWithString:projectURLString];
    NSRange range = NSMakeRange(0, attrs.length);
    if (url != nil) {
        [attrs addAttribute:NSLinkAttributeName value:url range:range];
    }
    [attrs addAttribute:NSForegroundColorAttributeName value:[NSColor linkColor] range:range];
    [attrs addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    [attrs addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:[NSFont systemFontSize]] range:range];
    linkField.attributedStringValue = attrs;
    alert.accessoryView = linkField;

    [alert addButtonWithTitle:@"Open Project Page"];
    [alert addButtonWithTitle:@"Close"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn && url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        [self appendLog:[NSString stringWithFormat:@"about_open_url url=%@", projectURLString]];
    }
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)updateToggleStates {
    uc_setToggle(self.autoHealMenuItem,          self.autoHealEnabled);
    uc_setToggle(self.notificationsMenuItem,     self.notificationsEnabled);
    uc_setToggle(self.syncResetMenuItem,         self.syncResetEnabled);
    uc_setToggle(self.sleepSyncMenuItem,         self.sleepSyncEnabled);
    uc_setToggle(self.sleepDisplaysSyncMenuItem, self.sleepDisplaysSyncEnabled);
    uc_setToggle(self.logWatchMenuItem,          self.logWatchEnabled);
    uc_setToggle(self.tcpWatchMenuItem,          self.tcpWatchEnabled);
    uc_setToggle(self.launchAtLoginMenuItem,
                 SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
}

@end
