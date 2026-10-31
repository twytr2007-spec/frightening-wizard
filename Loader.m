// Loader for FLEX (compiled together with FLEX sources into libFLEX.dylib).
// Adds a small draggable "FLEX" button; tap it to open/close the explorer.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id FLEXMgr(void) {
    Class c = NSClassFromString(@"FLEXManager");
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedManager"));
}

@interface FXWindow : UIWindow
@end
@implementation FXWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

@interface FXTarget : NSObject
- (void)tap;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static FXWindow *gW;
static UIButton *gB;
static FXTarget *gT;

@implementation FXTarget
- (void)tap {
    id m = FLEXMgr();
    if (m) ((void (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"toggleExplorer"));
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void Setup(void) {
    if (gW) return;
    UIWindowScene *sc = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        sc = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) break;
    }
    if (!sc) return;

    gW = [[FXWindow alloc] initWithWindowScene:sc];
    gW.windowLevel = UIWindowLevelAlert - 1;
    gW.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    gW.rootViewController = root;
    gW.hidden = NO;

    gT = [FXTarget new];
    gB = [UIButton buttonWithType:UIButtonTypeSystem];
    gB.frame = CGRectMake(sc.coordinateSpace.bounds.size.width - 60, 140, 46, 46);
    gB.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    gB.layer.cornerRadius = 23;
    gB.tintColor = UIColor.whiteColor;
    gB.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [gB setTitle:@"FLEX" forState:UIControlStateNormal];
    [gB addTarget:gT action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [gB addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gT action:@selector(pan:)]];
    [root.view addSubview:gB];
}

__attribute__((constructor)) static void FXInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id m = FLEXMgr();
        if (m) {
            @try { [m setValue:@YES forKey:@"networkDebuggingEnabled"]; } @catch (...) {}
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { Setup(); }];
        Setup();
    });
}
