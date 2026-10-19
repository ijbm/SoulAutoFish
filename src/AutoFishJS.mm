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
function tapNorm(nx, ny) {
    var el = gameTarget();
    var r = el.getBoundingClientRect();
    var x = r.left + nx * r.width;
    var y = r.top + ny * r.height;
    var touch = null;
    try {
        // 关键: pageX/pageY 必须显式设置 — Touch 构造器默认 0，
        // canvas 引擎读 touches[0].pageX/pageY → v10 全落在 (0,0)
        touch = new Touch({ identifier: 1, target: el, clientX: x, clientY: y,
                            pageX: x, pageY: y, screenX: x, screenY: y,
                            radiusX: 2, radiusY: 2, rotationAngle: 0, force: 1 });
    } catch (e) {}
    var base = { bubbles: true, cancelable: true, view: window,
                 clientX: x, clientY: y, screenX: x, screenY: y,
                 pageX: x, pageY: y, button: 0 };
    var evts = [];
    try {
        var t0 = touch ? { touches: [touch], targetTouches: [touch], changedTouches: [touch] }
                       : { touches: [], targetTouches: [], changedTouches: [] };
        evts.push(new TouchEvent('touchstart', Object.assign({}, base, t0)));
        evts.push(new TouchEvent('touchend', Object.assign({}, base,
            { touches: [], targetTouches: [], changedTouches: touch ? [touch] : [] })));
    } catch (e) {}
    try {
        evts.push(new PointerEvent('pointerdown', Object.assign(
            { pointerId: 1, pointerType: 'touch', isPrimary: true }, base)));
        evts.push(new PointerEvent('pointerup', Object.assign(
            { pointerId: 1, pointerType: 'touch', isPrimary: true }, base)));
    } catch (e) {}
    evts.push(new MouseEvent('mousedown', base));
    evts.push(new MouseEvent('mouseup', base));
    evts.push(new MouseEvent('click', base));
    for (var i = 0; i < evts.length; i++) {
        try { el.dispatchEvent(evts[i]); } catch (e) {}
    }
}

// ---------------- 信号源 ----------------
var wsLogCount = 0;
// 游戏用二进制协议 (v11: JSON.stringify(ArrayBuffer) 全是 "{}")
function handleServerText(s, fromBinary) {
    if (s && wsLogCount < 120) { wsLogCount++; log('WS<' + (fromBinary ? 'B:' : '') + s.slice(0, 120) + '>'); }
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
                if (wsLogCount < 120) {
                    wsLogCount++;
                    var hex = '';
                    for (var i = 0; i < Math.min(arr.length, 60); i++) hex += ('0' + arr[i].toString(16)).slice(-2);
                    log('WS<hex' + arr.length + ':' + hex + '>');
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
function onBite(src) {
    if (!AF.running || AF.state !== 'waiting') return;
    var now = Date.now();
    if (now - AF.biteCooldown < 400) return;
    AF.biteCooldown = now;
    AF.state = 'reeling';
    AF.stats.bites++;
    log('咬钩信号: ' + src);
    report();
    setTimeout(function () {
        tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]);   // 收杆
        setTimeout(function () {
            tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]); // 关结算页
            AF.stats.catches++;
            AF.state = 'idle';
            report();
        }, rand(AF.cfg.catchDelay[0], AF.cfg.catchDelay[1]));
    }, rand(AF.cfg.reactMin, AF.cfg.reactMax));
}

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
            AF.stats.casts++;
            var el = gameTarget();
            tapNorm(AF.cfg.castPos[0], AF.cfg.castPos[1]);
            log('抛竿→' + (el.tagName || '?') + ' ' + Math.round(AF.cfg.castPos[0] * 100) + '%,' + Math.round(AF.cfg.castPos[1] * 100) + '%');
            report();
        } else if (AF.state === 'waiting' && Date.now() - AF.lastCast > AF.cfg.recastTimeout) {
            AF.state = 'idle';
            log('超时重抛');
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
