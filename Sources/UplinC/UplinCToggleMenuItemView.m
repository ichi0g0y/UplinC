#import "UplinCToggleMenuItemView.h"

static const CGFloat kToggleRowHeight   = 22.0;
static const CGFloat kCheckmarkInset    =  6.0;
static const CGFloat kCheckmarkWidth    = 14.0;
static const CGFloat kTitleLeadingInset = 22.0;
static const CGFloat kTitleTrailingPad  = 16.0;
static const CGFloat kCornerRadius      =  4.0;

@interface UplinCToggleMenuItemView ()
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation UplinCToggleMenuItemView

- (instancetype)initWithTitle:(NSString *)title
                       target:(id)target
                       action:(SEL)action {
    NSFont *font = [NSFont menuFontOfSize:0];
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    NSSize size = [title sizeWithAttributes:attrs];
    CGFloat width = ceil(size.width) + kTitleLeadingInset + kTitleTrailingPad;
    self = [super initWithFrame:NSMakeRect(0, 0, width, kToggleRowHeight)];
    if (self) {
        _title  = [title copy];
        _target = target;
        _action = action;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (BOOL)wantsUpdateLayer { return NO; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited
                               | NSTrackingActiveInActiveApp
                               | NSTrackingInVisibleRect;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:opts
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (BOOL)isItemEnabled {
    NSMenuItem *item = self.enclosingMenuItem;
    return item ? item.enabled : YES;
}

- (NSColor *)textColor {
    if (![self isItemEnabled]) {
        return [NSColor disabledControlTextColor];
    }
    if (self.highlighted) {
        return [NSColor selectedMenuItemTextColor];
    }
    return [NSColor controlTextColor];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    BOOL drawHighlight = self.highlighted && [self isItemEnabled];
    if (drawHighlight) {
        NSRect bg = NSInsetRect(self.bounds, 5.0, 1.0);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bg
                                                             xRadius:kCornerRadius
                                                             yRadius:kCornerRadius];
        [[NSColor controlAccentColor] setFill];
        [path fill];
    }

    NSColor *fg = [self textColor];

    if (self.on) {
        NSRect checkRect = NSMakeRect(kCheckmarkInset,
                                      0,
                                      kCheckmarkWidth,
                                      self.bounds.size.height);
        NSImage *symbol = nil;
        if (@available(macOS 11.0, *)) {
            symbol = [NSImage imageWithSystemSymbolName:@"checkmark"
                                accessibilityDescription:nil];
        }
        if (symbol) {
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:12
                                                                weight:NSFontWeightSemibold];
            symbol = [symbol imageWithSymbolConfiguration:cfg];
            NSSize sz = symbol.size;
            NSRect drawRect = NSMakeRect(NSMinX(checkRect) + (kCheckmarkWidth - sz.width) / 2.0,
                                         (self.bounds.size.height - sz.height) / 2.0,
                                         sz.width,
                                         sz.height);
            [symbol drawInRect:drawRect
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:@{ NSImageHintInterpolation: @(NSImageInterpolationHigh) }];
            [fg set];
            NSRectFillUsingOperation(drawRect, NSCompositingOperationSourceIn);
        } else {
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont menuFontOfSize:0],
                NSForegroundColorAttributeName: fg,
            };
            NSString *check = @"✓";
            NSSize sz = [check sizeWithAttributes:attrs];
            NSPoint origin = NSMakePoint(NSMinX(checkRect) + (kCheckmarkWidth - sz.width) / 2.0,
                                         (self.bounds.size.height - sz.height) / 2.0);
            [check drawAtPoint:origin withAttributes:attrs];
        }
    }

    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont menuFontOfSize:0],
        NSForegroundColorAttributeName: fg,
    };
    NSSize titleSize = [self.title sizeWithAttributes:titleAttrs];
    NSPoint titleOrigin = NSMakePoint(kTitleLeadingInset,
                                      (self.bounds.size.height - titleSize.height) / 2.0);
    [self.title drawAtPoint:titleOrigin withAttributes:titleAttrs];
}

- (void)setOn:(BOOL)on {
    if (_on == on) return;
    _on = on;
    [self setNeedsDisplay:YES];
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if ([self isItemEnabled]) {
        self.highlighted = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    self.highlighted = NO;
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (![self isItemEnabled]) return;
    [self dispatchAction];
}

- (void)dispatchAction {
    if (self.target && self.action) {
        [NSApp sendAction:self.action to:self.target from:self.enclosingMenuItem];
    }
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement { return YES; }

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityCheckBoxRole;
}

- (NSString *)accessibilityLabel {
    return self.title;
}

- (id)accessibilityValue {
    return @(self.on);
}

- (BOOL)accessibilityPerformPress {
    if (![self isItemEnabled]) return NO;
    [self dispatchAction];
    return YES;
}

@end
