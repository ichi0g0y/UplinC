#import "MedicApp.h"

@implementation MedicApp (Utilities)

- (NSString *)compactAddress:(NSString *)address {
    if (address.length <= 18) {
        return address;
    }
    return [NSString stringWithFormat:@"...%@", [address substringFromIndex:address.length - 14]];
}
- (NSString *)sanitizedToken:(NSString *)value {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"._-"];
    NSMutableString *result = [[NSMutableString alloc] init];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
        } else {
            [result appendString:@"_"];
        }
    }
    return result.length > 0 ? result : @"unknown";
}
- (void)setStatusIcon:(NSString *)symbolName fallbackTitle:(NSString *)fallbackTitle description:(NSString *)description {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:description];
    if (image == nil) {
        self.statusItem.button.image = nil;
        self.statusItem.button.title = fallbackTitle;
        return;
    }

    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
    image = [image imageWithSymbolConfiguration:configuration] ?: image;
    image.template = YES;

    self.statusItem.button.title = @"";
    self.statusItem.button.image = image;
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip = description;
}
- (NSString *)formattedTime:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeStyle = NSDateFormatterMediumStyle;
    formatter.dateStyle = NSDateFormatterNoStyle;
    return [formatter stringFromDate:date];
}
- (NSString *)medicLogPath {
    NSString *logsDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    return [logsDirectory stringByAppendingPathComponent:@"UplinC.log"];
}
- (void)appendMedicLog:(NSString *)message {
    @synchronized (self) {
        NSString *logsDirectory = [[self medicLogPath] stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:logsDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [self logTimestamp], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = [self medicLogPath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
            return;
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            return;
        }
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        [self rotateMedicLogIfNeeded];
    }
}
- (void)ensureMedicLogFileExists {
    NSString *logsDirectory = [[self medicLogPath] stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self medicLogPath]]) {
        [@"" writeToFile:[self medicLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
- (void)rotateMedicLogIfNeeded {
    NSString *path = [self medicLogPath];
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes fileSize];
    if (size < 1024 * 1024) {
        return;
    }

    NSString *oldPath = [path stringByAppendingString:@".1"];
    [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:path toPath:oldPath error:nil];
}
- (NSString *)logTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSZZZZZ";
    return [formatter stringFromDate:[NSDate date]];
}
- (NSString *)sanitizedSingleLine:(NSString *)text maxLength:(NSUInteger)maxLength {
    NSString *singleLine = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (singleLine.length <= maxLength) {
        return singleLine;
    }
    return [[singleLine substringToIndex:maxLength] stringByAppendingString:@"..."];
}
- (void)notifyResetComplete:(NSString *)reason {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Universal Control restarted";
    content.body = reason;
    content.sound = [UNNotificationSound defaultSound];

    NSString *identifier = [NSString stringWithFormat:@"uc-reset-%@", [[NSUUID UUID] UUIDString]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

@end
