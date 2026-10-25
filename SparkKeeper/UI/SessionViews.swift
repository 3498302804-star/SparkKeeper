import Foundation
import SwiftUI
import UIKit
import WebKit

// MARK: - 登录页（复用同一个 WKWebView）

struct LoginWebView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    /// 登录态要落到哪个账号；nil = 第一个账号
    var accountId: UUID? = nil

    @State private var reloadToken = UUID()
    @State private var busy = false

    /// 实际目标账号：显式传入优先，否则退回第一个
    private var targetId: UUID? {
        accountId ?? store.accounts.first?.id
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                WebContainer(reloadToken: reloadToken)
            }
            .navigationTitle("登录抖音创作者中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        WebSession.shared.detachBackToOffscreen()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        reloadToken = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "…" : "已登录") {
                        Task { await finishLogin() }
                    }
                    .disabled(busy)
                }
            }
            .onAppear {
                WebSession.shared.present()
                Task {
                    try? await WebSession.shared.load(store.settings.homeURL)
                }
            }
            .onDisappear {
                WebSession.shared.detachBackToOffscreen()
            }
        }
    }

    /// 只有真的拿到会话票据才落库。
    /// 旧实现一进来就 `exportCookies()`，用户还没扫码时导到的是游客 cookie，
    /// 覆盖写入后账号看着「已登录」，实际每次跑都撞登录墙。
    @MainActor
    private func finishLogin() async {
        busy = true
        defer { busy = false }

        let sessionNames: Set<String> = ["sessionid", "sessionid_ss", "sid_tt", "sid_guard", "passport_auth_status"]
        var cookies = await WebSession.shared.exportCookies()
        var ok = cookies.contains { sessionNames.contains($0.name) }

        if !ok {
            // 给一次机会：用户可能刚扫完码，票据还没落到 cookie store
            store.log("暂未拿到登录票据，等待 6 秒再取一次…")
            for _ in 0..<3 where !ok {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                cookies = await WebSession.shared.exportCookies()
                ok = cookies.contains { sessionNames.contains($0.name) }
            }
        }

        store.log("Cookie 共 \(cookies.count) 条，登录票据：\(ok ? "已取得" : "缺失")")
        guard ok else {
            store.log("还没检测到登录票据 —— 请先在页面上扫码登录成功，再点「完成登录」")
            return
        }

        var id = targetId
        if id == nil {
            id = store.addAccount(title: "主号", uniqueId: "")
            store.log("还没有账号，已自动创建「主号」")
        }
        if let id = id {
            store.update(id) { acc in
                acc.cookies = cookies
                acc.needLogin = false
            }
            await SparkRunner.shared.refreshLoginState(for: id)
        }

        WebSession.shared.detachBackToOffscreen()
        dismiss()
    }
}

struct WebContainer: UIViewRepresentable {
    let reloadToken: UUID

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .systemBackground
        WebSession.shared.embed(into: v)
        context.coordinator.lastToken = reloadToken
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        WebSession.shared.embed(into: uiView)
        // reloadToken 变化 = 用户点了右上角刷新，真正重新载入一次
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            WebSession.shared.present()
            Task { await WebSession.shared.reload() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken: UUID?
    }
}

// MARK: - 从私信列表抓取好友

struct FriendPickerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    let accountId: UUID

    @State private var names: [String] = []
    @State private var picked: Set<String> = []
    @State private var loading = false
    @State private var message = "正在读取私信列表…"

    var body: some View {
        NavigationView {
            List {
                Section {
                    if loading {
                        HStack { ProgressView(); Text(message).font(.footnote) }
                    } else if names.isEmpty {
                        Text(message).font(.footnote).foregroundColor(.secondary)
                    } else {
                        Button(picked.count == names.count ? "取消全选" : "全选") {
                            picked = picked.count == names.count ? [] : Set(names)
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("共 \(names.count) 个会话，已选 \(picked.count)")
                }

                Section {
                    ForEach(names, id: \.self) { n in
                        Button {
                            if picked.contains(n) { picked.remove(n) } else { picked.insert(n) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(n) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(picked.contains(n) ? .orange : .secondary)
                                Text(n).foregroundColor(.primary)
                                Spacer()
                                if existingNames.contains(n) {
                                    Text("已添加").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("抓取好友")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("加入列表") {
                        let add = picked.subtracting(existingNames)
                        store.update(accountId) { a in
                            for n in add.sorted() { a.targets.append(Target(name: n)) }
                        }
                        store.log("已添加 \(add.count) 个目标好友")
                        dismiss()
                    }
                    .disabled(picked.subtracting(existingNames).isEmpty)
                }
            }
            .task { await fetch() }
        }
    }

    @MainActor
    private var existingNames: Set<String> {
        Set(store.accounts.first { $0.id == accountId }?.targets.map(\.name) ?? [])
    }

    @MainActor
    private func fetch() async {
        loading = true
        let session = WebSession.shared
        try? await session.load(store.settings.chatURL, timeout: 45)
        await session.injectCore()
        _ = try? await session.js("""
        if (!window.__SK) return false;
        await window.__SK.waitFor(() => window.__SK.friends().length > 0, 20000);
        return true;
        """)

        let st = await session.jsObject(DouyinJS.state)
        if (st["login"] as? Bool) == true {
            message = "需要先登录：请到「登录抖音创作者中心」扫码"
            loading = false
            return
        }

        let maxScrolls = store.settings.maxScrolls
        let raw: Any? = try? await session.js("""
        const sk = window.__SK;
        if (!sk) return [];
        const seen = new Set();
        const out = [];
        const push = (arr) => arr.forEach(n => { if (n && !seen.has(n)) { seen.add(n); out.push(n); } });
        push(sk.friends());
        const host = sk.scrollHost(document.body);
        if (host) {
          for (let i = 0; i < maxScrolls; i++) {
            host.scrollTop = host.scrollTop + Math.max(400, host.clientHeight * 0.9);
            await sk.sleep(700);
            push(sk.friends());
            if (/没有更多|暂无更多|no more/i.test(document.body.innerText) && i > 1) break;
          }
        }
        return out.slice(0, 300);
        """, args: ["maxScrolls": maxScrolls])

        var list: [String] = []
        if let a = raw as? [String] { list = a }
        else if let a = raw as? [Any] { list = a.compactMap { $0 as? String } }

        names = list
        if names.isEmpty {
            message = "没读到会话列表。先用右上角「诊断」确认私信页能否打开。"
        }
        loading = false
    }
}

// MARK: - 诊断：把页面真实 DOM 情况摊开看

struct DiagnosticsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    @State private var report = "点右上角「开始」读取当前页面"
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("页面诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button(copied ? "已复制" : "复制") {
                            UIPasteboard.general.string = report
                            copied = true
                            store.log("诊断结果已复制到剪贴板")
                        }
                        .disabled(busy)
                        Button(busy ? "…" : "开始") { Task { await run() } }
                            .disabled(busy)
                    }
                }
            }
        }
    }

    // 安全取值，避免 Optional 打印成 "Optional(...)"
    private func str(_ v: Any?) -> String {
        if let s = v as? String, !s.isEmpty { return s }
        return "-"
    }

    private func num(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }

    private func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    private func list(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { $0 as? String } ?? []
    }

    @MainActor
    private func run() async {
        busy = true
        copied = false
        defer { busy = false }

        let session = WebSession.shared
        var out: [String] = ["=== 载入 ==="]
        out.append("请求：\(store.settings.chatURL)")
        do {
            try await session.load(store.settings.chatURL, timeout: 45)
        } catch {
            out.append("载入失败：\(error.localizedDescription)")
        }
        out.append("落点：\(session.lastLoadedURL)")
        await session.injectCore()

        let info = await session.jsObject(DouyinJS.diagnose)
        if info.isEmpty {
            out.append("")
            out.append("脚本没返回数据 —— WebContent 可能已崩，或页面在跨域 iframe 里")
            report = out.joined(separator: "\n")
            return
        }

        out.append("")
        out.append("=== 页面 ===")
        out.append("URL：\(str(info["url"]))")
        out.append("标题：\(str(info["title"]))")
        out.append("视口：\(num(info["vw"])) × \(num(info["vh"]))")
        out.append("hasFocus：\(bool(info["focus"]))")
        out.append("iframe：\(num(info["frames"])) 个")
        let frameSrcs = list(info["framesSrc"])
        if !frameSrcs.isEmpty {
            out.append(contentsOf: frameSrcs.map { "  src: \($0)" })
        }

        out.append("")
        out.append("=== 判定 ===")
        out.append("登录墙：\(bool(info["login"]) ? "是（会直接中止）" : "否")")
        out.append("输入框：\(bool(info["editor"]) ? "已找到" : "没找到")")
        out.append("可编辑元素总数：\(num(info["editors"]))")

        let names = list(info["names"])
        out.append("")
        out.append("=== 会话名（\(names.count) 个） ===")
        if names.isEmpty {
            out.append("（一个都没识别到 —— 左栏结构或滚动容器不匹配）")
        } else {
            out.append(contentsOf: names.prefix(40).map { "  · \($0)" })
        }

        let btns = list(info["buttons"])
        out.append("")
        out.append("=== 可见按钮（\(btns.count) 个） ===")
        out.append(btns.isEmpty ? "（无）" : btns.prefix(24).joined(separator: " | "))

        let chains = list(info["chains"])
        if !chains.isEmpty {
            out.append("")
            out.append("=== 会话行祖先链 ===")
            out.append(contentsOf: chains.map { "  \($0)" })
        }

        let html = str(info["leftHtml"])
        if html != "-" {
            out.append("")
            out.append("=== 左栏 HTML（前 1500 字） ===")
            out.append(html)
        }

        out.append("")
        out.append("=== 正文前 800 字 ===")
        out.append(str(info["text"]))

        report = out.joined(separator: "\n")
        store.log("诊断完成：会话名 \(names.count) 个，输入框 \(bool(info["editor"]) ? "有" : "无")，登录墙 \(bool(info["login"]) ? "命中" : "未命中")")
    }
}
