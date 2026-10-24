import SwiftUI
import WebKit

// MARK: - 登录页（复用同一个 WKWebView）

struct LoginWebView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    /// 登录态要落到哪个账号；nil = 第一个账号
    var accountId: UUID?

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

    /// 先落 Cookie 快照到目标账号，再回读一次登录态，最后退回离屏窗口。
    /// 一个账号都没有时自动建一个「主号」，避免白登录。
    private func finishLogin() async {
        busy = true
        defer { busy = false }

        let cookies = await WebSession.shared.exportCookies()
        store.log("已获取 \(cookies.count) 条 Cookie")

        var id = targetId
        if id == nil {
            id = store.addAccount(title: "主号", uniqueId: "")
            store.log("还没有账号，已自动创建「主号」")
        }
        if let id = id {
            store.update(id) { acc in
                if !cookies.isEmpty { acc.cookies = cookies }
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
                    Button(busy ? "…" : "开始") { Task { await run() } }
                        .disabled(busy)
                }
            }
        }
    }

    @MainActor
    private func run() async {
        busy = true
        defer { busy = false }
        let session = WebSession.shared
        var out: [String] = []
        out.append("载入：\(store.settings.chatURL)")
        try? await session.load(store.settings.chatURL, timeout: 45)
        await session.injectCore()

        let info = await session.jsObject(DouyinJS.diagnose)
        out.append("URL：\(info["url"] as? String ?? "-")")
        out.append("标题：\(info["title"] as? String ?? "-")")
        out.append("登录墙：\((info["login"] as? Bool) == true ? "是" : "否")")
        out.append("输入框：\((info["editor"] as? Bool) == true ? "已找到" : "没找到")")

        let names = (info["names"] as? [Any])?.compactMap { $0 as? String } ?? []
        if names.isEmpty {
            out.append("识别到的会话名：0 个")
        } else {
            out.append("识别到的会话名（\(names.count)）：")
            out.append(contentsOf: names.prefix(40).map { "  · \($0)" })
        }

        let classes = (info["classes"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !classes.isEmpty {
            out.append("列表项 class 采样：")
            out.append(contentsOf: classes.prefix(25).map { "  · \($0)" })
        }

        let btns = (info["buttons"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !btns.isEmpty {
            out.append("可见按钮文本：\(btns.prefix(20).joined(separator: " | "))")
        }

        out.append("滚动容器：\(info["scrollable"] as? String ?? "-")")
        out.append("正文前 600 字：")
        out.append(info["text"] as? String ?? "-")

        report = out.joined(separator: "\n")
        store.log("诊断完成：会话名 \(names.count) 个，输入框 \(info["editor"] as? Bool == true ? "有" : "无")")
    }
}
