#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UplinCToggleMenuItemView : NSView

- (instancetype)initWithTitle:(NSString *)title
                       target:(nullable id)target
                       action:(nullable SEL)action;

@property (nonatomic, copy)   NSString *title;
@property (nonatomic, weak)   id        target;
@property (nonatomic, assign) SEL       action;
@property (nonatomic, assign) BOOL      on;
@property (nonatomic, assign, getter=isHighlighted) BOOL highlighted;

@end

NS_ASSUME_NONNULL_END
