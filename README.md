# SoulAutoFish — Soul 派对钓鱼全自动挂机插件

iOS arm64 dylib，注入 Soul App 后在聊天室/派对里全自动玩"钓鱼"H5 小游戏。
带悬浮控制窗：启动/停止、实时统计、坐标校准、速度/自动开关设置。

## 编译（GitHub Actions）

1. 把本目录推到 GitHub 仓库（`SoulAutoFish/` 内容作为仓库根目录）
2. Actions → `Build SoulAutoFish` → Run workflow（push 也会自动触发）
3. 跑完后在 run 页面下载 artifact `SoulAutoFish-dylib` → 里面的 `SoulAutoFish.dylib`

本地有 Xcode 的话也可以直接：

```bash
xcrun --sdk iphoneos clang++ \
  -target arm64-apple-ios14.0 -dynamiclib -fobjc-arc -std=c++17 -O2 \
  -framework Foundation -framework UIKit -framework WebKit \
  -Wl,-install_name,@executable_path/Frameworks/SoulAutoFish.dylib \
  -o SoulAutoFish.dylib src/SoulAutoFish.mm src/AutoFishJS.mm src/AutoFishWindow.mm
codesign --force --sign - --timestamp=none SoulAutoFish.dylib
```

## 注入（巨魔）

把 `SoulAutoFish.dylib` 丢进 `Soul_New.app/Frameworks/`，按你现有的巨魔注入流程走。

## 使用

进派对/聊天室，房主开启钓鱼玩法后：

- **悬浮窗**（可拖拽，右上角）：`启动` / `校准` / `设置` / 收起
- **校准**：第一次用先点"校准"，然后在游戏里先点【抛竿按钮】位置、再点【收杆按钮】位置，坐标永久保存（默认抛竿=底部中间、收杆=屏幕中间，多数情况不用校准）
- **设置**：
  - 进入游戏自动启动（默认关）
  - 钓鱼浮窗自动展开（默认关，开了就是全自动：浮窗出现 → 自动展开 → 自动开钓）
  - 抛竿速度：慢速（拟人）/ 正常 / 快速（激进）

## 工作原理

```
SOFishingModule(Swift) ──模式开关──▶ 钓鱼浮窗出现
        │  UIView addSubview: 全局过滤 hook 捕获浮窗
        ▼  自动调 delegate fishingFloatViewDidTapExpand: → 全屏
SOCPAppletsModule ──installWebGameBridgeForWebView:─▶ 抓到游戏 WKWebView
        │  注入 JS 引擎（documentStart userScript + 立即补注）
        ▼
JS 引擎（window.__autoFish）
  ├─ WebSocket 包装：游戏服务器协议 → 咬钩/收获信号
  ├─ MutationObserver：DOM 游戏的咬钩提示
  ├─ 声音信号：原生 hook SoulAppletsManager 音频 API / CFGame 音效 → 转发
  └─ 合成触摸（touch/pointer/mouse 三套全发）驱动抛竿/收杆
        ▲
悬浮窗（独立 UIWindow, hitTest 穿透）◀─ webkit.messageHandlers.AutoFishCtl ─ 统计/日志/校准回传
```

咬钩检测是三信号融合（声音 URL 关键词 + WebSocket 协议 + DOM 变化），
400ms 冷却防重复触发；无咬钩 18 秒超时自动重抛。

## 文件

```
src/SoulAutoFish.mm     主入口：全部 ObjC hook + 注入逻辑
src/AutoFishWindow.mm   悬浮控制窗 + WKScriptMessageHandler + 配置持久化
src/AutoFishJS.mm       注入游戏 WebView 的 JS 自动化引擎
.github/workflows/      GitHub Actions 编译
```

## 已 hook 的点（全部经逆向确认）

| 类 | 方法 | 作用 |
|---|---|---|
| SOCPAppletsModule | installWebGameBridgeForWebView: | 抓 webview + 注入 |
| SOCPAppletsModule | gameLoaded: | 游戏就绪 → 自动启动 |
| SOCPAppletsModule | loadApplet | 显示 appID |
| SOCPAppletsModule | userContentController:didReceiveScriptMessage: | 观察游戏消息 |
| SoulAppletsManager | service_innerAudioApiHandler:param:callbackId: | 音效 → 咬钩 |
| CFGameWebviewController | viewDidLoad / gameEffectSoundStartPlay: | LUK 容器路径 |
| UIView | addSubview:（过滤） | 捕获钓鱼浮窗 |
| SOFishingModule | fishingFloatViewDidTapExpand: | 展开后自动启动 |

纯 ObjC runtime swizzle（method_setImplementation），不依赖 CydiaSubstrate。
