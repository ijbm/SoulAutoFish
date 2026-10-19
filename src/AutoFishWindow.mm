// AutoFishWindow.mm
// 悬浮控制窗实现：独立 UIWindow (Alert+10) + hitTest 穿透 + 可拖拽面板
#import "AutoFishWindow.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kAutoStart  = @"af_autostart";
static NSString * const kAutoExpand = @"af_autoexpand";
static NSString * const kSpeed      = @"af_speed";     // 0 慢 1 正常 2 快
static NSString * const kCastPos    = @"af_castpos";  // "x,y"
static NSString * const kReelPos    = @"af_reelpos";

#pragma mark - helpers

NSString *AFJSEscape(NSString *s) {
    if (!s) s = @"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
    if (!d) return @"\"\"";
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (arr.length < 2) return @"\"\"";
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

NSString *AFMakeJSCmd(NSString *name, NSDictionary *arg) {
    if (arg.count) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:arg options:0 error:nil];
        NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
        return [NSString stringWithFormat:@"window.__autoFish&&window.__autoFish.cmd('%@',%@)", name, json];
    }
    return [NSString stringWithFormat:@"window.__autoFish&&window.__autoFish.cmd('%@')", name];
}

static UIViewController *AFTopViewController(void) {
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (!key && ws.windows.count) key = ws.windows.firstObject;
            if (key) break;
        }
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 穿透窗口（标准悬浮窗方案：panel 挂在穿透式根视图内）

@interface AFPassthroughView : UIView
@end

@implementation AFPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v; // 空白处穿透；面板/按钮正常响应
}
@end

@interface AFOverlayVC : UIViewController
@end

@implementation AFOverlayVC
- (void)loadView {
    AFPassthroughView *v = [[AFPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = YES;
    self.view = v;
}
@end

#pragma mark - AutoFishWindow

@interface AutoFishWindow ()
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *dotBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *logLabel;
@property (nonatomic, strong) UIButton *mainBtn;
@property (nonatomic, strong) UIButton *calibBtn;
@property (nonatomic, strong) UIButton *setBtn;
@property (nonatomic, strong) UIButton *minBtn;
@property (nonatomic, strong) UIView *stateDot;
@property (nonatomic, weak) WKWebView *webview;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *appID;
@end

static CGFloat const kPanelW = 224.0;
static CGFloat const kPanelH = 110.0;

@implementation AutoFishWindow

+ (instancetype)shared {
    static AutoFishWindow *s = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[AutoFishWindow alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) [self buildUI];
    return self;
}

#pragma mark UI

- (UIButton *)mkBtn:(NSString *)title color:(UIColor *)c action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = c;
    b.layer.cornerRadius = 9;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 0.5;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.panel.clipsToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 120, 18)];
    title.text = @"🎣 自动钓鱼";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [self.panel addSubview:title];

    self.stateDot = [[UIView alloc] initWithFrame:CGRectMake(kPanelW - 22, 12, 8, 8)];
    self.stateDot.layer.cornerRadius = 4;
    self.stateDot.backgroundColor = [UIColor colorWithWhite:0.6 alpha:1];
    [self.panel addSubview:self.stateDot];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 28, kPanelW - 24, 15)];
    self.statusLabel.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.65 alpha:1];
    self.statusLabel.font = [UIFont fontWithName:@"Menlo" size:11];
    self.statusLabel.text = @"状态:待机";
    [self.panel addSubview:self.statusLabel];

    self.logLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, kPanelW - 24, 14)];
    self.logLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    self.logLabel.font = [UIFont fontWithName:@"Menlo" size:10];
    self.logLabel.text = @"等待游戏…";
    [self.panel addSubview:self.logLabel];

    self.mainBtn  = [self mkBtn:@"启动" color:[UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1] action:@selector(onMain)];
    self.mainBtn.frame = CGRectMake(12, 68, 58, 32);
    [self.panel addSubview:self.mainBtn];

    self.calibBtn = [self mkBtn:@"校准" color:[UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1] action:@selector(onCalib)];
    self.calibBtn.frame = CGRectMake(76, 68, 50, 32);
    [self.panel addSubview:self.calibBtn];

    self.setBtn = [self mkBtn:@"设置" color:[UIColor colorWithWhite:0.32 alpha:1] action:@selector(onSettings)];
    self.setBtn.frame = CGRectMake(132, 68, 38, 32);
    [self.panel addSubview:self.setBtn];

    self.minBtn = [self mkBtn:@"—" color:[UIColor colorWithWhite:0.32 alpha:1] action:@selector(onMinimize)];
    self.minBtn.frame = CGRectMake(176, 68, 36, 32);
    [self.panel addSubview:self.minBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.panel addGestureRecognizer:pan];

    // 收起后的圆点
    self.dotBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.dotBtn.frame = CGRectMake(0, 0, 44, 44);
    self.dotBtn.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    self.dotBtn.layer.cornerRadius = 22;
    self.dotBtn.layer.borderWidth = 0.5;
    self.dotBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.dotBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    [self.dotBtn setTitle:@"🎣" forState:UIControlStateNormal];
    [self.dotBtn addTarget:self action:@selector(onRestore) forControlEvents:UIControlEventTouchUpInside];
    self.dotBtn.hidden = YES;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlay) {
            UIWindowScene *ws = nil;
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:UIWindowScene.class] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    ws = (UIWindowScene *)s; break;
                }
            }
            if (!ws) {
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if ([s isKindOfClass:UIWindowScene.class]) { ws = (UIWindowScene *)s; break; }
                }
            }
            CGRect frame = UIScreen.mainScreen.bounds;
            UIWindow *win = nil;
            if (@available(iOS 13.0, *)) {
                if (ws) {
                    win = [[UIWindow alloc] initWithWindowScene:ws];
                    frame = ws.coordinateSpace.bounds;
                }
            }
            if (!win) win = [[UIWindow alloc] initWithFrame:frame];
            win.frame = frame; // 显式设置，防止 scene 尺寸未同步
            win.windowLevel = UIWindowLevelAlert + 10.0;
            win.backgroundColor = UIColor.clearColor;
            win.userInteractionEnabled = YES;
            win.rootViewController = [[AFOverlayVC alloc] init];
            win.hidden = NO;
            self.overlay = win;

            UIView *root = win.rootViewController.view;
            [root addSubview:self.panel];
            [root addSubview:self.dotBtn];

            self.panel.center = CGPointMake(frame.size.width - kPanelW / 2 - 10,
                                             100.0 + kPanelH / 2);
            self.dotBtn.center = CGPointMake(frame.size.width - 36, 170);
        }
        self.overlay.hidden = NO;
        self.panel.hidden = NO;
        self.dotBtn.hidden = YES;
    });
}

#pragma mark actions

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.panel.superview ?: self.overlay;
    CGPoint t = [g translationInView:sv];
    CGPoint c = self.panel.center;
    self.panel.center = CGPointMake(c.x + t.x, c.y + t.y);
    [g setTranslation:CGPointZero inView:sv];
}

- (void)onMain {
    if (self.running) [self stopEngine]; else [self startEngine];
}

- (void)onCalib {
    [self evalJS:AFMakeJSCmd(@"calibrate", nil)];
    [self addLog:@"校准: 点两个位置"];
}

- (void)onMinimize {
    self.panel.hidden = YES;
    self.dotBtn.hidden = NO;
}

- (void)onRestore {
    self.panel.hidden = NO;
    self.dotBtn.hidden = YES;
}

- (void)onSettings {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL as = [d boolForKey:kAutoStart];
    BOOL ae = [d boolForKey:kAutoExpand];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自动钓鱼设置"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"进入游戏自动启动：%@", as ? @"开 ✅" : @"关"]
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) { [d setBool:!as forKey:kAutoStart]; }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"钓鱼浮窗自动展开：%@", ae ? @"开 ✅" : @"关"]
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) { [d setBool:!ae forKey:kAutoExpand]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"抛竿速度…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) { [self speedAlert]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.setBtn;
    UIViewController *top = AFTopViewController();
    if (top) [top presentViewController:a animated:YES completion:nil];
}

- (void)speedAlert {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger cur = [d integerForKey:kSpeed];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"抛竿速度"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"慢速（拟人）", @"正常", @"快速（激进）"];
    for (NSInteger i = 0; i < 3; i++) {
        NSString *mark = (i == cur) ? @" ✅" : @"";
        [a addAction:[UIAlertAction actionWithTitle:[names[i] stringByAppendingString:mark]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
                                                [d setInteger:i forKey:kSpeed];
                                                [self pushConfig];
                                            }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.setBtn;
    UIViewController *top = AFTopViewController();
    if (top) [top presentViewController:a animated:YES completion:nil];
}

#pragma mark engine control

- (void)startEngine {
    if (!self.webview) { [self addLog:@"未检测到游戏窗口"]; return; }
    [self pushConfig];
    [self evalJS:AFMakeJSCmd(@"start", nil)];
    self.running = YES;
    [self refreshUI];
}

- (void)stopEngine {
    [self evalJS:AFMakeJSCmd(@"stop", nil)];
    self.running = NO;
    [self refreshUI];
}

- (void)refreshUI {
    [self.mainBtn setTitle:(self.running ? @"停止" : @"启动") forState:UIControlStateNormal];
    self.mainBtn.backgroundColor = self.running
        ? [UIColor colorWithRed:1.0 green:0.31 blue:0.36 alpha:1]
        : [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
    self.stateDot.backgroundColor = self.running
        ? [UIColor colorWithRed:0.2 green:1.0 blue:0.45 alpha:1]
        : [UIColor colorWithWhite:0.6 alpha:1];
    if (!self.running) self.statusLabel.text = @"状态:待机";
}

- (void)pushConfig {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger sp = [d integerForKey:kSpeed];
    NSArray *cast, *react;
    if (sp == 0)      { cast = @[@4000, @6500]; react = @[@150, @350]; }
    else if (sp == 2) { cast = @[@1200, @2000]; react = @[@40, @110]; }
    else              { cast = @[@2200, @3800]; react = @[@70, @180]; }
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithDictionary:@{
        @"castMin": cast[0], @"castMax": cast[1],
        @"reactMin": react[0], @"reactMax": react[1],
    }];
    NSString *cp = [d stringForKey:kCastPos];
    if (cp.length) {
        NSArray *p = [cp componentsSeparatedByString:@","];
        if (p.count == 2) cfg[@"castPos"] = @[@([p[0] floatValue]), @([p[1] floatValue])];
    }
    NSString *rp = [d stringForKey:kReelPos];
    if (rp.length) {
        NSArray *p = [rp componentsSeparatedByString:@","];
        if (p.count == 2) cfg[@"reelPos"] = @[@([p[0] floatValue]), @([p[1] floatValue])];
    }
    [self evalJS:AFMakeJSCmd(@"cfg", cfg)];
}

- (void)evalJS:(NSString *)js {
    WKWebView *wv = self.webview;
    if (!wv) return;
    void (^blk)(void) = ^{ [wv evaluateJavaScript:js completionHandler:nil]; };
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

#pragma mark callbacks

- (void)attachWebView:(WKWebView *)wv {
    _webview = wv;
    if (wv) [self addLog:@"游戏视图已连接"];
}

- (void)setCurrentAppID:(NSString *)appID {
    _appID = [appID copy];
    if (appID.length) [self addLog:[NSString stringWithFormat:@"appID: %@", appID]];
}

- (void)addLog:(NSString *)msg {
    if (!msg.length) return;
    NSString *m = msg.length > 90 ? [msg substringToIndex:90] : msg;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logLabel.text = m;
    });
}

- (void)onGameMessage:(NSString *)name body:(id)body {
    if ([name isEqualToString:@"gameRecharge"]) {
        [self addLog:@"游戏请求充值"];
    }
}

- (void)onFloatViewShown:(UIView *)fv {
    if (![NSUserDefaults.standardUserDefaults boolForKey:kAutoExpand]) return;
    static void *kExpandedKey = &kExpandedKey;
    if (objc_getAssociatedObject(fv, kExpandedKey)) return;
    objc_setAssociatedObject(fv, kExpandedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id delegate = nil;
        @try { delegate = [fv valueForKey:@"delegate"]; } @catch (id e) {}
        if (delegate && [delegate respondsToSelector:@selector(fishingFloatViewDidTapExpand:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(delegate,
                @selector(fishingFloatViewDidTapExpand:), fv);
            [self addLog:@"已自动展开钓鱼浮窗"];
        }
    });
}

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *d = (NSDictionary *)message.body;
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSString *ev = d[@"event"];
    if ([ev isEqualToString:@"stats"]) {
        NSString *line = [NSString stringWithFormat:@"%@ 抛:%@ 获:%@ 咬:%@",
                          d[@"state"], d[@"casts"], d[@"catches"], d[@"bites"]];
        dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = line; });
    } else if ([ev isEqualToString:@"calibrated"]) {
        NSArray *cast = d[@"cast"], *reel = d[@"reel"];
        if ([cast isKindOfClass:NSArray.class] && cast.count == 2 &&
            [reel isKindOfClass:NSArray.class] && reel.count == 2) {
            NSUserDefaults *d2 = NSUserDefaults.standardUserDefaults;
            [d2 setObject:[NSString stringWithFormat:@"%.3f,%.3f", [cast[0] floatValue], [cast[1] floatValue]] forKey:kCastPos];
            [d2 setObject:[NSString stringWithFormat:@"%.3f,%.3f", [reel[0] floatValue], [reel[1] floatValue]] forKey:kReelPos];
            [self addLog:@"校准完成"];
        }
    } else if ([ev isEqualToString:@"log"]) {
        [self addLog:d[@"msg"]];
    }
}

#pragma mark props

- (BOOL)autoStart  { return [NSUserDefaults.standardUserDefaults boolForKey:kAutoStart]; }
- (BOOL)autoExpand { return [NSUserDefaults.standardUserDefaults boolForKey:kAutoExpand]; }

@end
