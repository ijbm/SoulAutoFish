// AutoFishWindow.mm
// 悬浮控制窗 v4：
//   - 零 UIControl：自绘 AFButton/AFToggle（纯 UIView + tap 手势），绕开 UIKit focus engine
//     （v3 崩溃: NSInternalInconsistencyException "targetNode" —— UIControl 触摸触发焦点解析炸 UIKit）
//   - 面板内嵌设置页、@try 装甲、崩溃捕获落盘（v3 保留）
//   - 穿透式根视图标准悬浮窗结构（v2 保留）
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

#pragma mark - 自绘控件（零 UIControl，不触发 focus engine）

@interface AFButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
- (void)setText:(NSString *)t;
@end

@implementation AFButton {
    UILabel *_label;
}
- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1];
        self.layer.cornerRadius = 9;
        self.userInteractionEnabled = YES;
        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = UIColor.whiteColor;
        _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _label.adjustsFontSizeToFitWidth = YES;
        _label.text = title;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)];
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)setText:(NSString *)t { _label.text = t; }
- (void)tap { if (self.onTap) self.onTap(); }
@end

@interface AFToggle : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^onChange)(BOOL on);
@end

@implementation AFToggle {
    UIView *_track;
    UIView *_knob;
}
- (instancetype)initWithFrame:(CGRect)frame on:(BOOL)on {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        _track = [[UIView alloc] initWithFrame:CGRectMake(0, 2, 51, 31)];
        _track.layer.cornerRadius = 15.5;
        [self addSubview:_track];
        _knob = [[UIView alloc] initWithFrame:CGRectMake(2, 4, 27, 27)];
        _knob.layer.cornerRadius = 13.5;
        _knob.backgroundColor = UIColor.whiteColor;
        [self addSubview:_knob];
        _on = on;
        [self render];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)];
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)render {
    _track.backgroundColor = _on
        ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1]
        : [UIColor colorWithWhite:0.35 alpha:1];
    _knob.frame = CGRectMake(_on ? 22 : 2, 4, 27, 27);
}
- (void)tap {
    _on = !_on;
    [self render];
    if (self.onChange) self.onChange(_on);
}
@end

#pragma mark - AutoFishWindow

@interface AutoFishWindow ()
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) AFButton *dotBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *logLabel;
@property (nonatomic, strong) AFButton *mainBtn;
@property (nonatomic, strong) AFButton *calibBtn;
@property (nonatomic, strong) AFButton *setBtn;
@property (nonatomic, strong) AFButton *minBtn;
@property (nonatomic, strong) UIView *stateDot;
@property (nonatomic, strong) UIView *settingsView;
@property (nonatomic, strong) AFToggle *autoStartSw;
@property (nonatomic, strong) AFToggle *autoExpandSw;
@property (nonatomic, strong) AFButton *spSlowBtn;
@property (nonatomic, strong) AFButton *spNormBtn;
@property (nonatomic, strong) AFButton *spFastBtn;
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

- (AFButton *)mkBtn:(NSString *)title color:(UIColor *)c frame:(CGRect)f onTap:(void(^)(void))blk {
    AFButton *b = [[AFButton alloc] initWithFrame:f title:title];
    b.backgroundColor = c;
    b.onTap = blk;
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

    UIColor *green = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
    UIColor *blue  = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1];
    UIColor *gray  = [UIColor colorWithWhite:0.32 alpha:1];

    self.mainBtn = [self mkBtn:@"启动" color:green frame:CGRectMake(12, 68, 58, 32) onTap:^{ [self onMain]; }];
    [self.panel addSubview:self.mainBtn];
    self.calibBtn = [self mkBtn:@"校准" color:blue frame:CGRectMake(76, 68, 50, 32) onTap:^{ [self onCalib]; }];
    [self.panel addSubview:self.calibBtn];
    self.setBtn = [self mkBtn:@"设置" color:gray frame:CGRectMake(132, 68, 38, 32) onTap:^{ [self onSettings]; }];
    [self.panel addSubview:self.setBtn];
    self.minBtn = [self mkBtn:@"—" color:gray frame:CGRectMake(176, 68, 36, 32) onTap:^{ [self onMinimize]; }];
    [self.panel addSubview:self.minBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.panel addGestureRecognizer:pan];

    // ---------- 设置页（面板内嵌） ----------
    self.settingsView = [[UIView alloc] initWithFrame:CGRectMake(0, 26, kPanelW, kPanelSettingsH - 26)];
    self.settingsView.hidden = YES;
    [self.panel addSubview:self.settingsView];

    [self.settingsView addSubview:[self mkLabel:@"进入游戏自动启动"
                                         frame:CGRectMake(12, 10, 140, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.autoStartSw = [[AFToggle alloc] initWithFrame:CGRectMake(kPanelW - 66, 6, 54, 35)
                                                     on:[d boolForKey:kAutoStart]];
    self.autoStartSw.onChange = ^(BOOL on) {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:kAutoStart];
    };
    [self.settingsView addSubview:self.autoStartSw];

    [self.settingsView addSubview:[self mkLabel:@"钓鱼浮窗自动展开"
                                         frame:CGRectMake(12, 42, 140, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.autoExpandSw = [[AFToggle alloc] initWithFrame:CGRectMake(kPanelW - 66, 38, 54, 35)
                                                    on:[d boolForKey:kAutoExpand]];
    self.autoExpandSw.onChange = ^(BOOL on) {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:kAutoExpand];
    };
    [self.settingsView addSubview:self.autoExpandSw];

    [self.settingsView addSubview:[self mkLabel:@"速度"
                                         frame:CGRectMake(12, 76, 40, 20)
                                         color:UIColor.whiteColor
                                         font:[UIFont systemFontOfSize:12]]];
    self.spSlowBtn = [self mkBtn:@"慢" color:gray frame:CGRectMake(58, 74, 44, 26) onTap:^{
        [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kSpeed];
        [self refreshSpeedButtons];
        [self pushConfig];
    }];
    [self.settingsView addSubview:self.spSlowBtn];
    self.spNormBtn = [self mkBtn:@"中" color:gray frame:CGRectMake(108, 74, 44, 26) onTap:^{
        [NSUserDefaults.standardUserDefaults setInteger:1 forKey:kSpeed];
        [self refreshSpeedButtons];
        [self pushConfig];
    }];
    [self.settingsView addSubview:self.spNormBtn];
    self.spFastBtn = [self mkBtn:@"快" color:gray frame:CGRectMake(158, 74, 44, 26) onTap:^{
        [NSUserDefaults.standardUserDefaults setInteger:2 forKey:kSpeed];
        [self refreshSpeedButtons];
        [self pushConfig];
    }];
    [self.settingsView addSubview:self.spFastBtn];
    [self refreshSpeedButtons];

    AFButton *back = [self mkBtn:@"返回" color:[UIColor colorWithRed:0.35 green:0.35 blue:0.40 alpha:1]
                         frame:CGRectMake(12, 110, kPanelW - 24, 28) onTap:^{ [self onCloseSettings]; }];
    [self.settingsView addSubview:back];

    // 收起后的圆点（同样零 UIControl）
    self.dotBtn = [[AFButton alloc] initWithFrame:CGRectMake(0, 0, 44, 44) title:@"🎣"];
    self.dotBtn.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    self.dotBtn.layer.cornerRadius = 22;
    self.dotBtn.layer.borderWidth = 0.5;
    self.dotBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.dotBtn.onTap = ^{ [self onRestore]; };
    self.dotBtn.hidden = YES;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlay) {
            // v6: Soul 无 scene manifest（老式 AppDelegate），宿主窗口全是
            // initWithFrame: 无 scene 建的。带 scene 的窗口在无 scene app 里
            // 会破坏 UIKit 事件节点图（触摸路由 targetNode 断言）。
            // 跟宿主完全同构：纯 initWithFrame，不碰 scene。
            CGRect sf = UIScreen.mainScreen.bounds;
            CGRect pf = CGRectMake(sf.size.width - kPanelW - 10, 100, kPanelW, kPanelH);
            UIWindow *win = [[UIWindow alloc] initWithFrame:pf];
            win.windowLevel = UIWindowLevelAlert + 10.0;
            win.backgroundColor = UIColor.clearColor;
            win.rootViewController = [UIViewController new];
            win.rootViewController.view.backgroundColor = UIColor.clearColor;
            [win.rootViewController.view addSubview:self.panel];
            [win.rootViewController.view addSubview:self.dotBtn];
            self.panel.frame = CGRectMake(0, 0, kPanelW, kPanelH);
            self.dotBtn.frame = CGRectMake(0, 0, 44, 44);
            self.dotBtn.hidden = YES;
            win.hidden = NO;
            self.overlay = win;
        }
        self.overlay.hidden = NO;
    });
}

#pragma mark 主面板动作（全部装甲）

- (void)onPan:(UIPanGestureRecognizer *)g {
    AFSafe(^{
        CGPoint t = [g translationInView:self.panel];
        CGRect f = self.overlay.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        // 限制在屏幕内
        CGRect sb = UIScreen.mainScreen.bounds;
        f.origin.x = fmaxf(0, fminf(f.origin.x, sb.size.width - f.size.width));
        f.origin.y = fmaxf(0, fminf(f.origin.y, sb.size.height - f.size.height));
        self.overlay.frame = f;
        [g setTranslation:CGPointZero inView:self.panel];
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
        CGRect f = self.overlay.frame;
        self.dotBtn.frame = CGRectMake(f.size.width - 44, 0, 44, 44);
        self.overlay.frame = CGRectMake(f.origin.x + f.size.width - 44, f.origin.y, 44, 44);
        self.panel.hidden = YES;
        self.dotBtn.hidden = NO;
    });
}

- (void)onRestore {
    AFSafe(^{
        CGRect f = self.overlay.frame;
        self.overlay.frame = CGRectMake(f.origin.x, f.origin.y, kPanelW, kPanelH);
        self.panel.frame = CGRectMake(0, 0, kPanelW, kPanelH);
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
        CGRect f = self.overlay.frame;
        f.size.height = kPanelSettingsH;
        self.overlay.frame = f;
        self.panel.frame = CGRectMake(0, 0, kPanelW, kPanelSettingsH);
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
        CGRect f = self.overlay.frame;
        f.size.height = kPanelH;
        self.overlay.frame = f;
        self.panel.frame = CGRectMake(0, 0, kPanelW, kPanelH);
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
    [self.mainBtn setText:(self.running ? @"停止" : @"启动")];
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
