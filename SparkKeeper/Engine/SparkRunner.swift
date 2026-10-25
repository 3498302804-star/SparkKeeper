import Foundation
import UIKit

/// 一次「续火花」的执行体：账号 → 好友 → 输入 → 发送。
@MainActor
final class SparkRunner {

    static let shared = SparkRunner()
    private init() {}

    /// 通知标题统一走这里，避免各处写死旧名字
    static let appName = "KA自动续火花"

    private var busy = false

    // MARK: - 入口

    /// - Parameters:
    ///   - onlyAccount: 只跑指定账号（手动触发时用），nil 表示全部启用的账号
    ///   - force: 忽略「今天已经成功过」的判断
    ///   - maxTargets: 本次最多处理多少个好友；后台被系统唤起时传小值，
    ///     因为 BGAppRefresh 只给约 30 秒，按默认 20 个根本跑不完。
    func run(onlyAccount: UUID? = nil, force: Bool = true, maxTargets: Int? = nil) async {
        guard !busy else {
            Store.shared.log("已有任务在跑，跳过本次触发")
            return
        }
        busy = true
        Store.shared.running = true
        defer {
            busy = false
            Store.shared.running = false
            Store.shared.save()
        }

        BackgroundKeeper.shared.begin()
        defer { BackgroundKeeper.shared.end() }

        let store = Store.shared
        store.log("===== 开始执行 =====")
        let settings = store.settings

        let targets = store.accounts.filter { acc in
            acc.enabled
                && (onlyAccount == nil || acc.id == onlyAccount)
                && !acc.targets.filter(\.enabled).isEmpty
        }

        guard !targets.isEmpty else {
            store.log("没有可用账号/目标，退出")
            Notifier.post(title: SparkRunner.appName, body: "没有可用账号或目标好友")
            return
        }

        for acc in targets {
            if Task.isCancelled { break }
            if !force, let last = acc.lastRun,
               Calendar.current.isDateInToday(last),
               acc.lastResult.hasPrefix("成功"),
               !acc.lastResult.contains("失败") {
                store.log("账号 \(acc.title) 今天已全部成功，跳过")
                continue
            }
            await runAccount(acc, settings: settings, maxTargets: maxTargets)
        }
        store.log("===== 执行结束 =====")
        notifierSummary()
    }

    // MARK: - 单账号

    /// 已经在私信页就不重新导航。
    /// 每次 reload 要 3–10 秒，十几个目标累加直接超时；而且 reload 会重置
    /// 列表滚动位置，等于把刚翻到的位置丢掉。
    private func loadChatIfNeeded(_ url: String) async throws {
        let session = WebSession.shared
        if session.lastLoadedURL.contains("/following/chat") {
            await session.injectCore()
            return
        }
        try await session.load(url)
        await session.injectCore()
    }

    private func runAccount(_ acc: Account, settings: AppSettings, maxTargets: Int? = nil) async {
        let store = Store.shared
        let session = WebSession.shared
        store.log("→ 账号 \(acc.title)")

        await session.healIfNeeded()

        if !acc.cookies.isEmpty {
            await session.importCookies(acc.cookies)
        }

        do {
            try await session.load(settings.homeURL)
            await session.injectCore()

            let probe = await session.jsObject(DouyinJS.probeLogin)
            let wall = (probe["login"] as? Bool) ?? false
            let early = await session.exportCookies()
            let hasTicket = early.contains { WebSession.sessionCookieNames.contains($0.name) }
            if wall && !hasTicket {
                store.update(acc.id) { $0.needLogin = true; $0.lastResult = "登录失效" }
                store.log("  登录态失效，需在 App 内重新扫码登录")
                Notifier.post(title: SparkRunner.appName, body: "\(acc.title) 登录已失效，请打开 App 重新登录")
                return
            }
            if wall {
                store.log("  页面结构像登录页，但 cookie 里有会话票据，继续往下走")
            }

            try await session.load(settings.chatURL)
            await session.injectCore()
            store.log("  私信页落点：\(session.lastLoadedURL)")

            let warmed = await session.jsObject("""
            if (!window.__SK) return { core: false, n: 0 };
            await window.__SK.waitFor(() => window.__SK.friends().length > 0, 15000);
            return { core: true, n: window.__SK.friends().length, url: location.href };
            """)
            let friendCount = (warmed["n"] as? Int) ?? 0
            store.log("  会话列表预热：核心库 \((warmed["core"] as? Bool) == true ? "ok" : "缺失")，识别到 \(friendCount) 个会话")

            let state = await session.jsObject(DouyinJS.state)
            if (state["login"] as? Bool) == true {
                store.update(acc.id) { $0.needLogin = true; $0.lastResult = "登录失效" }
                store.log("  私信页要求登录，需重新扫码")
                return
            }

            // 刷新 cookie 快照
            let cookies = await session.exportCookies()
            store.update(acc.id) { $0.cookies = cookies }

            var okCount = 0
            var skipCount = 0
            var failNames: [String] = []
            let cap = max(1, maxTargets ?? settings.maxTargetsPerRun)
            let list = Array(acc.targets.filter(\.enabled).prefix(cap))

            for t in list {
                if Task.isCancelled { break }

                // 今天已经发成功过的就不重发 —— 两次手动触发不该把同一条消息刷两遍
                if !force, t.lastOk, let sent = t.lastSent, Calendar.current.isDateInToday(sent) {
                    store.log("  · 目标 \(t.name) 今天已发过，跳过")
                    okCount += 1
                    skipCount += 1
                    continue
                }

                let msg = store.buildMessage(account: acc.title, target: t.name)
                store.log("  · 目标 \(t.name)")
                var ok = false
                var detail = ""

                for attempt in 1...2 {
                    do {
                        if attempt == 1 {
                            try await loadChatIfNeeded(settings.chatURL)
                        } else {
                            // 只有重试才真正重新导航
                            try await session.load(settings.chatURL)
                            await session.injectCore()
                        }
                        let res = await session.jsObject(DouyinJS.openAndType, args: [
                            "name": t.name,
                            "message": msg,
                            "timeoutMs": settings.perTargetTimeout * 1000,
                            "maxScrolls": settings.maxScrolls
                        ], timeout: Double(settings.perTargetTimeout) + 45)

                        let opened = (res["ok"] as? Bool) ?? false
                        if !opened {
                            let reason = (res["reason"] as? String) ?? "unknown"
                            detail = "打开失败:\(reason)"
                            if let h = res["header"] as? String, !h.isEmpty {
                                detail += " 会话头:\(String(h.prefix(30)))"
                            }
                            if reason == "login" {
                                store.update(acc.id) { $0.needLogin = true }
                                break
                            }
                            if let friends = res["friends"] as? [String], !friends.isEmpty, attempt == 2 {
                                detail += " 可见好友:" + friends.prefix(6).joined(separator: "/")
                            }
                        } else if settings.dryRun {
                            ok = true
                            detail = "演练：已输入未发送"
                            _ = try? await session.js("""
                            const e = window.__SK && window.__SK.editorEl();
                            if (e) {
                              if (e.tagName === "TEXTAREA" || e.tagName === "INPUT") { e.value = ""; }
                              else { e.innerText = ""; }
                            }
                            return true;
                            """, timeout: 20)
                        } else {
                            let sr = await session.jsObject(DouyinJS.submit, timeout: 30)
                            ok = (sr["ok"] as? Bool) ?? false
                            let via = (sr["via"] as? String) ?? "enter"
                            let leftover = (sr["leftover"] as? String) ?? ""
                            detail = ok ? "已发送(\(via))" : "发送未确认:\(leftover)"
                        }
                    } catch {
                        detail = "异常:\(error.localizedDescription)"
                    }

                    if ok { break }
                    if attempt == 1 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                }

                if ok { okCount += 1 } else { failNames.append(t.name) }

                store.update(acc.id) { a in
                    if let i = a.targets.firstIndex(where: { $0.id == t.id }) {
                        if ok { a.targets[i].lastSent = Date() }
                        a.targets[i].lastOk = ok
                    }
                }
                store.record(RunRecord(date: Date(), account: acc.title, target: t.name, ok: ok, detail: detail))
                store.log("    \(ok ? "✅" : "❌") \(detail)")

                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let stamp = skipCount > 0
                ? "成功 \(okCount)/\(list.count)（\(skipCount) 个今天已发过）"
                : "成功 \(okCount)/\(list.count)"
            store.update(acc.id) { a in
                a.lastRun = Date()
                a.lastResult = failNames.isEmpty
                    ? stamp
                    : stamp + " 失败:" + failNames.prefix(3).joined(separator: ",")
                if okCount > 0 { a.needLogin = false }
            }
            store.log("  账号结果：\(stamp)")
        } catch {
            store.update(acc.id) { $0.lastResult = "错误:\(error.localizedDescription)"; $0.lastRun = Date() }
            store.log("  账号异常：\(error.localizedDescription)")
        }
    }

    private func notifierSummary() {
        let store = Store.shared
        let today = store.history.filter { Calendar.current.isDateInToday($0.date) }
        guard !today.isEmpty else { return }
        let ok = today.filter(\.ok).count
        Notifier.post(title: "火花已续", body: "\(ok)/\(today.count) 个好友成功")
    }

    // MARK: - 登录辅助

    func refreshLoginState(for id: UUID) async {
        let store = Store.shared
        let session = WebSession.shared
        try? await session.load(store.settings.homeURL)
        await session.injectCore()
        let probe = await session.jsObject(DouyinJS.probeLogin)
        let wall = (probe["login"] as? Bool) ?? false
        let cookies = await session.exportCookies()
        // cookie 里有会话票据，比页面结构判定硬得多：创作者中心首页的结构经常被误判成登录墙
        let hasTicket = cookies.contains { WebSession.sessionCookieNames.contains($0.name) }
        let dead = wall && !hasTicket
        store.update(id) { a in
            a.cookies = cookies
            a.needLogin = dead
            a.lastResult = dead ? "登录失效" : "登录正常"
        }
        store.log(dead ? "登录状态：失效" : "登录状态：正常（\(cookies.count) 条 Cookie）")
    }
}
