import Foundation
import UIKit

/// 一次「续火花」的执行体：账号 → 好友 → 输入 → 发送。
@MainActor
final class SparkRunner {

    static let shared = SparkRunner()
    private init() {}

    private var busy = false

    // MARK: - 入口

    /// - Parameters:
    ///   - onlyAccount: 只跑指定账号（手动触发时用），nil 表示全部启用的账号
    ///   - force: 忽略「今天已经成功过」的判断
    func run(onlyAccount: UUID? = nil, force: Bool = true) async {
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
            Notifier.post(title: "火花助手", body: "没有可用账号或目标好友")
            return
        }

        for acc in targets {
            if Task.isCancelled { break }
            if !force, let last = acc.lastRun,
               Calendar.current.isDateInToday(last),
               acc.lastResult.hasPrefix("成功") {
                store.log("账号 \(acc.title) 今天已完成，跳过")
                continue
            }
            await runAccount(acc, settings: settings)
        }
        store.log("===== 执行结束 =====")
        notifierSummary()
    }

    // MARK: - 单账号

    private func runAccount(_ acc: Account, settings: AppSettings) async {
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
            if (probe["login"] as? Bool) == true {
                store.update(acc.id) { $0.needLogin = true; $0.lastResult = "登录失效" }
                store.log("  登录态失效，需在 App 内重新扫码登录")
                Notifier.post(title: "火花助手", body: "\(acc.title) 登录已失效，请打开 App 重新登录")
                return
            }

            try await session.load(settings.chatURL)
            await session.injectCore()
            _ = try? await session.js("""
            if (!window.__SK) return false;
            await window.__SK.waitFor(() => window.__SK.friends().length > 0, 15000);
            return true;
            """)

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
            var failNames: [String] = []
            let list = Array(acc.targets.filter(\.enabled).prefix(max(1, settings.maxTargetsPerRun)))

            for t in list {
                if Task.isCancelled { break }
                let msg = store.buildMessage(account: acc.title, target: t.name)
                store.log("  · 目标 \(t.name)")
                var ok = false
                var detail = ""

                for attempt in 1...2 {
                    do {
                        try await session.load(settings.chatURL)
                        await session.injectCore()
                        let res = await session.jsObject(DouyinJS.openAndType, args: [
                            "name": t.name,
                            "message": msg,
                            "timeoutMs": settings.perTargetTimeout * 1000,
                            "maxScrolls": settings.maxScrolls
                        ])

                        let opened = (res["ok"] as? Bool) ?? false
                        if !opened {
                            let reason = (res["reason"] as? String) ?? "unknown"
                            detail = "打开失败:\(reason)"
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
                            if (e) { e.innerText = ""; }
                            return true;
                            """)
                        } else {
                            let sr = await session.jsObject(DouyinJS.submit)
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

            let stamp = "成功 \(okCount)/\(list.count)"
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
        store.update(id) { a in
            a.cookies = cookies
            a.needLogin = wall
            a.lastResult = wall ? "登录失效" : "登录正常"
        }
        store.log(wall ? "登录状态：失效" : "登录状态：正常（\(cookies.count) 条 Cookie）")
    }
}
