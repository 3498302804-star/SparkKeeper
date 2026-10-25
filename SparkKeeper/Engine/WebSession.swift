import Foundation
import WebKit
import UIKit
import CoreFoundation

/// 全局唯一的隐藏 WKWebView 会话：登录、抓好友、发送共用同一个持久化数据容器。
///
/// 说明：脚本执行走自建的 Promise 桥（evaluateJavaScript + 轮询），不依赖
/// `callAsyncJavaScript` 的标签签名，任何 Xcode 15/16 SDK 都能直接编译。
@MainActor
final class WebSession {

    static let shared = WebSession()

    /// 桌面版 UA，保证拿到 creator.douyin.com 的桌面 DOM
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private(set) var webView: WKWebView!
    /// 隐藏宿主容器：挂在 key window 的根视图最底层，保证 WebKit 认为它「在屏」
    private weak var hostView: UIView?

    init() {
        webView = WKWebView(frame: WebSession.canvas, configuration: WebSession.makeConfiguration())
        webView.customUserAgent = WebSession.desktopUA
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
    }

    /// 离屏画布尺寸：不能是 zero-size，否则 WebKit 会跳过渲染与脚本调度。
    /// 用 1280 宽是为了逼抖音走「桌面双栏」布局——列表在左、聊天在右，
    /// 窄屏（460）会退化成单栏，DOM 结构完全不同，自动化选择器全对不上。
    private static let canvas = CGRect(x: 0, y: 0, width: 1280, height: 820)

    /// 每次新建 webView 都必须配一份全新的 configuration。
    /// 同一个 WKWebViewConfiguration 实例被第二个 WKWebView 复用会抛
    /// "already used to create a WebView" 异常直接崩溃。
    private static func makeConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        return cfg
    }

    // MARK: - 隐藏宿主

    /// 保证 webView 有一个「在窗口里」的宿主容器。
    ///
    /// 关键：只在 webView **没有任何 superview** 时才挂上去，绝不从登录页的
    /// 可见容器里把它抢走。旧实现 `present()` → `ensureOffscreenWindow()` →
    /// `embed(into: vc.view)` 会在用户刚打开登录 sheet 时把 WebView 搬进一个
    /// `windowLevel = -1000`、`alpha = 0.02`、从不 makeKey 的窗口，结果就是
    /// 登录页白屏 + `document.hasFocus()` 恒为 false + `execCommand` 全部失败。
    @discardableResult
    private func ensureHost() -> Bool {
        if let h = hostView, h.window != nil {
            if webView.superview == nil { embed(into: h) }
            return true
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            Store.shared.log("找不到 windowScene，WebView 无法挂载")
            return false
        }
        guard let keyWin = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = keyWin.rootViewController?.view else {
            Store.shared.log("找不到 key window，WebView 无法挂载")
            return false
        }
        let host = UIView(frame: WebSession.canvas)
        host.backgroundColor = .clear
        host.alpha = 0.02
        host.isUserInteractionEnabled = false
        host.clipsToBounds = true
        root.insertSubview(host, at: 0)
        hostView = host
        if webView.superview == nil { embed(into: host) }
        return true
    }

    /// 把 webView 嵌入给定容器（登录页会调用）
    func embed(into container: UIView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        pin(webView, to: container)
    }

    /// 登录页出现时调用：刻意留空。
    /// 登录全程 WebView 必须留在用户看得见的 sheet 容器里。
    func present() {}

    /// 登录页关闭后：放回隐藏宿主，保持会话存活
    func detachBackToOffscreen() {
        guard let host = hostView, host.window != nil else { return }
        embed(into: host)
    }

    private func pin(_ child: UIView, to host: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            child.topAnchor.constraint(equalTo: host.topAnchor),
            child.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    // MARK: - 导航

    /// 最近一次导航结束后的真实 URL（可能被重定向，和请求的 URL 不同）
    private(set) var lastLoadedURL: String = ""

    func load(_ urlString: String, timeout: TimeInterval = 40) async throws {
        guard let url = URL(string: urlString), url.scheme != nil else { throw SparkError.badURL }
        guard ensureHost() else { throw SparkError.js("webview-no-host") }
        let before = webView.url?.absoluteString
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        webView.load(req)

        let t0 = Date()
        // 阶段一：等导航真正开始（load() 返回后 isLoading 有一小段还是 false，
        // 直接判 isLoading 会瞬间跳出，后续脚本全打在旧页面上）
        while Date().timeIntervalSince(t0) < 8 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if webView.isLoading { break }
            if let u = webView.url?.absoluteString, u != before, !webView.isLoading { break }
        }
        // 阶段二：等加载结束
        while Date().timeIntervalSince(t0) < timeout {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !webView.isLoading { break }
        }
        // 给前端框架留出首屏渲染时间
        try await Task.sleep(nanoseconds: 1_500_000_000)
        lastLoadedURL = webView.url?.absoluteString ?? ""
    }

    func reload() async {
        webView.reload()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    // MARK: - JS 桥

    /// 在页面世界执行一段 async JS（body 内可直接写 await / return）。
    /// - Parameters:
    ///   - body: 异步函数体
    ///   - args: 以 `const 名字 = 值;` 预置到函数体内的变量表
    func js(_ body: String, args: [String: Any] = [:]) async throws -> Any? {
        let token = UUID().uuidString
        let decls = args.keys.sorted().compactMap { key -> String? in
            guard let lit = WebSession.jsonLiteral(args[key]) else { return nil }
            return "const \(key) = \(lit);"
        }.joined(separator: "\n")

        let kickoff = """
        (function () {
          window.__skJobs = window.__skJobs || {};
          const job = { done: false, result: null, error: null };
          window.__skJobs["\(token)"] = job;
          (async function () {
            \(decls)
            try {
              const r = await (async function () { \(body) }).call(window);
              job.result = (r === undefined) ? null : r;
            } catch (e) {
              job.error = String((e && e.message) ? e.message : e);
            }
            job.done = true;
          })();
          return true;
        })();
        """
        _ = try? await webView.evaluateJavaScript(kickoff)

        let probe = """
        (function () {
          const j = (window.__skJobs || {})["\(token)"];
          if (!j) return JSON.stringify({ d: true, e: "job-missing", r: null });
          const out = { d: !!j.done, e: j.error || null, r: null };
          if (j.done && !j.error) {
            try { out.r = (j.result === undefined) ? null : j.result; } catch (err) { out.r = null; }
          }
          return JSON.stringify(out);
        })();
        """

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let raw = try? await webView.evaluateJavaScript(probe)
            if let s = raw as? String,
               let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let done = (obj["d"] as? Bool) ?? false
                if done {
                    cleanup(token)
                    if let err = obj["e"] as? String, !err.isEmpty {
                        throw SparkError.js(err)
                    }
                    return obj["r"]
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        cleanup(token)
        throw SparkError.timeout("JS 执行超时")
    }

    private func cleanup(_ token: String) {
        webView.evaluateJavaScript("(function(){ try { delete window.__skJobs['\(token)']; } catch(e){} return true; })();",
                                   completionHandler: nil)
    }

    /// 把 Swift 值转成 JS 字面量
    static func jsonLiteral(_ value: Any?) -> String? {
        guard let value else { return "null" }
        if value is NSNull { return "null" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return encodeString(s) }
        if let arr = value as? [Any] {
            let items = arr.compactMap { jsonLiteral($0) }
            return "[" + items.joined(separator: ",") + "]"
        }
        if let dict = value as? [String: Any] {
            let items = dict.keys.sorted().compactMap { k -> String? in
                guard let v = jsonLiteral(dict[k]) else { return nil }
                return encodeString(k) + ":" + v
            }
            return "{" + items.joined(separator: ",") + "}"
        }
        return encodeString("\(value)")
    }

    /// JSON 字符串编码（保证 JS 端不会踩到换行/引号）
    private static func encodeString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let json = String(data: data, encoding: .utf8) {
            // ["xxx"] → "xxx"
            let trimmed = json.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return trimmed.isEmpty ? "\"\"" : trimmed
        }
        return "\"\""
    }

    func jsObject(_ body: String, args: [String: Any] = [:]) async -> [String: Any] {
        let raw = try? await js(body, args: args)
        if let d = raw as? [String: Any] { return d }
        if let d = raw as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d { if let ks = k as? String { out[ks] = v } }
            return out
        }
        return [:]
    }

    /// 注入一次核心工具库（幂等）
    func injectCore() async {
        _ = try? await js(DouyinJS.core)
    }

    // MARK: - Cookie

    func exportCookies() async -> [StoredCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[StoredCookie], Never>) in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let list = cookies
                    .filter { $0.domain.contains("douyin.com") }
                    .map { c in
                        StoredCookie(name: c.name,
                                     value: c.value,
                                     domain: c.domain,
                                     path: c.path,
                                     expires: c.expiresDate?.timeIntervalSince1970 ?? 0,
                                     secure: c.isSecure)
                    }
                cont.resume(returning: list)
            }
        }
    }

    func importCookies(_ list: [StoredCookie]) async {
        guard !list.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in list {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name,
                .value: c.value,
                .domain: c.domain,
                .path: c.path.isEmpty ? "/" : c.path
            ]
            if c.expires > 0 { props[.expires] = Date(timeIntervalSince1970: c.expires) }
            if c.secure { props[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: props) else { continue }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { cont.resume() }
            }
        }
    }

    func wipeWebData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { (cont: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { cont.resume(returning: $0) }
        }
        let douyin = records.filter { $0.displayName.contains("douyin") }
        guard !douyin.isEmpty else { return }
        // removeData 只接受 (ofTypes:modifiedSince:)，没有按 record 定向删除的重载；
        // 抖音相关记录都在同一 data store 里，按 distantPast 全清即可。
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { cont.resume() }
        }
    }

    // MARK: - 崩溃自愈

    /// 检查 WebContent 进程是否还活着，死了就重建 webView 并重新登录态注入。
    func healIfNeeded() async {
        if webView == nil {
            rebuild()
            return
        }
        // 探针：evaluateJavaScript 返回 nil 说明进程已死
        let alive = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript("1+1") { _, err in
                cont.resume(returning: err == nil)
            }
        }
        if !alive {
            Store.shared.log("WebContent 已失效，重建 webView")
            rebuild()
        }
    }

    private func rebuild() {
        let fresh = WKWebView(frame: WebSession.canvas, configuration: WebSession.makeConfiguration())
        fresh.customUserAgent = WebSession.desktopUA
        fresh.allowsBackForwardNavigationGestures = false
        fresh.isOpaque = false
        fresh.backgroundColor = .clear
        webView = fresh
        if let host = hostView, host.window != nil {
            host.subviews.forEach { $0.removeFromSuperview() }
            embed(into: host)
        }
    }
}

enum SparkError: LocalizedError {
    case badURL
    case notLoggedIn
    case noTargets
    case timeout(String)
    case js(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL 无效"
        case .notLoggedIn: return "登录态失效，需要重新登录"
        case .noTargets: return "没有启用的目标好友"
        case .timeout(let s): return "超时：\(s)"
        case .js(let s): return "脚本错误：\(s)"
        }
    }
}
