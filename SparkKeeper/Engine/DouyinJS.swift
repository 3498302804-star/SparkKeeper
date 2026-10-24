import Foundation

/// 页面内注入的抖音创作者中心自动化脚本。
/// 选择器分三层递进：精确 class → 模糊 class → 文本兜底，任一命中即可。
enum DouyinJS {

    // MARK: - 核心工具库

    static let core = #"""
    (function () {
      if (window.__SK && window.__SK.version === 3) return "ok";
      const sleep = (ms) => new Promise(r => setTimeout(r, ms));
      const norm = (s) => (s || "").replace(/\s+/g, " ").trim();

      function visible(el) {
        if (!el) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
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

      function nameSpans() {
        const out = [];
        const sels = ['[class*="item-header-name-"]', '[class*="item-header-name"]', '[class*="conversation-item"] [class*="name"]'];
        for (const s of sels) {
          try {
            document.querySelectorAll(s).forEach(el => { if (visible(el) && norm(el.innerText)) out.push(el); });
          } catch (e) {}
        }
        // 去重
        const seen = new Set();
        return out.filter(el => {
          if (seen.has(el)) return false;
          seen.add(el);
          return true;
        });
      }

      function itemBox(span) {
        let el = span;
        for (let i = 0; i < 6 && el; i++) {
          const cls = (el.className || "").toString();
          if (/semi-list-item|conversation|session-item|chat-item/i.test(cls)) return el;
          el = el.parentElement;
        }
        return span.parentElement || span;
      }

      function scrollHost(el) {
        let p = el;
        for (let i = 0; i < 12 && p; i++) {
          if (p.scrollHeight > p.clientHeight + 40) {
            const cs = getComputedStyle(p);
            if (/(auto|scroll|overlay)/.test(cs.overflowY)) return p;
          }
          p = p.parentElement;
        }
        // 兜底：找页面里最高且可滚动的容器
        let best = null, bestH = 0;
        document.querySelectorAll("div,ul").forEach(d => {
          if (d.scrollHeight > d.clientHeight + 120 && d.clientHeight > 200) {
            const cs = getComputedStyle(d);
            if (/(auto|scroll|overlay)/.test(cs.overflowY) && d.scrollHeight > bestH) {
              bestH = d.scrollHeight; best = d;
            }
          }
        });
        return best;
      }

      function loginWall() {
        const txt = norm(document.body ? document.body.innerText : "");
        if (/扫码登录|登录后查看|请先登录|验证码登录|密码登录/.test(txt)) return true;
        if (pick(['[class*="login-panel"]', '[class*="login-modal"]', '[id*="login-container"]', '[class*="qrcode"]'])) return true;
        if (location.href.indexOf("/login") >= 0) return true;
        return false;
      }

      function editorEl() {
        return pick([
          '[class*="chat-input"] [contenteditable="true"]',
          '[class*="chat-input"] textarea',
          'div[contenteditable="true"][class*="editor"]',
          'div[contenteditable="true"]',
          'textarea'
        ]);
      }

      function fire(el, type, opts) {
        const ev = new (type.startsWith("key") ? KeyboardEvent : (type === "input" || type.startsWith("before") ? InputEvent : Event))(type, Object.assign({ bubbles: true, cancelable: true, composed: true }, opts || {}));
        el.dispatchEvent(ev);
      }

      function setText(el, text) {
        el.focus();
        const sel = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(false);
        sel.removeAllRanges();
        sel.addRange(range);
        let ok = false;
        try { ok = document.execCommand("insertText", false, text); } catch (e) { ok = false; }
        if (!ok || norm(el.innerText).length === 0) {
          el.innerText = text;
          fire(el, "input", { inputType: "insertText", data: text });
        }
        fire(el, "keyup", { key: " ", code: "Space" });
        return norm(el.innerText);
      }

      function sendButton() {
        const cands = Array.from(document.querySelectorAll('button, [role="button"], [class*="send"], span, div'))
          .filter(visible)
          .filter(el => /^(发送|Send|发 送)$/.test(norm(el.innerText)) && el.children.length <= 2);
        return cands[0] || null;
      }

      function pressEnter(el) {
        const base = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
        el.dispatchEvent(new KeyboardEvent("keydown", base));
        el.dispatchEvent(new KeyboardEvent("keypress", base));
        el.dispatchEvent(new KeyboardEvent("keyup", base));
      }

      const SK = {
        version: 3,
        sleep, norm, visible, pick, loginWall, editorEl, scrollHost, sendButton,

        async waitFor(fn, timeoutMs, stepMs) {
          const step = stepMs || 300;
          const t0 = Date.now();
          while (Date.now() - t0 < (timeoutMs || 20000)) {
            try { const v = fn(); if (v) return v; } catch (e) {}
            await sleep(step);
          }
          return null;
        },

        friends() {
          return nameSpans().map(el => norm(el.innerText));
        },

        findFriend(name) {
          const spans = nameSpans();
          const target = norm(name);
          if (!target) return null;
          let hit = spans.find(el => norm(el.innerText) === target);
          if (!hit) hit = spans.find(el => norm(el.innerText).indexOf(target) >= 0);
          if (!hit) hit = spans.find(el => target.indexOf(norm(el.innerText)) >= 0 && norm(el.innerText).length >= 2);
          return hit ? itemBox(hit) : null;
        },

        async scrollTo(name, maxScrolls) {
          const host0 = scrollHost(document.body);
          let found = SK.findFriend(name);
          if (found) return found;
          if (!host0) return null;
          for (let i = 0; i < (maxScrolls || 12); i++) {
            host0.scrollTop = host0.scrollTop + Math.max(400, host0.clientHeight * 0.9);
            await sleep(900);
            found = SK.findFriend(name);
            if (found) return found;
            const noMore = /没有更多|暂无更多|no more/i.test(norm(document.body.innerText));
            if (noMore && i > 1) break;
          }
          return SK.findFriend(name);
        },

        click(el) {
          if (!el) return false;
          try { el.scrollIntoView({ block: "center" }); } catch (e) {}
          const r = el.getBoundingClientRect();
          const opts = { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, view: window };
          ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach(t => {
            try {
              const Ctor = t.startsWith("pointer") ? (window.PointerEvent || MouseEvent) : MouseEvent;
              el.dispatchEvent(new Ctor(t, opts));
            } catch (e) {}
          });
          return true;
        },

        async openFriend(name, timeoutMs, maxScrolls) {
          if (SK.loginWall()) return { ok: false, reason: "login" };
          const box = await SK.scrollTo(name, maxScrolls);
          if (!box) return { ok: false, reason: "notfound", friends: SK.friends() };
          SK.click(box);
          const ed = await SK.waitFor(() => SK.editorEl(), timeoutMs || 20000);
          if (!ed) return { ok: false, reason: "noeditor" };
          await sleep(500);
          return { ok: true, editor: true };
        },

        async type(text) {
          const ed = await SK.waitFor(() => SK.editorEl(), 15000);
          if (!ed) return { ok: false, reason: "noeditor" };
          const got = setText(ed, text);
          await sleep(350);
          return { ok: got.length > 0, text: got };
        },

        async submit() {
          const ed = SK.editorEl();
          if (!ed) return { ok: false, reason: "noeditor" };
          const btn = SK.sendButton();
          if (btn) { SK.click(btn); await sleep(600); }
          pressEnter(ed);
          await sleep(1200);
          const left = ed ? norm(ed.innerText) : "";
          if (left.length === 0) return { ok: true, via: btn ? "button+enter" : "enter" };
          // 再补一次回车
          pressEnter(ed);
          await sleep(1200);
          const left2 = norm(ed.innerText);
          return { ok: left2.length === 0, via: "retry", leftover: left2.slice(0, 40) };
        },

        state() {
          return {
            url: location.href,
            title: document.title,
            login: SK.loginWall(),
            friends: SK.friends().slice(0, 40),
            editor: !!SK.editorEl()
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
    if (sk.loginWall()) return { ok: false, reason: "login" };
    const r = await sk.openFriend(name, timeoutMs, maxScrolls);
    if (!r.ok) return r;
    const t = await sk.type(message);
    if (!t.ok) return { ok: false, reason: "typefail", detail: t };
    return { ok: true, typed: t.text };
    """#

    static let submit = #"""
    const sk = window.__SK;
    if (!sk) return { ok: false, reason: "nocore" };
    const r = await sk.submit();
    return r;
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

    // MARK: - 诊断

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

    // 采样列表项 class，方便按真实 DOM 调选择器
    const classSet = new Set();
    document.querySelectorAll('[class*="list-item"], [class*="item-header"], [class*="conversation"], [class*="session"]').forEach(el => {
      String(el.className || "").split(/\s+/).forEach(c => {
        if (/item|name|header|session|chat|conversation/i.test(c)) classSet.add(c);
      });
    });

    const btns = Array.from(document.querySelectorAll('button, [role="button"]'))
      .filter(vis).map(b => norm(b.innerText)).filter(t => t && t.length < 12).slice(0, 20);

    return {
      url: location.href,
      title: document.title,
      login: sk ? sk.loginWall() : false,
      editor: sk ? !!sk.editorEl() : false,
      names: sk ? sk.friends().slice(0, 60) : [],
      classes: Array.from(classSet).slice(0, 40),
      buttons: btns,
      scrollable: sk ? (() => { const h = sk.scrollHost(document.body); return h ? (h.className || "div") : "none"; })() : "none",
      text: (document.body ? document.body.innerText : "").slice(0, 600)
    };
    """#
}
