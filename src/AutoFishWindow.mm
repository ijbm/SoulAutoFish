// AutoFishWindow.mm
// 悬浮控制窗 v3：
//   - 面板内嵌设置页（不 present 任何 VC，避开宿主 VC 生命周期 swizzle）
//   - 全部按钮动作 @try/@catch 装甲，异常落盘不崩
//   - 未捕获异常记录器 → Documents/SoulAutoFish_log.txt
//   - 穿透式根视图标准悬浮窗结构
#import "AutoFishWindow.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kAutoStart  = @"af_autostart";
static NSString * const kAutoExpand = @"af_autoexpand";
static NSString * const kSpeed      = @"af_speed";     // 0 慢 1 正常 2 快
static NSString * const kCastPos    = @"af_castpos";  // "x,y"
static NSString * const kReelPos    = @"af_reelpos";

#pragma mark - 崩溃/日志捕获

static NSString * AFCrashLogPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SoulAutoFish_log.txt"];
}

void AFWriteLogLine(NSString *s) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s ?: @"(nil)"];
        NSString *path = AFCrashLogPath();
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (id e) {}
}

static void af_uncaught_handler(NSException *e) {
    NSString *s = [NSString stringWithFormat:@"UNCAUGHT EXCEPTION: %@\nreason: %@\nstack:\n%@",
                   e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    AFWriteLogLine(s);
}

void AFInstallCrashCapture(void) {
    NSSetUncaughtExceptionHandler(&af_uncaught_handler);
}

/// 动作装甲：异常捕获落盘，不崩
static void AFSafe(void (^blk)(void)) {
    @try { blk(); }
    @catch (NSException *e) {
        AFWriteLogLine([NSString stringWithFormat:@"CAUGHT %@: %@\nstack:\n%@",
                        e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]]);
    }
}

#pragma mark - JS 命令

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

#pragma mark - 穿透窗口（panel 挂在穿透式根视图内）

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
// 设置页（面板内嵌，不 present）
@property (nonatomic, strong) UIView *settingsView;
@property (nonatomic, strong) UISwitch *autoStartSw;
@property (nonatomic, strong) UISwitch *autoExpandSw;
@property (nonatomic, strong) UIButton *spSlowBtn;
@property (nonatomic, strong) UIButton *spNormBtn;
@property (nonatomic, strong) UIButton *spFastBtn;
@property (nonatomic, weak) WKWebView *webview;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *appID;
@end

static CGFloat const kPanelW = 224.0;
static CGFloat const kPanelH = 110.0;
static CGFloat const kPanelSettingsH = 168.0;

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

- (UILabel *)mkLabel:(NSString *)text frame:(CGRect)f color:(UIColor *)c font:(UIFont *)f2 {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.textColor = c;
    l.font = f2;
    l.userInteractionEnabled = NO;
    return l;
}

- (void)buildUI {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 0.5;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.panel.clipsToBounds = YES;

    [self.panel addSubview:[self mkLabel:@"🎣 自动钓鱼"
                                  frame:CGRectMake(12, 8, 120, 18)
                                  color:UIColor.whiteColor
                                  font:[UIFont systemFontOfSize:13 weight:UIFontWeightBold]]];

    self.stateDot = [[UIView alloc] initWithFrame:CGRectMake(kPanelW - 22, 12, 8, 8)];
    self.stateDot.layer.cornerRadius = 4;
    self.stateDot.backgroundColor = [UIColor colorWithWhite:0.6 alpha:1];
    self.stateDot.userInteractionEnabled = NO;
    [self.panel addSubview:self.stateDot];

    self.statusLabel = [self mkLabel:@"状态:待机"
                              frame:CGRectMake(12, 28, kPanelW - 24, 15)
                              color:[UIColor colorWithRed:0.55 green:0.95 blue:0.65 alpha:1]
                              font:[UIFont fontWithName:@"Menlo" size:11]];
    [self.panel addSubview:self.statusLabel];

    self.logLabel = [self mkLabel:@"初始化…"
                           frame:CGRectMake(12, 46, kPanelW - 24, 14)
                           color:[UIColor colorWithWhite:0.72 alpha:1]
                           font:[UIFont fontWithName:@"Menlo" size:10]];
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

    // ---------- 设置页（面板内嵌） ----------
    self.settingsView = [[UIView alloc] initWithFrame:CGRectMake(0, 26, kPanelW, kPanelSettingsH - 26)];
    self.settingsView.hidden = YES;
    [self.panel addSubview:self.settingsView];

    [self.settingsView addSubview:[self mkLabel:@"进入游戏自动启动"
                                         frame:CGRectMake(12, 8, 140, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.autoStartSw = [[UISwitch alloc] initWithFrame:CGRectMake(kPanelW - 64, 4, 51, 31)];
    self.autoStartSw.on = [d boolForKey:kAutoStart];
    [self.autoStartSw addTarget:self action:@selector(onAutoStartSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.settingsView addSubview:self.autoStartSw];

    [self.settingsView addSubview:[self mkLabel:@"钓鱼浮窗自动展开"
                                         frame:CGRectMake(12, 40, 140, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.autoExpandSw = [[UISwitch alloc] initWithFrame:CGRectMake(kPanelW - 64, 36, 51, 31)];
    self.autoExpandSw.on = [d boolForKey:kAutoExpand];
    [self.autoExpandSw addTarget:self action:@selector(onAutoExpandSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.settingsView addSubview:self.autoExpandSw];

    [self.settingsView addSubview:[self mkLabel:@"速度"
                                         frame:CGRectMake(12, 74, 40, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.spSlowBtn = [self mkBtn:@"慢" color:[UIColor colorWithWhite:0.32 alpha:1] action:@selector(onSpeed:)];
    self.spSlowBtn.tag = 0;
    self.spSlowBtn.frame = CGRectMake(58, 72, 44, 26);
    [self.settingsView addSubview:self.spSlowBtn];
    self.spNormBtn = [self mkBtn:@"中" color:[UIColor colorWithWhite:0.32 alpha:1] action:@selector(onSpeed:)];
    self.spNormBtn.tag = 1;
    self.spNormBtn.frame = CGRectMake(108, 72, 44, 26);
    [self.settingsView addSubview:self.spNormBtn];
    self.spFastBtn = [self mkBtn:@"快" color:[UIColor colorWithWhite:0.32 alpha:1] action:@selector(onSpeed:)];
    self.spFastBtn.tag = 2;
    self.spFastBtn.frame = CGRectMake(158, 72, 44, 26);
    [self.settingsView addSubview:self.spFastBtn];
    [self refreshSpeedButtons];

    UIButton *back = [self mkBtn:@"返回" color:[UIColor colorWithRed:0.35 green:0.35 blue:0.40 alpha:1] action:@selector(onCloseSettings)];
    back.frame = CGRectMake(12, 108, kPanelW - 24, 28);
    [self.settingsView addSubview:back];

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
            win.frame = frame;
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

#pragma mark 主面板动作（全部装甲）

- (void)onPan:(UIPanGestureRecognizer *)g {
    AFSafe(^{
        UIView *sv = self.panel.superview ?: self.overlay;
        CGPoint t = [g translationInView:sv];
        CGPoint c = self.panel.center;
        self.panel.center = CGPointMake(c.x + t.x, c.y + t.y);
        [g setTranslation:CGPointZero inView:sv];
    });
}

- (void)onMain {
    AFSafe(^{
        if (self.running) [self stopEngine]; else [self startEngine];
    });
}

- (void)onCalib {
    AFSafe(^{
        [self evalJS:AFMakeJSCmd(@"calibrate", nil)];
        [self addLog:@"校准: 点两个位置"];
    });
}

- (void)onMinimize {
    AFSafe(^{
        self.panel.hidden = YES;
        self.dotBtn.hidden = NO;
    });
}

- (void)onRestore {
    AFSafe(^{
        self.panel.hidden = NO;
        self.dotBtn.hidden = YES;
    });
}

#pragma mark 设置页（面板内嵌，无 present）

- (void)onSettings {
    AFSafe(^{
        self.settingsView.hidden = NO;
        self.statusLabel.hidden = YES;
        self.logLabel.hidden = YES;
        self.mainBtn.hidden = YES;
        self.calibBtn.hidden = YES;
        self.setBtn.hidden = YES;
        self.minBtn.hidden = YES;
        CGRect f = self.panel.frame;
        f.size.height = kPanelSettingsH;
        self.panel.frame = f;
    });
}

- (void)onCloseSettings {
    AFSafe(^{
        self.settingsView.hidden = YES;
        self.statusLabel.hidden = NO;
        self.logLabel.hidden = NO;
        self.mainBtn.hidden = NO;
        self.calibBtn.hidden = NO;
        self.setBtn.hidden = NO;
        self.minBtn.hidden = NO;
        CGRect f = self.panel.frame;
        f.size.height = kPanelH;
        self.panel.frame = f;
    });
}

- (void)onAutoStartSwitch:(UISwitch *)s {
    AFSafe(^{ [NSUserDefaults.standardUserDefaults setBool:s.on forKey:kAutoStart]; });
}

- (void)onAutoExpandSwitch:(UISwitch *)s {
    AFSafe(^{ [NSUserDefaults.standardUserDefaults setBool:s.on forKey:kAutoExpand]; });
}

- (void)onSpeed:(UIButton *)b {
    AFSafe(^{
        [NSUserDefaults.standardUserDefaults setInteger:b.tag forKey:kSpeed];
        [self refreshSpeedButtons];
        [self pushConfig];
    });
}

- (void)refreshSpeedButtons {
    NSInteger cur = [NSUserDefaults.standardUserDefaults integerForKey:kSpeed];
    UIColor *sel = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
    UIColor *nor = [UIColor colorWithWhite:0.32 alpha:1];
    self.spSlowBtn.backgroundColor = (cur == 0) ? sel : nor;
    self.spNormBtn.backgroundColor = (cur == 1) ? sel : nor;
    self.spFastBtn.backgroundColor = (cur == 2) ? sel : nor;
}

#pragma mark 引擎控制

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

#pragma mark 回调

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
    AFWriteLogLine(m);
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
        AFSafe(^{
            id delegate = nil;
            @try { delegate = [fv valueForKey:@"delegate"]; } @catch (id e) {}
            if (delegate && [delegate respondsToSelector:@selector(fishingFloatViewDidTapExpand:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(delegate,
                    @selector(fishingFloatViewDidTapExpand:), fv);
                [self addLog:@"已自动展开钓鱼浮窗"];
            }
        });
    });
}

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    AFSafe(^{
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
    });
}

#pragma mark props

- (BOOL)autoStart  { return [NSUserDefaults.standardUserDefaults boolForKey:kAutoStart]; }
- (BOOL)autoExpand { return [NSUserDefaults.standardUserDefaults boolForKey:kAutoExpand]; }

@end
