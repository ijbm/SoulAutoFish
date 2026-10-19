// AutoFishJS.mm
// 注入到游戏 WKWebView 的自动化引擎 v15（全协议驱动）
//   实测协议 (wss://prod-soul-connexus.soulapp.cn/connexus, soul 魔数二进制帧):
//     soul+00+b0        抛竿确认
//     soul+01+f4+54     鱼咬          ← 刺鱼触发
//     文本帧 FOLD_FISH   上钩确认+鱼名  ← 开始长按
//     soul+01+f4+83     收杆完成       ← 松手
//     soul+00+ca        收入鱼塘       ← 渔获计数
//     {"c":0,...}       心跳确认(每3s) ← 不是咬钩!
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
function log(msg) { post({ event: 'log', msg: String(msg) }); }
function report() {
    post({ event: 'stats', state: AF.state, casts: AF.stats.casts,
           catches: AF.stats.catches, bites: AF.stats.bites });
}

var AF = {
    running: false,
    state: 'idle',          // idle | waiting | striking | reeling
    lastCast: 0,
    biteCooldown: 0,
    hooked: false,
    releaseHold: null,
    calib: null,
    stats: { casts: 0, catches: 0, bites: 0 },
    cfg: {
        castMin: 2200,          // 抛竿间隔
        castMax: 3800,
        reactMin: 70,           // 咬钩→刺鱼反应延迟
        reactMax: 180,
        strikeWait: 3000,       // 刺鱼后等上钩确认超时
        strikeGap: [180, 350],  // 刺鱼→长按间隔
        reelMaxMs: 90000,       // 长按上限（协议 f4/83 提前释放）
        recastTimeout: 25000,   // 无咬钩重抛
        catchDelay: [700, 1400],
        castPos: [0.5, 0.86],
        reelPos: [0.5, 0.5],
        timedMode: false,       // 定时兜底（默认关，协议信号已精确）
        biteWindow: [8000, 15000],
        biteSoundRe: /(bite|fish|hook|catch|zhongyu|shanggou|yaogou|diaoyu|hit)/i
    }
};

// ---------------- 触摸引擎 ----------------
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
// 长按: 按住直到 finish 触发（协议释放或超时），AF.releaseHold 供协议提前松手
function holdNorm(nx, ny, maxMs, onDone) {
    var el = gameTarget();
    var r = el.getBoundingClientRect();
    var x = r.left + nx * r.width, y = r.top + ny * r.height;
    var t = makeTouch(el, x, y);
    dispatchStart(el, x, y, t);
    var done = false;
    var moveT = setInterval(function () { dispatchMove(el, x + 1, y + 1, t); }, 2000);
    var finish = function () {
        if (done) return;
        done = true;
        clearInterval(moveT);
        dispatchEnd(el, x, y, t);
        AF.releaseHold = null;
        if (onDone) onDone();
    };
    AF.releaseHold = finish;
    setTimeout(finish, maxMs);
}

// ---------------- 协议信号 ----------------
function onFishFrame(name) {
    log('上钩: ' + name);
    if (AF.state === 'striking') {
        AF.hooked = true;
        startReel();
    } else if (AF.state === 'waiting') {
        onBite('fish');
    }
}
function onReelDone() {
    if (AF.state === 'reeling' && AF.releaseHold) {
        log('收杆完成(协议)');
        AF.releaseHold();
    }
}

// ---------------- 状态机 ----------------
function onBite(src) {
    if (!AF.running || AF.state !== 'waiting') return;
    var now = Date.now();
    if (now - AF.biteCooldown < 400) return;
    AF.biteCooldown = now;
    AF.state = 'striking';
    AF.stats.bites++;
    log('咬钩(' + src + ')→刺鱼');
    report();
    setTimeout(function () {
        if (AF.state !== 'striking') return;
        tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]); // 刺鱼
        setTimeout(function () {
            if (AF.state !== 'striking') return;
            if (AF.hooked) { startReel(); return; } // FISH 帧已到
            AF.state = 'idle';
            log('刺鱼未中，重抛');
            report();
        }, AF.cfg.strikeWait);
    }, rand(AF.cfg.reactMin, AF.cfg.reactMax));
}
function startReel() {
    AF.state = 'reeling';
    log('长按收杆(协议释放, 最长' + Math.round(AF.cfg.reelMaxMs / 1000) + 's)');
    holdNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1], AF.cfg.reelMaxMs, function () {
        setTimeout(function () {
            tapNorm(AF.cfg.reelPos[0], AF.cfg.reelPos[1]); // 关结算
            AF.hooked = false;
            AF.state = 'idle';
            report();
        }, rand(AF.cfg.catchDelay[0], AF.cfg.catchDelay[1]));
    });
    report();
}

async function mainLoop() {
    log('引擎启动');
    while (AF.running) {
        if (AF.state === 'idle') {
            await sleep(rand(250, 700));
            if (!AF.running) break;
            AF.state = 'waiting';
            AF.lastCast = Date.now();
            AF.stats.casts++;
            tapNorm(AF.cfg.castPos[0], AF.cfg.castPos[1]);
            report();
        } else if (AF.state === 'waiting') {
            var waited = Date.now() - AF.lastCast;
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

// ---------------- WS 拦截（二进制协议解码 + 精确信号） ----------------
var wsLogCount = 0;
function handleServerText(s, fromBinary) {
    if (s && wsLogCount < 150) { wsLogCount++; log('WS<' + (fromBinary ? 'B:' : '') + s.slice(0, 120) + '>'); }
    // 上钩确认帧: FOLD_FISH + 鱼名
    if (s.indexOf('FOLD_FISH') >= 0) {
        var ms = s.match(/[\u4e00-\u9fa5]{2,}/g);
        onFishFrame(ms && ms.length ? ms[ms.length - 1] : '?');
        return;
    }
    if (!AF.running) return;
    if (/catch|reward|score|coin|prize/i.test(s)) { AF.stats.catches++; report(); }
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
            var hex = '';
            for (var i = 0; i < Math.min(arr.length, 60); i++) hex += ('0' + arr[i].toString(16)).slice(-2);
            if (wsLogCount < 150) { wsLogCount++; log('WS<hex' + arr.length + ':' + hex + '>'); }
            // ---- 精确协议匹配（实测） ----
            if (hex.indexOf('736f756c0100000000000000f400000054') === 0) {
                onBite('proto');            // 鱼咬
            } else if (hex.indexOf('736f756c0100000000000000f400000083') === 0) {
                onReelDone();               // 收杆完成 → 松手
            } else if (hex.indexOf('736f756c00000000000000ca') === 0) {
                AF.stats.catches++;         // 收入鱼塘
                report();
                log('渔获+1 (协议确认)');
            }
            return;
        }
        if (typeof Blob !== 'undefined' && data instanceof Blob) {
            data.arrayBuffer().then(function (ab) { onServerMsg(ab); }).catch(function () {});
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
    try {
        Object.getOwnPropertyNames(OW).forEach(function (k) {
            if (!(k in WS)) { try { WS[k] = OW[k]; } catch (e) {} }
        });
    } catch (e) {}
    WS.__afHooked = true;
    window.WebSocket = WS;
})();

// ---------------- 音频钩子（辅助信号） ----------------
(function wrapAudio() {
    try {
        if (window.HTMLAudioElement && !HTMLAudioElement.__afHooked) {
            var origPlay = HTMLAudioElement.prototype.play;
            HTMLAudioElement.prototype.play = function () {
                try {
                    var u = this.src || this.currentSrc || '';
                    if (u && AF.soundLogCount < 40) {
                        AF.soundLogCount = (AF.soundLogCount || 0) + 1;
                        log('音效<' + u.slice(0, 80) + '>');
                    }
                } catch (e) {}
                return origPlay.apply(this, arguments);
            };
            HTMLAudioElement.__afHooked = true;
        }
    } catch (e) {}
})();

// ---------------- DOM 观察（辅助） ----------------
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
            if (AF.releaseHold) AF.releaseHold();
            break;
        case 'cfg':
            if (arg && typeof arg === 'object') {
                for (var k in arg) { if (k in AF.cfg) AF.cfg[k] = arg[k]; }
            }
            break;
        case 'calibrate':
            AF.startCalibrate();
            break;
        case 'stats':
            report();
            break;
    }
    report();
    return 'ok';
};

window.__autoFish = AF;
log('自动钓鱼引擎 v15 就绪 ' + location.href.slice(0, 80));
report();
})();
)AFJS";
}

@end
