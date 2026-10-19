// AutoFishWindow.h
// 悬浮控制窗：启动/停止/校准/设置 + 实时统计 + JS 回调
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

/// 生成调用 JS 引擎的语句: window.__autoFish.cmd('name', {json})
NSString *AFMakeJSCmd(NSString *name, NSDictionary *arg);
/// JSON 字符串转义（带引号）
NSString *AFJSEscape(NSString *s);

@interface AutoFishWindow : NSObject <WKScriptMessageHandler>
+ (instancetype)shared;

- (void)show;
- (void)attachWebView:(WKWebView *)wv;
- (void)startEngine;
- (void)stopEngine;
- (void)evalJS:(NSString *)js;
- (void)addLog:(NSString *)msg;
- (void)onGameMessage:(NSString *)name body:(id)body;
- (void)onFloatViewShown:(UIView *)floatView;
- (void)setCurrentAppID:(NSString *)appID;

@property (nonatomic, readonly) BOOL autoStart;
@property (nonatomic, readonly) BOOL autoExpand;
@property (nonatomic, weak, readonly) WKWebView *webview;
@end
