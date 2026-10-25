import Foundation

/// 页面内注入的抖音创作者中心自动化脚本。
///
/// v4 设计原则：**不再依赖任何 CSS Modules 哈希类名**。
/// 会话行靠「几何位置 + 文本内容」的结构特征识别，输入框靠「右栏 + 最靠下」，
/// 发送键靠「文本 / aria-label / 尺寸最小」多路兜底。任何一处失效都有下一层接住。
enum DouyinJS {

    // MARK: - 核心工具库

    static let core = #"""
    (function () {
      if (window.__SK && window.__SK.version === 5) return "ok";

      const sleep = (ms) => new Promise(r => setTimeout(r, ms));
      const norm = (s) => (s || "").replace(/\s+/g, " ").trim();
      // 用户手填的名字和左栏显示的昵称经常差装饰：emoji、零宽、全角空格、
      // 「·」分隔符、"已读"角标之类。只留字母数字汉字再做一次比较。
      // 用 RegExp 构造而不是字面量：\p{...} 万一不被支持会变成语法错误，构造式能兜底。
      const TIGHT_RE = (function () {
        try { return new RegExp("[^\\p{L}\\p{N}]", "gu"); }
        catch (e) { return new RegExp("[^0-9A-Za-z\\u4e00-\\u9fa5]", "g"); }
      })();
      const tight = (s) => (s || "").replace(TIGHT_RE, "").toLowerCase();
      const vw = () => window.innerWidth || document.documentElement.clientWidth || 1280;
      const vh = () => window.innerHeight || document.documentElement.clientHeight || 820;

      // 时间戳 / 相对时间，不是人名
      const JUNK = /^(\d{1,2}:\d{2}|昨天|前天|刚刚|\d+\s*(秒|分钟|小时|天|周|个月)前|周[一二三四五六日]|\d{4}[-/]\d{1,2}[-/]\d{1,2})$/;
      const BTN = /^(发送|发 送|send|Send|SEND)$/;

      function rect(el) { try { return el.getBoundingClientRect(); } catch (e) { return null; } }

      function visible(el) {
        if (!el) return false;
        const r = rect(el);
        if (!r || r.width < 2 || r.height < 2) return false;
        const cs = getComputedStyle(el);
        return cs.visibility !== "hidden" && cs.display !== "none" && cs.opacity !== "0";
      }

      function pick(selectors, root) {
        const scope = root || document;
        for (const s of selectors) {
          let list = [];
          try { list = Array.from(scope.querySelectorAll(s)); } catch (e) { continue; }
          const hit = list.find(visible);
          if (hit) return hit;
        }
        return null;
      }

      // textarea / input 用 value，其余用 innerText
      function readText(el) {
        if (!el) return "";
        const tag = (el.tagName || "").toUpperCase();
        if (tag === "TEXTAREA" || tag === "INPUT") return norm(el.value);
        return norm(el.innerText || el.textContent || "");
      }

      // 左栏「叶子文本块」：完全不看 class，只看几何 + 文本
      function leftLeaves() {
        const out = [];
        const root = document.body;
        if (!root) return out;
        const lim = vw() * 0.62;
        const all = root.querySelectorAll("*");
        for (let i = 0; i < all.length; i++) {
          const el = all[i];
          if (el.children.length > 2) continue;
          const r = rect(el);
          if (!r || r.width < 20 || r.height < 12 || r.height > 170) continue;
          if (r.left > lim) continue;
          const t = norm(el.textContent);
          if (!t || t.length > 40) continue;
          out.push({ el: el, t: t, r: r });
        }
        return out;
      }

      function findNameEl(name) {
        const target = norm(name);
        if (!target) return null;
        const tg = tight(target);
        const cands = leftLeaves();
        const hits = [];
        for (let i = 0; i < cands.length; i++) {
          const c = cands[i];
          if (JUNK.test(c.t)) continue;
          const ct = tight(c.t);
          let s = 0;
          if (c.t === target) s = 5;
          else if (tg && tg.length >= 1 && ct === tg) s = 4;          // 只差装饰符号
          else if (c.t.length >= 2 && c.t.indexOf(target) >= 0) s = 3; // 名字里带角标
          else if (tg && tg.length >= 2 && ct.indexOf(tg) >= 0) s = 3;
          else if (target.indexOf(c.t) >= 0 && c.t.length >= 2) s = 2;
          else if (tg && ct.length >= 2 && tg.indexOf(ct) >= 0) s = 2;
          if (s > 0) hits.push({ el: c.el, r: c.r, s: s });
        }
        if (!hits.length) return null;
        hits.sort(function (a, b) {
          if (b.s !== a.s) return b.s - a.s;
          return (a.r.width * a.r.height) - (b.r.width * b.r.height);
        });
        return hits[0].el;
      }

      // 从名字叶子往上找点击行
      function rowOf(el) {
        let p = el, fallback = el;
        for (let i = 0; i < 10 && p && p !== document.body; i++) {
          const r = rect(p);
          if (r && r.height >= 36 && r.height <= 140 && r.width >= 140) fallback = p;
          if (r && r.height >= 28 && r.width >= 100) {
            const cls = String(p.className || "");
            const cs = getComputedStyle(p);
            const clickable = cs.cursor === "pointer"
              || p.getAttribute("role") === "button"
              || p.tagName === "LI"
              || /list-item|conversation|session|chat-item|conv-item/i.test(cls);
            if (clickable) return p;
          }
          p = p.parentElement;
        }
        return fallback;
      }

      function scrollHost() {
        let best = null, bestH = 0;
        const all = document.querySelectorAll("div,ul,section,main");
        for (let i = 0; i < all.length; i++) {
          const d = all[i];
          if (d.scrollHeight <= d.clientHeight + 60) continue;
          if (d.clientHeight < 120) continue;
          const r = rect(d);
          if (!r || r.left > vw() * 0.62) continue;
          const cs = getComputedStyle(d);
          if (!/(auto|scroll|overlay)/.test(cs.overflowY)) continue;
          if (d.scrollHeight > bestH) { bestH = d.scrollHeight; best = d; }
        }
        return best;
      }

      // iframe 里的内容 querySelectorAll 看不到，先探测出来给诊断用
      function frameCount() {
        try { return document.querySelectorAll("iframe").length; } catch (e) { return 0; }
      }

      function bodyText() {
        return norm(document.body ? document.body.innerText : "");
      }

      function loginWall() {
        if (/\/login|passport\.|\/passport/i.test(location.href)) return true;
        const qr = pick(['[class*="qrcode"]', '[class*="qr-code"]', '[class*="login-panel"]', '[class*="login-modal"]']);
        if (qr) {
          const r = rect(qr);
          if (r && r.width > 80 && r.height > 80) return true;
        }
        // 已经有会话行 / 输入框 ⇒ 肯定登录了，早退避免误判
        if (leftLeaves().length > 3) return false;
        if (editorEl()) return false;
        const txt = bodyText();
        if (/扫码登录|登录后查看|请先登录/.test(txt)) return true;
        return false;
      }

      function editors() {
        let list = [];
        try {
          list = Array.from(document.querySelectorAll('[contenteditable]:not([contenteditable="false"]),textarea,[role="textbox"]'));
        } catch (e) { list = []; }
        return list.filter(function (el) {
          if (!visible(el)) return false;
          const r = rect(el);
          return r && r.height >= 18 && r.width >= 60;
        });
      }

      // 输入框：优先右栏，其次屏幕最靠下的那个（聊天输入框永远贴着底部）
      function editorEl() {
        const list = editors();
        if (!list.length) return null;
        const lim = vw() * 0.24;
        const right = list.filter(function (el) { const r = rect(el); return r && r.left >= lim; });
        const pool = right.length ? right : list;
        pool.sort(function (a, b) { return rect(b).top - rect(a).top; });
        return pool[0];
      }

      function setText(el, text) {
        if (!el) return "";
        try { el.focus(); } catch (e) {}
        const tag = (el.tagName || "").toUpperCase();
        if (tag === "TEXTAREA" || tag === "INPUT") {
          try {
            const proto = tag === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
            setter.call(el, text);
          } catch (e) { try { el.value = text; } catch (e2) {} }
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return readText(el);
        }
        try {
          const sel = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(el);
          range.collapse(false);
          sel.removeAllRanges();
          sel.addRange(range);
        } catch (e) {}
        let ok = false;
        try { ok = document.execCommand("insertText", false, text); } catch (e) { ok = false; }
        if (!ok || readText(el).length === 0) {
          try { el.textContent = text; } catch (e) {}
          try { el.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text })); } catch (e) {}
          try { el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text })); } catch (e) {}
          try { el.dispatchEvent(new Event("change", { bubbles: true })); } catch (e) {}
        }
        try { el.dispatchEvent(new Event("keyup", { bubbles: true })); } catch (e) {}
        return readText(el);
      }

      // 发送键：文本 / aria-label / title 三路，取面积最小的那个（最像按钮）
      function sendButton() {
        const all = document.querySelectorAll('button,[role="button"],div,span,a');
        const hits = [];
        for (let i = 0; i < all.length; i++) {
          const el = all[i];
          if (!visible(el)) continue;
          const r = rect(el);
          if (!r || r.width < 12 || r.height < 12) continue;
          if (r.top < 40) continue;
          const t = norm(el.innerText);
          const aria = norm(el.getAttribute("aria-label")) + " " + norm(el.getAttribute("title"));
          const byText = t.length > 0 && t.length <= 8 && BTN.test(t) && el.children.length <= 3;
          const byAria = /发送|send/i.test(aria) && aria.length <= 16;
          if (!byText && !byAria) continue;
          hits.push({ el: el, area: r.width * r.height });
        }
        if (!hits.length) return null;
        hits.sort(function (a, b) { return a.area - b.area; });
        return hits[0].el;
      }

      function pressEnter(el) {
        const base = { key: "Enter", code: "Enter", bubbles: true, cancelable: true, composed: true };
        ["keydown", "keypress", "keyup"].forEach(function (t) {
          let ev;
          try { ev = new KeyboardEvent(t, base); } catch (e) { return; }
          try { Object.defineProperty(ev, "keyCode", { get: function () { return 13; } }); } catch (e) {}
          try { Object.defineProperty(ev, "which", { get: function () { return 13; } }); } catch (e) {}
          try { el.dispatchEvent(ev); } catch (e) {}
        });
      }

      function click(el) {
        if (!el) return false;
        try { el.scrollIntoView({ block: "center" }); } catch (e) {}
        const r = rect(el);
        if (!r) return false;
        const x = Math.round(r.left + Math.min(r.width / 2, 60));
        const y = Math.round(r.top + r.height / 2);
        let target = el;
        try { target = document.elementFromPoint(x, y) || el; } catch (e) { target = el; }
        const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0 };
        ["pointerover", "pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach(function (t) {
          try {
            const Ctor = t.indexOf("pointer") === 0 ? (window.PointerEvent || window.MouseEvent) : window.MouseEvent;
            target.dispatchEvent(new Ctor(t, opts));
          } catch (e) {}
        });
        if (target !== el) {
          try { el.dispatchEvent(new window.MouseEvent("click", opts)); } catch (e) {}
        }
        return true;
      }

      // 右栏顶部的会话标题，用于确认「确实点开了这个人」
      function header() {
        const out = [];
        const all = document.querySelectorAll("div,span,h1,h2,h3,p");
        const lim = vw() * 0.24;
        for (let i = 0; i < all.length; i++) {
          const el = all[i];
          if (el.children.length > 2) continue;
          const r = rect(el);
          if (!r || r.top > 140 || r.left < lim) continue;
          const t = norm(el.textContent);
          if (!t || t.length > 30) continue;
          out.push(t);
        }
        return out.slice(0, 4).join(" | ");
      }

      function friends() {
        const seen = {};
        const out = [];
        const leaves = leftLeaves();
        for (let i = 0; i < leaves.length; i++) {
          const c = leaves[i];
          if (c.t.length > 24) continue;
          if (JUNK.test(c.t)) continue;
          if (BTN.test(c.t)) continue;
          let dup = false;
          for (let k = 0; k < c.el.children.length; k++) {
            if (norm(c.el.children[k].textContent) === c.t) { dup = true; break; }
          }
          if (dup) continue;
          if (seen[c.t]) continue;
          seen[c.t] = 1;
          out.push(c.t);
        }
        return out.slice(0, 80);
      }

      const SK = {
        version: 5,
        sleep: sleep, norm: norm, visible: visible, pick: pick, readText: readText,
        loginWall: loginWall, editorEl: editorEl, editors: editors,
        scrollHost: scrollHost, sendButton: sendButton, header: header,
        friends: friends,

        async waitFor(fn, timeoutMs, stepMs) {
          const step = stepMs || 300;
          const t0 = Date.now();
          while (Date.now() - t0 < (timeoutMs || 20000)) {
            try { const v = fn(); if (v) return v; } catch (e) {}
            await sleep(step);
          }
          return null;
        },

        findFriend(name) {
          const el = findNameEl(name);
          return el ? rowOf(el) : null;
        },

        leftNames() {
          return leftLeaves().map(function (c) { return c.t; }).slice(0, 80);
        },

        async scrollTo(name, maxScrolls) {
          let found = findNameEl(name);
          if (found) return rowOf(found);
          const host = scrollHost();
          if (!host) return null;
          for (let i = 0; i < (maxScrolls || 12); i++) {
            host.scrollTop = host.scrollTop + Math.max(300, host.clientHeight * 0.85);
            await sleep(800);
            found = findNameEl(name);
            if (found) return rowOf(found);
            if (i > 1 && /没有更多|暂无更多|no more/i.test(bodyText())) break;
          }
          found = findNameEl(name);
          return found ? rowOf(found) : null;
        },

        click: click,

        async openFriend(name, timeoutMs, maxScrolls) {
          if (loginWall()) return { ok: false, reason: "login" };
          const box = await SK.scrollTo(name, maxScrolls);
          if (!box) return { ok: false, reason: "notfound", friends: friends().slice(0, 12) };
          click(box);
          const ed = await SK.waitFor(function () { return editorEl(); }, timeoutMs || 20000);
          if (!ed) return { ok: false, reason: "noeditor", header: header(), friends: friends().slice(0, 12) };
          await sleep(700);
          return { ok: true, header: header() };
        },

        async type(text) {
          const ed = await SK.waitFor(function () { return editorEl(); }, 15000);
          if (!ed) return { ok: false, reason: "noeditor" };
          const got = setText(ed, text);
          await sleep(400);
          const again = readText(editorEl() || ed);
          return { ok: again.length > 0, text: again || got };
        },

        async submit() {
          const ed0 = editorEl();
          if (!ed0) return { ok: false, reason: "noeditor" };
          if (readText(ed0).length === 0) return { ok: false, reason: "empty" };
          const cleared = function () { return readText(editorEl() || ed0).length === 0; };

          let btn = sendButton();
          if (btn) {
            click(btn);
            await sleep(900);
            if (cleared()) return { ok: true, via: "button" };
          }

          pressEnter(ed0);
          await sleep(1200);
          if (cleared()) return { ok: true, via: btn ? "button+enter" : "enter" };

          btn = sendButton();
          if (btn) {
            click(btn);
            await sleep(1300);
            if (cleared()) return { ok: true, via: "button2" };
          }

          pressEnter(ed0);
          await sleep(1500);
          if (cleared()) return { ok: true, via: "enter2" };

          return { ok: false, reason: "unsent", leftover: readText(editorEl() || ed0).slice(0, 40) };
        },

        state() {
          return {
            url: location.href,
            title: document.title,
            login: loginWall(),
            editor: !!editorEl(),
            editorCount: editors().length,
            header: header(),
            friends: friends().slice(0, 40),
            frames: frameCount(),
            focus: document.hasFocus(),
            vw: vw(),
            vh: vh()
          };
        }
      };

      window.__SK = SK;
      return "ok";
    })();
    """#

    // MARK: - 打开好友并输入

    static let openAndType = #"""
    const sk = window.__SK;
    if (!sk) return { ok: false, reason: "nocore" };
    if (sk.loginWall()) return { ok: false, reason: "login", url: location.href };
    const r = await sk.openFriend(name, timeoutMs, maxScrolls);
    if (!r.ok) return r;
    const t = await sk.type(message);
    if (!t.ok) return { ok: false, reason: "typefail", detail: t, header: r.header };
    return { ok: true, typed: t.text, header: r.header };
    """#

    static let submit = #"""
    const sk = window.__SK;
    if (!sk) return { ok: false, reason: "nocore" };
    return await sk.submit();
    """#

    static let state = #"""
    const sk = window.__SK;
    if (!sk) return { url: location.href, login: false, friends: [], editor: false };
    return sk.state();
    """#

    static let probeLogin = #"""
    const sk = window.__SK;
    if (!sk) return { login: false, url: location.href };
    return { login: sk.loginWall(), url: location.href, title: document.title };
    """#

    // MARK: - 诊断：把页面真实结构摊开，方便一次定位是 iframe / URL / 选择器哪一层坏了

    static let diagnose = #"""
    const sk = window.__SK;
    const norm = (s) => (s || "").replace(/\s+/g, " ").trim();
    const vis = (el) => {
      if (!el) return false;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return false;
      const cs = getComputedStyle(el);
      return cs.visibility !== "hidden" && cs.display !== "none";
    };
    const out = {
      url: location.href,
      title: document.title,
      vw: window.innerWidth || 0,
      vh: window.innerHeight || 0,
      focus: document.hasFocus(),
      frames: document.querySelectorAll("iframe").length,
      framesSrc: [],
      login: false,
      editor: false,
      names: [],
      buttons: [],
      editors: [],
      chains: [],
      leftHtml: "",
      text: ""
    };

    try {
      document.querySelectorAll("iframe").forEach(function (f) {
        if (out.framesSrc.length < 5) out.framesSrc.push(norm(f.src).slice(0, 120));
      });
    } catch (e) {}

    if (sk) {
      out.login = sk.loginWall();
      out.editor = !!sk.editorEl();
      out.names = sk.friends().slice(0, 60);
      out.buttons = Array.from(document.querySelectorAll('button,[role="button"]'))
        .filter(vis)
        .map(function (b) { return norm(b.innerText) || norm(b.getAttribute("aria-label")); })
        .filter(function (t) { return t && t.length < 16; })
        .slice(0, 24);
      out.editors = document.querySelectorAll('[contenteditable],textarea,[role="textbox"]').length;

      // 前 3 个会话名的祖先链，用来确认「点哪一层才是行」
      const seen = {};
      for (const el of document.querySelectorAll("div,span,a,li")) {
        if (el.children.length > 1) continue;
        const t = norm(el.textContent);
        if (!t || t.length > 20 || seen[t]) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2 || r.top > 900 || r.left > window.innerWidth * 0.62) continue;
        seen[t] = 1;
        const chain = [];
        let p = el;
        for (let i = 0; i < 7 && p && p !== document.body; i++) {
          const rr = p.getBoundingClientRect();
          chain.push(p.tagName + "." + String(p.className || "").split(/\s+/).slice(0, 2).join(".") + "[" + Math.round(rr.width) + "x" + Math.round(rr.height) + "]");
          p = p.parentElement;
        }
        out.chains.push(t + "  =>  " + chain.join(" < "));
        if (out.chains.length >= 3) break;
      }

      // 左栏前 1500 字符的 HTML，直接看出真实类名结构
      let leftRoot = null, leftArea = 0;
      document.querySelectorAll("div,ul,aside").forEach(function (d) {
        const r = d.getBoundingClientRect();
        if (r.width < 100 || r.height < 200) return;
        if (r.left > window.innerWidth * 0.62) return;
        if (d.getElementsByTagName("img").length === 0) return;
        const a = r.width * r.height;
        if (a > leftArea) { leftArea = a; leftRoot = d; }
      });
      if (leftRoot) out.leftHtml = leftRoot.outerHTML.replace(/\s+/g, " ").slice(0, 1500);
    }

    out.text = (document.body ? document.body.innerText : "").replace(/[ \t]+/g, " ").slice(0, 800);
    return out;
    """#
}
