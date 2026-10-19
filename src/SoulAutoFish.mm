// SoulAutoFish.mm
// Soul 派对钓鱼 · 全自动挂机插件（主入口）
//
// Engine: iOS 14.0+ / arm64 / ObjC++ (ARC)
// Build:  GitHub Actions — xcrun --sdk iphoneos clang++（见 .github/workflows/build.yml）
// Inject: 巨魔(TrollStore)手动注入 Frameworks 即可
//
// 机制（全部基于逆向确认的类/选择器）:
//   SOCPAppletsModule  installWebGameBridgeForWebView:  → 抓游戏 WKWebView + 注入 JS 引擎
//   SOCPAppletsModule  gameLoaded:                      → 游戏就绪，自动启动
//   SOCPAppletsModule  loadApplet                       → 显示当前游戏 appID
//   SOCPAppletsModule  userContentController:didReceiveScriptMessage: → 观察游戏消息
//   SoulAppletsManager service_innerAudioApiHandler:param:callbackId: → 声音事件 → 咬钩信号
//   CFGameWebviewController viewDidLoad / gameEffectSoundStartPlay:   → LUK 容器路径
//   UIView addSubview: (全局过滤)                        → 捕获钓鱼浮窗出现 → 自动展开
//   SOFishingModule fishingFloatViewDidTapExpand:        → 展开后自动启动引擎

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AutoFishWindow.h"
#import "AutoFishJS.h"

#define AFLog(fmt, ...) NSLog(@"[SoulAutoFish] " fmt, ##__VA_ARGS__)

#pragma mark - swizzle

static IMP af_swizzle(Class cls, SEL sel, IMP newImp) {
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        AFLog(@"method missing: %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
        return NULL;
    }
    Class sc = class_getSuperclass(cls);
    if (sc && class_getInstanceMethod(sc, sel) == m) {
        AFLog(@"inherited (skip): %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
        return NULL; // 父类实现，不全局劫持
    }
    return method_setImplementation(m, newImp);
}

#pragma mark - JS 引擎注入

static void af_inject(WKWebView *wv) {
    if (!wv) return;
    @try {
        static void *kInjectedKey = &kInjectedKey;
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (!objc_getAssociatedObject(wv, kInjectedKey)) {
            objc_setAssociatedObject(wv, kInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { [ucc removeScriptMessageHandlerForName:@"AutoFishCtl"]; } @catch (id e) {}
            [ucc addScriptMessageHandler:[AutoFishWindow shared] name:@"AutoFishCtl"];
            WKUserScript *us = [[WKUserScript alloc] initWithSource:[AutoFishJS engine]
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:YES];
            [ucc addUserScript:us];
            AFLog(@"user script installed");
        }
        // 幂等（JS 内部有 __autoFish 守卫），当前页立即补注
        [wv evaluateJavaScript:[AutoFishJS engine] completionHandler:nil];
    } @catch (id e) {
        AFLog(@"inject error: %@", e);
    }
}

#pragma mark - SOCPAppletsModule hooks（Soul 小程序容器）

static void (*orig_installBridge)(id, SEL, id);
static void h_installBridge(id self, SEL _cmd, WKWebView *wv) {
    if (orig_installBridge) orig_installBridge(self, _cmd, wv);
    if (!wv) return;
    [[AutoFishWindow shared] addLog:@"游戏桥已挂载"];
    [[AutoFishWindow shared] attachWebView:wv];
    void (^blk)(void) = ^{ af_inject(wv); };
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

static void (*orig_gameLoaded)(id, SEL, id);
static void h_gameLoaded(id self, SEL _cmd, id args) {
    if (orig_gameLoaded) orig_gameLoaded(self, _cmd, args);
    AFLog(@"gameLoaded");
    WKWebView *wv = nil;
    @try { wv = [self valueForKey:@"wkWebView"]; } @catch (id e) {}
    dispatch_async(dispatch_get_main_queue(), ^{
        if (wv) {
            [[AutoFishWindow shared] addLog:@"游戏已加载"];
            [[AutoFishWindow shared] attachWebView:wv];
            af_inject(wv);
        }
        // 注意：不在所有小游戏里自动启动 —— 自动启动只走钓鱼专属路径
        // (h_didExpand / 钓鱼浮窗展开)，避免在狼人杀等其它派对游戏里误触发
    });
}

static void (*orig_appletsMsg)(id, SEL, id, id);
static void h_appletsMsg(id self, SEL _cmd, id ucc, id msg) {
    if (orig_appletsMsg) orig_appletsMsg(self, _cmd, ucc, msg);
    @try {
        NSString *name = [msg valueForKey:@"name"];
        id body = [msg valueForKey:@"body"];
        [[AutoFishWindow shared] onGameMessage:name body:body];
    } @catch (id e) {}
}

static void (*orig_loadApplet)(id, SEL);
static void h_loadApplet(id self, SEL _cmd) {
    if (orig_loadApplet) orig_loadApplet(self, _cmd);
    @try {
        id applet = [self valueForKey:@"applet"];
        NSString *appID = [applet valueForKey:@"appID"];
        if (appID.length) [[AutoFishWindow shared] setCurrentAppID:appID];
    } @catch (id e) {}
}

#pragma mark - SoulAppletsManager hook（小程序音频 API → 咬钩信号）

static void (*orig_innerAudio)(id, SEL, id, id, id);
static void h_innerAudio(id self, SEL _cmd, id param, id p2, id cbId) {
    if (orig_innerAudio) orig_innerAudio(self, _cmd, param, p2, cbId);
    @try {
        NSString *s = [param description];
        if (s.length) {
            NSString *js = [NSString stringWithFormat:
                @"window.__autoFish&&window.__autoFish.cmd('sound',{url:%@})", AFJSEscape(s)];
            [[AutoFishWindow shared] evalJS:js];
        }
    } @catch (id e) {}
}

#pragma mark - CFGameWebviewController hooks（LUK 游戏容器）

static void (*orig_cfViewDidLoad)(id, SEL);
static void h_cfViewDidLoad(id self, SEL _cmd) {
    if (orig_cfViewDidLoad) orig_cfViewDidLoad(self, _cmd);
    @try {
        WKWebView *wv = [self valueForKey:@"webView"];
        if (wv) {
            [[AutoFishWindow shared] attachWebView:wv];
            if ([NSThread isMainThread]) af_inject(wv);
            else dispatch_async(dispatch_get_main_queue(), ^{ af_inject(wv); });
        }
    } @catch (id e) {}
}

static void (*orig_cfSound)(id, SEL, id);
static void h_cfSound(id self, SEL _cmd, id body) {
    if (orig_cfSound) orig_cfSound(self, _cmd, body);
    @try {
        NSString *s = [body description];
        if (s.length) {
            NSString *js = [NSString stringWithFormat:
                @"window.__autoFish&&window.__autoFish.cmd('sound',{url:%@})", AFJSEscape(s)];
            [[AutoFishWindow shared] evalJS:js];
        }
    } @catch (id e) {}
}

#pragma mark - 钓鱼浮窗自动展开

static void (*orig_addSubview)(id, SEL, id);
static void h_addSubview(id self, SEL _cmd, id view) {
    if (orig_addSubview) orig_addSubview(self, _cmd, view);
    static Class floatCls = NULL;
    static dispatch_once_t once;
    if (!view) return;
    dispatch_once(&once, ^{
        floatCls = NSClassFromString(@"_TtC14SoulChatModule18SOFishingFloatView");
    });
    if (floatCls && [view isKindOfClass:floatCls]) {
        [[AutoFishWindow shared] onFloatViewShown:view];
    }
}

static void (*orig_didExpand)(id, SEL, id);
static void h_didExpand(id self, SEL _cmd, id view) {
    if (orig_didExpand) orig_didExpand(self, _cmd, view);
    if ([[AutoFishWindow shared] autoStart]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoFishWindow shared] startEngine];
        });
    }
}

#pragma mark - entry

__attribute__((constructor)) static void SoulAutoFishEntry(void) {
    @autoreleasepool {
        AFInstallCrashCapture(); // 崩溃捕获最先装

        int n = 0;

        Class applets = NSClassFromString(@"SOCPAppletsModule");
        Class mgr     = NSClassFromString(@"SoulAppletsManager");
        Class cfvc    = NSClassFromString(@"CFGameWebviewController");
        Class fmod    = NSClassFromString(@"_TtC14SoulChatModule15SOFishingModule");

        if (applets) {
            orig_installBridge = (void (*)(id, SEL, id))af_swizzle(applets,
                @selector(installWebGameBridgeForWebView:), (IMP)h_installBridge);
            if (orig_installBridge) n++;
            orig_gameLoaded = (void (*)(id, SEL, id))af_swizzle(applets,
                @selector(gameLoaded:), (IMP)h_gameLoaded);
            if (orig_gameLoaded) n++;
            orig_appletsMsg = (void (*)(id, SEL, id, id))af_swizzle(applets,
                @selector(userContentController:didReceiveScriptMessage:), (IMP)h_appletsMsg);
            if (orig_appletsMsg) n++;
            orig_loadApplet = (void (*)(id, SEL))af_swizzle(applets,
                @selector(loadApplet), (IMP)h_loadApplet);
            if (orig_loadApplet) n++;
        } else {
            AFLog(@"SOCPAppletsModule not found");
        }

        if (mgr) {
            orig_innerAudio = (void (*)(id, SEL, id, id, id))af_swizzle(mgr,
                @selector(service_innerAudioApiHandler:param:callbackId:), (IMP)h_innerAudio);
            if (orig_innerAudio) n++;
        }

        if (cfvc) {
            orig_cfViewDidLoad = (void (*)(id, SEL))af_swizzle(cfvc,
                @selector(viewDidLoad), (IMP)h_cfViewDidLoad);
            if (orig_cfViewDidLoad) n++;
            orig_cfSound = (void (*)(id, SEL, id))af_swizzle(cfvc,
                @selector(gameEffectSoundStartPlay:), (IMP)h_cfSound);
            if (orig_cfSound) n++;
        }

        if (fmod) {
            orig_didExpand = (void (*)(id, SEL, id))af_swizzle(fmod,
                @selector(fishingFloatViewDidTapExpand:), (IMP)h_didExpand);
            if (orig_didExpand) n++;
        }

        orig_addSubview = (void (*)(id, SEL, id))af_swizzle([UIView class],
            @selector(addSubview:), (IMP)h_addSubview);
        if (orig_addSubview) n++;

        AFLog(@"%d hooks installed", n);
        // v7: 构造函数在 pre-main 阶段执行（UIApplicationMain 未启动），
        // v2~v6 在这里创建 UI，视图带半初始化状态进 UIKit 事件节点图，
        // 首次触摸路由即 targetNode 断言。全部 UI 延迟到主 runloop 创建。
        NSString *appletsOK = applets ? @"✓" : @"✗";
        NSString *cfOK = cfvc ? @"✓" : @"✗";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoFishWindow shared] addLog:[NSString stringWithFormat:
                @"hooks %d/9 · applets:%@ cf:%@ [v7-lazyui]", n, appletsOK, cfOK]];
            [[AutoFishWindow shared] show];
        });
    }
}
