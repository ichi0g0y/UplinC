#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#include <netinet/in.h>
#include <sys/socket.h>

extern const int UplinCHeartbeatPort;

@interface UplinCApp : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate, NSNetServiceDelegate, NSNetServiceBrowserDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *statusMenuItem;
@property NSMenuItem *lastCheckMenuItem;
@property NSMenuItem *logStatusMenuItem;
@property NSMenuItem *tcpStatusMenuItem;
@property NSMenuItem *heartbeatStatusMenuItem;
@property NSMenuItem *versionMenuItem;
@property NSMenuItem *machinesMenuItem;
@property NSMenu *machinesSubmenu;
@property NSMenuItem *lastResetMenuItem;
@property NSMenuItem *logFileMenuItem;
@property NSMenuItem *autoHealMenuItem;
@property NSMenuItem *notificationsMenuItem;
@property NSMenuItem *syncResetMenuItem;
@property NSMenuItem *logWatchMenuItem;
@property NSMenuItem *tcpWatchMenuItem;
@property NSTimer *healthTimer;
@property NSTimer *heartbeatTimer;
@property NSTask *logTask;
@property BOOL autoHealEnabled;
@property BOOL notificationsEnabled;
@property BOOL syncResetEnabled;
@property BOOL logWatchEnabled;
@property BOOL tcpWatchEnabled;
@property BOOL heartbeatPeerHasBeenSeen;
@property BOOL tcpLinkHasBeenSeen;
@property BOOL resetInProgress;
@property NSString *instanceID;
@property NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *heartbeatPeers;
@property BOOL lastUniversalControlRunning;
@property BOOL hasLastUniversalControlRunning;
@property NSInteger lastLoggedUCConnectionCount;
@property NSInteger lastLoggedRapportLinkLocalCount;
@property NSInteger lastLoggedHeartbeatPeerCount;
@property NSString *lastLoggedPeerSummary;
@property NSInteger missedHeartbeatChecks;
@property NSMutableSet<NSString *> *ucPeersEverSeen;
@property NSMutableOrderedSet<NSString *> *recentRemoteResetNonces;
@property NSNetService *bonjourService;
@property NSNetServiceBrowser *bonjourBrowser;
@property NSMutableDictionary<NSString *, NSNetService *> *bonjourPeers;
@property NSMutableDictionary<NSString *, NSArray<NSData *> *> *bonjourPeerAddresses;
@property int heartbeatSocket;
@property NSDate *lastResetAttempt;
@property NSDate *lastFailureLogAt;
@property NSDate *lastHeartbeatReceivedAt;
@property NSInteger failureLogHits;
@property NSInteger missedTCPChecks;
@end

@interface UplinCApp (Internal)
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)configureMenu;
- (void)configureNotifications;
- (void)startHealthTimer;
- (void)startHeartbeatTimer;
- (void)heartbeatTick;
- (void)checkHealth;
- (void)startLogWatcher;
- (void)stopLogWatcher;
- (void)handleLog:(NSString *)text;
- (void)resetNow:(id)sender;
- (void)toggleAutoHeal:(id)sender;
- (void)toggleNotifications:(id)sender;
- (void)toggleSyncReset:(id)sender;
- (void)toggleLogWatch:(id)sender;
- (void)toggleTCPWatch:(id)sender;
- (void)openLogFile:(id)sender;
- (void)quit:(id)sender;
- (void)updateToggleStates;
- (BOOL)canAutoReset;
- (void)configureIdentity;
- (void)checkTCPLinkHealth;
- (void)checkHeartbeatHealth;
- (void)resetUniversalControl:(NSString *)reason force:(BOOL)force manual:(BOOL)manual broadcast:(BOOL)broadcast;
- (void)startHeartbeatSocket;
- (void)stopHeartbeatSocket;
- (void)startBonjour;
- (void)stopBonjour;
- (void)netServiceDidPublish:(NSNetService *)sender;
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict;
- (void)netServiceDidResolveAddress:(NSNetService *)sender;
- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict;
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing;
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing;
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict;
- (NSInteger)sendHeartbeatViaBonjour;
- (void)sendResetCommandViaBonjour:(NSString *)reason;
- (void)drainHeartbeatSocket;
- (NSString *)canonicalizedAddressFromSockaddr:(const struct sockaddr *)sa;
- (void)handleRemoteResetPayload:(NSString *)payload fromAddress:(NSString *)senderAddressString senderHost:(NSString *)senderHost;
- (NSDictionary<NSString *, NSString *> *)heartbeatFieldsFromPayload:(NSString *)payload;
- (NSArray<NSDictionary<NSString *, id> *> *)recentHeartbeatPeers;
- (NSArray<NSDictionary<NSString *, id> *> *)allKnownHeartbeatPeers;
- (NSString *)formatPeerAge:(NSTimeInterval)age;
- (void)updatePeerStatusWithUCPeerAddresses:(NSArray<NSString *> *)ucPeerAddresses;
- (void)rebuildMachinesSubmenu;
- (NSString *)compactAddress:(NSString *)address;
- (NSString *)sanitizedToken:(NSString *)value;
- (void)setStatusIcon:(NSString *)symbolName fallbackTitle:(NSString *)fallbackTitle description:(NSString *)description;
- (NSString *)formattedTime:(NSDate *)date;
- (NSString *)logPath;
- (void)appendLog:(NSString *)message;
- (void)ensureLogFileExists;
- (void)rotateLogIfNeeded;
- (NSString *)logTimestamp;
- (NSString *)sanitizedSingleLine:(NSString *)text maxLength:(NSUInteger)maxLength;
- (void)notifyResetComplete:(NSString *)reason manual:(BOOL)manual;
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler;
- (BOOL)isProcessRunning:(NSString *)name;
- (void)getTCPConnectionCount:(NSInteger *)ucConnectionCount rapportLinkLocalCount:(NSInteger *)rapportLinkLocalCount ucPeerAddresses:(NSArray<NSString *> **)ucPeerAddresses;
- (NSArray<NSString *> *)universalControlPeerAddresses;
- (NSString *)peerAddressFromLsofLine:(NSString *)line;
- (BOOL)parseIPv6Address:(NSString *)addressString into:(struct in6_addr *)outAddr scopeID:(uint32_t *)outScopeID;
- (NSString *)formatIPv6Address:(const struct in6_addr *)addr scopeID:(uint32_t)scopeID;
- (NSString *)canonicalIPv6String:(NSString *)addressString;
- (int)run:(NSString *)executable arguments:(NSArray<NSString *> *)arguments;
- (NSString *)outputFrom:(NSString *)executable arguments:(NSArray<NSString *> *)arguments;
@end
