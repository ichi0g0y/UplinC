#import "UplinCApp.h"

@implementation UplinCApp (MachineIcon)

- (NSImage *)machineIndicatorImageWithHeartbeat:(BOOL)hasHeartbeat
                                universalControl:(BOOL)hasUniversalControl
                                          online:(BOOL)isOnline {
    NSMutableArray<NSImage *> *glyphs = [[NSMutableArray alloc] init];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular];

    NSImage *(^loadGlyph)(NSString *) = ^NSImage *(NSString *symbolName) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        if (image == nil) {
            return nil;
        }
        image = [image imageWithSymbolConfiguration:config] ?: image;
        image.template = YES;
        return image;
    };

    if (hasHeartbeat) {
        NSImage *glyph = loadGlyph(@"waveform.path.ecg");
        if (glyph != nil) {
            [glyphs addObject:glyph];
        }
    }
    if (hasUniversalControl) {
        NSImage *glyph = loadGlyph(@"display.2");
        if (glyph != nil) {
            [glyphs addObject:glyph];
        }
    }
    NSImage *dot = loadGlyph(isOnline ? @"circle.fill" : @"circle");
    if (dot != nil) {
        [glyphs addObject:dot];
    }

    if (glyphs.count == 0) {
        return nil;
    }

    const CGFloat slot = 14.0;
    const CGFloat padding = 2.0;
    const CGFloat height = 14.0;
    NSSize totalSize = NSMakeSize(slot * glyphs.count + padding * (glyphs.count - 1), height);

    NSImage *composite = [NSImage imageWithSize:totalSize flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        (void)dstRect;
        CGFloat x = 0;
        for (NSImage *glyph in glyphs) {
            NSSize glyphSize = glyph.size;
            CGFloat drawWidth = MIN(glyphSize.width, slot);
            CGFloat drawHeight = MIN(glyphSize.height, height);
            NSRect rect = NSMakeRect(x + (slot - drawWidth) / 2.0,
                                     (height - drawHeight) / 2.0,
                                     drawWidth,
                                     drawHeight);
            [glyph drawInRect:rect];
            x += slot + padding;
        }
        return YES;
    }];
    composite.template = YES;
    return composite;
}

@end
