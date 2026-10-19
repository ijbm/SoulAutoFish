// AutoFishJS.mm
// 注入到游戏 WKWebView 的自动化引擎：
//   - WebSocket 流量监听（游戏协议信号）
//   - MutationObserver（DOM 游戏的咬钩提示）
//   - CFGame 桥观察（gameStateChange）
//   - 合成触摸引擎（touch/pointer/mouse 三套事件全发）
//   - 状态机: 抛竿 → 等待咬钩(声音/WS/DOM 三信号) → 收杆 → 结算 → 循环
//   - 校准模式：手动点两个位置记录抛竿/收杆坐标
//   - 统计上报: webkit.messageHandlers.AutoFishCtl
#import "AutoFishJS.h"

@implementation AutoFishJS

+ (NSString *)engine {
    return @R"AFJS((function () {
'use strict';
if (window.__autoFish) { return; }

function post(o) {
    try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.AutoFishCtl) {
            window.webkit.messageHandlers.AutoFishCtl.postMessage(o);
        }
    } catch (e) {}
}
function rand(a, b) { return a + Math.random() * (b - a); }
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

var AF = {
    running: false,
    state: 'idle',
    lastCast: 0,
    biteCooldown: 0,
    calib: null,
    stats: { casts: 0, catches: 0, bites: 0 },
    cfg: {
        castMin: 2200,          // 抛竿后最短等待 ms
        castMax: 3800,
        reactMin: 70,           // 咬钩后反应延迟 ms（拟人）
        reactMax: 180,
        recastTimeout: 18000,   // 无咬钩超时重抛 ms
        catchDelay: [700, 1400],
        strikeGap: [180, 350],     // 刺鱼后到长按的间隔
        holdMs: [2600, 3400],      // 长按收杆时长
        biteWindow: [4000, 9000],  // 定时模式: 抛竿后预计咬钩窗口
        timedMode: true,           // 定时兜底（无信号也按窗口刺鱼）
        castPos: [0.5, 0.86],   // 归一化抛竿点
        reelPos: [0.5, 0.5],    // 归一化收杆点
        biteSoundRe: /(bite|fish|hook|catch|zhongyu|shanggou|yaogou|diaoyu|hit)/i
    }
};

function report() {
    post({ event: 'stats', state: AF.state, casts: AF.stats.casts,
           catches: AF.stats.catches, bites: AF.stats.bites });
}
function log(msg) { post({ event: 'log', msg: String(msg) }); }

// ---------------- 合成触摸 ----------------
function gameTarget() {
    var list = document.querySelectorAll('canvas');
    var best = null, bestArea = 0;
    for (var i = 0; i < list.length; i++) {
        var r = list[i].getBoundingClientRect();
        if (r.width * r.height > bestArea) { bestArea = r.width * r.height; best = list[i]; }
    }
    return best || document.body;
}
function makeTouch(el, x, y) {
    try {
        // pageX/pageY 必须显式设置 — Touch 构造器默认 0
        return new Touch({ identifier: 1, target: el, clientX: x, clientY: y,
                           pageX: x, pageY: y, screenX: x, screenY: y,
                           radiusX: 2, radiusY: 2, rotationAngle: 0, force: 1 });
    } catch (e) { return null; }
}
function evBase(x, y) {
    return { bubbles: true, cancelable: true, view: window,
             clientX: x, clientY: y, screenX: x, screenY: y,
             pageX: x, pageY: y, button: 0 };
}
function fire(el, ev) { try { el.dispatchEvent(ev); } catch (e) {} }
function dispatchStart(el, x, y, touch) {
    var base = evBase(x, y);
    if (touch) {
        try {
            fire(el, new TouchEvent('touchstart', Object.assign({}, base,
                { touches: [touch], targetTouches: [touch], changedTouches: [touch] })));
        } catch (e) {}
    }
    try {
        fire(el, new PointerEvent('pointerdown', Object.assign(
            { pointerId: 1, pointerType: 'touch', isPrimary: true }, base)));
    } catch (e) {}
    fire(el, new MouseEvent('mousedown', base));
}
function dispatchMove(el, x, y, touch) {
    var base = evBase(x, y);
    if (touch) {
        try {
            fire(el, new TouchEvent('touchmove', Object.assign({}, base,
                { touches: [touch], targetTouches: [touch], changedTouches: [touch] })));
        } catch (e) {}
    }
    try {
        fire(el, new PointerEvent('pointermove', Object.assign(
            { pointerId: 1, pointerType: 'touch', isPrimary: true }, base)));
    } catch (e) {}
    fire(el, new MouseEvent('mousemove', base));
}
function dispatchEnd(el, x, y, touch) {
    var base = evBase(x, y);
    if (touch) {
        try {
            fire(el, new TouchEvent('touchend', Object.assign({}, base,
                { touches: [], targetTouches: [], changedTouches: [touch] })));
        } catch (e) {}
    }
    try {
        fire(el, new PointerEvent('pointerup', Object.assign(
            { pointerId: 1, pointerType: 'touch', isPrimary: true }, base)));
    } catch (e) {}
    fire(el, new MouseEvent('mouseup', base));
    fire(el, new MouseEvent('click', base));
}
function tapNorm(nx, ny) {
    var el = gameTarget();
    var r = el.getBoundingClientRect();
    var x = r.left + nx * r.width, y = r.top + ny * r.height;
    var t = makeTouch(el, x, y);
    dispatchStart(el, x, y, t);
    dispatchEnd(el, x, y, t);
}
// 长按: 按住 holdMs（中途一次 touchmove 防静止判定）
function holdNorm(nx, ny, holdMs) {
    var el = gameTarget();
    var r = el.getBoundingClientRect();
    var x = r.left + nx * r.width, y = r.top + ny * r.height;
    var t = makeTouch(el, x, y);
    dispatchStart(el, x, y, t);
    setTimeout(function () { dispatchMove(el, x + 1, y + 1, t); }, Math.round(holdMs * 0.4));
    setTimeout(function () { dispatchEnd(el, x, y, t); }, holdMs);
}

// ---------------- 信号源 ----------------
var wsLogCount = 0;
// 游戏用二进制协议 (v11: JSON.stringify(ArrayBuffer) 全是 "{}")
function handleServerText(s, fromBinary) {
    if (s && wsLogCount < 120) { wsLogCount++; log('WS<' + (fromBinary ? 'B:' : '') + s.slice(0, 120) + '>'); }
    // 精确咬钩信号（实测协议: 文本帧 JSON 载荷 {"c":0,...}）
    if (AF.running && AF.state === 'waiting' && s.indexOf('"c":0') >= 0) {
        onBite('proto');
        return;
    }
    if (!AF.running) return;
    if (/catch|reward|score|coin|prize|shouhuo|jiangli/i.test(s)) {
        AF.stats.catches++; report();
    }
    if (/(bite|hook|shanggou|yaogou|zhongyu|diaoyu|fish|上钩|咬|中鱼)/i.test(s)) {
        onBite('ws');
    }
}
function printableRatio(s) {
    if (!s) return 0;
    var ok = 0, n = Math.min(s.length, 200);
    for (var i = 0; i < n; i++) {
        var c = s.charCodeAt(i);
        if ((c >= 32 && c < 127) || c > 0x4E00) ok++;
    }
    return n ? ok / n : 0;
}
function onServerMsg(data) {
    try {
        if (data instanceof ArrayBuffer) {
            var arr = new Uint8Array(data);
            var txt = '';
            try { txt = new TextDecoder('utf-8').decode(arr); } catch (e) {}
            if (printableRatio(txt) > 0.7) {
                handleServerText(txt, true);
            } else {
                // 二进制帧: hex 前 60 字节
                var hex = '';
                for (var i = 0; i < Math.min(arr.length, 60); i++) hex += ('0' + arr[i].toString(16)).slice(-2);
                if (wsLogCount < 120) {
                    wsLogCount++;
                    log('WS<hex' + arr.length + ':' + hex + '>');
                }
                // 收入鱼塘确认帧: soul magic + cmd 0xca (实测协议)
                if (hex.indexOf('736f756c00000000000000ca') === 0) {
                    AF.stats.catches++;
                    report();
                    log('渔获+1 (协议确认)');
                }
            }
            return;
        }
        if (typeof Blob !== 'undefined' && data instanceof Blob) {
            data.text().then(function (t) { handleServerText(t, true); }).catch(function () {});
            return;
        }
        handleServerText(String(data), false);
    } catch (e) {}
}

(function wrapWS() {
    var OW = window.WebSocket;
    if (!OW || OW.__afHooked) return;
    function WS(url, protos) {
        var ws = (protos !== undefined) ? new OW(url, protos) : new OW(url);
        try {
            ws.addEventListener('open', function () { log('WS已连接: ' + String(url).slice(0, 60)); });
            ws.addEventListener('error', function () { log('WS错误: ' + String(url).slice(0, 60)); });
            ws.addEventListener('close', function () { log('WS关闭: ' + String(url).slice(0, 60)); });
            ws.addEventListener('message', function (ev) {
                try { onServerMsg(ev.data); } catch (e) {}
            });
        } catch (e) {}
        return ws;
    }
    try { WS.prototype = OW.prototype; } catch (e) {}
    // 关键修复: 复制全部静态常量 (OPEN/CONNECTING/CLOSING/CLOSED...)
    // v9 漏了这步 → 游戏读 WebSocket.OPEN 拿到 undefined → 连接状态机崩 → "网络不稳定"
    try {
        Object.getOwnPropertyNames(OW).forEach(function (k) {
            if (!(k in WS)) { try { WS[k] = OW[k]; } catch (e) {} }
        });
    } catch (e) {}
    WS.__afHooked = true;
    window.WebSocket = WS;
})();

(function wrapCFGame() {
    if (!window.CFGame) return;
    try {
        var life = window.CFGame.GameLife;
        if (life && typeof life.gameStateChange === 'function') {
            var orig = life.gameStateChange;
            life.gameStateChange = function (data) {
                try {
                    if (AF.running && data) {
                        var s = (typeof data === 'string') ? data : JSON.stringify(data);
                        if (/start|play|fish|bite|catch/i.test(s)) onBite('state');
                    }
                } catch (e) {}
                return orig.apply(this, arguments);
            };
        }
    } catch (e) {}
})();

// 游戏音效: HTML5 Audio + 哈希文件名 (d7b5e219....m4a)
// 记录每次播放的 URL → 咬钩音效的哈希值可从日志识别后精确匹配
(function wrapAudio() {
    try {
        if (window.HTMLAudioElement && !HTMLAudioElement.__afHooked) {
            var origPlay = HTMLAudioElement.prototype.play;
            HTMLAudioElement.prototype.play = function () {
                try {
                    var u = this.src || this.currentSrc || '';
                    if (u) AF.onSound(u);
                } catch (e) {}
                return origPlay.apply(this, arguments);
            };
            HTMLAudioElement.__afHooked = true;
        }
    } catch (e) {}
})();

(function wrapDOM() {
    try {
        var mo = new MutationObserver(function (muts) {
            if (!AF.running || AF.state !== 'waiting') return;
            for (var i = 0; i < muts.length; i++) {
                var m = muts[i];
                if (m.type !== 'childList' || !m.addedNodes || !m.addedNodes.length) continue;
                for (var j = 0; j < m.addedNodes.length; j++) {
                    var n = m.addedNodes[j];
                    var txt = ((n.textContent || '') + ' ' + (n.className || '') + ' ' + (n.id || '')).slice(0, 200);
                    if (/咬|拉竿|收竿|提竿|上钩|中鱼|bite|reel|pull/i.test(txt)) {
                        onBite('dom'); return;
                    }
                }
            }
        });
        mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
})();

// ---------------- 状态机 ----------------
AF.onBite = function (src) {
    if (!AF.running || AF.state !== 'waiting') return;
    var now = Date.now();
    if (now - AF.biteCooldown < 400) return;
    AF.biteCooldown = now;
    AF.state = 'reeling';
    AF.stats.bites++;
    log('咬钩(' + src + ')→刺鱼');
    report();
    var react = rand(AF.cfg.reactMin, AF.cfg.reactMax);
    setTimeout(function () {
        tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]); // 刺鱼（点按）
        setTimeout(function () {
            var hold = rand(AF.cfg.holdMs[0], AF.cfg.holdMs[1]);
            log('长按收杆 ' + Math.round(hold) + 'ms');
            holdNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1], hold); // 长按收杆
            setTimeout(function () {
                tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]); // 关结算
                AF.stats.catches++;
                AF.state = 'idle';
                report();
            }, hold + rand(AF.cfg.catchDelay[0], AF.cfg.catchDelay[1]));
        }, rand(AF.cfg.strikeGap[0], AF.cfg.strikeGap[1]));
    }, react);
};

AF.onSound = function (idOrUrl) {
    var s = String(idOrUrl || '');
    if (s && AF.soundLogCount < 40) { AF.soundLogCount = (AF.soundLogCount || 0) + 1; log('音效<' + s.slice(0, 80) + '>'); }
    if (AF.cfg.biteSoundRe.test(s)) onBite('sound');
};

async function mainLoop() {
    log('引擎启动');
    while (AF.running) {
        if (AF.state === 'idle') {
            await sleep(rand(250, 700));
            if (!AF.running) break;
            AF.state = 'waiting';
            AF.lastCast = Date.now();
            AF.biteAt = rand(AF.cfg.biteWindow[0], AF.cfg.biteWindow[1]);
            AF.stats.casts++;
            var el = gameTarget();
            tapNorm(AF.cfg.castPos[0], AF.cfg.castPos[1]);
            log('抛竿→' + (el.tagName || '?') + ' ' + Math.round(AF.cfg.castPos[0] * 100) + '%,' + Math.round(AF.cfg.castPos[1] * 100) + '%');
            report();
        } else if (AF.state === 'waiting') {
            var waited = Date.now() - AF.lastCast;
            // 定时兜底: 信号没来但窗口到了 → 当作咬钩（真实信号提前触发，互不冲突）
            if (AF.cfg.timedMode && waited > AF.biteAt) {
                onBite('timer');
            } else if (waited > AF.cfg.recastTimeout) {
                AF.state = 'idle';
                log('超时重抛');
            }
        }
        await sleep(200);
    }
    AF.state = 'idle';
    report();
    log('引擎停止');
}

// ---------------- 校准 ----------------
AF.startCalibrate = function () {
    AF.calib = [];
    log('校准: 先点【抛竿】位置, 再点【收杆】位置');
    function onEv(e) {
        if (!AF.calib) return;
        var t = e.changedTouches ? (e.changedTouches[0] || e.touches[0]) : e;
        if (!t) return;
        var el = gameTarget(), r = el.getBoundingClientRect();
        AF.calib.push([(t.clientX - r.left) / r.width, (t.clientY - r.top) / r.height]);
        if (AF.calib.length >= 2) {
            AF.cfg.castPos = AF.calib[0];
            AF.cfg.reelPos = AF.calib[1];
            AF.calib = null;
            cleanup();
            post({ event: 'calibrated', cast: AF.cfg.castPos, reel: AF.cfg.reelPos });
        }
    }
    function cleanup() {
        document.removeEventListener('touchstart', onEv, true);
        document.removeEventListener('mousedown', onEv, true);
    }
    document.addEventListener('touchstart', onEv, true);
    document.addEventListener('mousedown', onEv, true);
};

// ---------------- 命令接口 ----------------
AF.cmd = function (name, arg) {
    switch (name) {
        case 'start':
            if (!AF.running) { AF.running = true; mainLoop(); }
            break;
        case 'stop':
            AF.running = false;
            break;
        case 'cfg':
            if (arg && typeof arg === 'object') {
                for (var k in arg) { if (k in AF.cfg) AF.cfg[k] = arg[k]; }
            }
            break;
        case 'calibrate':
            AF.startCalibrate();
            break;
        case 'sound':
            AF.onSound(arg && (arg.url || arg.id));
            break;
        case 'stats':
            report();
            break;
    }
    report();
    return 'ok';
};

window.__autoFish = AF;
log('自动钓鱼引擎就绪 ' + location.href.slice(0, 80));
report();
})();
)AFJS";
}

@end
