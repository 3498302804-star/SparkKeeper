import SwiftUI

// MARK: - 首页

struct HomeView: View {
    @EnvironmentObject var store: Store

    @State private var showLogin = false
    @State private var showAddAccount = false
    @State private var showDiagnostics = false
    @State private var pickingFor: SheetTarget?
    @State private var addingTo: SheetTarget?
    @State private var loginFor: SheetTarget?
    @State private var pendingDelete: UUID?

    var body: some View {
        NavigationView {
            List {
                nextFireSection
                if store.accounts.isEmpty { emptySection }

                ForEach(store.accounts) { acc in
                    accountSection(acc: acc)
                }

                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("KA自动续火花")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddAccount) { AddAccountView() }
            .sheet(isPresented: $showLogin) { LoginWebView() }
            .sheet(item: $loginFor) { s in LoginWebView(accountId: s.id) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(item: $pickingFor) { s in FriendPickerView(accountId: s.id) }
            .sheet(item: $addingTo) { s in AddTargetView(accountId: s.id) }
            .alert("删除账号？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let id = pendingDelete { store.remove(id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该账号的登录态与目标好友会一并移除。")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 顶部卡片

    private var nextFireSection: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("下次自动续火花")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(store.settings.schedulerEnabled ? Scheduler.fmt(store.nextFireDate()) : "已关闭")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(store.settings.schedulerEnabled ? .primary : .secondary)
                    Text(store.running ? "正在发送…" : statusLine)
                        .font(.caption)
                        .foregroundColor(store.running ? .orange : .secondary)
                }
                Spacer()
                Button {
                    Task { await SparkRunner.shared.run(force: true) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(store.running ? 0.10 : 0.18))
                            .frame(width: 62, height: 62)
                        Image(systemName: store.running ? "hourglass" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.running)
            }
            .padding(.vertical, 8)
        }
    }

    private var statusLine: String {
        if store.settings.dryRun { return "演练模式：只输入不发送" }
        let total = store.accounts.reduce(0) { $0 + $1.targets.filter(\.enabled).count }
        return total == 0 ? "还没有目标好友" : "共 \(total) 个目标好友"
    }

    private var emptySection: some View {
        Section {
            Button {
                showLogin = true
            } label: {
                Label("打开抖音创作者中心登录", systemImage: "qrcode")
            }
            Button {
                showAddAccount = true
            } label: {
                Label("先添加账号", systemImage: "person.crop.circle.badge.plus")
            }
        } footer: {
            Text("流程：登录一次抖音 → 抓取好友 → 勾选要续火花的人 → 每天自动发一条消息。")
        }
    }

    // MARK: - 账号区块

    @ViewBuilder
    private func accountSection(acc: Account) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: acc.enabled ? "flame.fill" : "flame")
                    .foregroundColor(acc.enabled ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(acc.title).font(.headline)
                    Text(resultText(acc))
                        .font(.caption)
                        .foregroundColor(acc.lastResult.hasPrefix("成功") ? .green : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { acc.enabled },
                    set: { v in store.update(acc.id) { $0.enabled = v } }
                ))
                .labelsHidden()
            }

            if acc.needLogin {
                Button {
                    loginFor = SheetTarget(id: acc.id)
                } label: {
                    Label("登录已失效，点此重新登录", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }

            ForEach(acc.targets) { t in
                Button {
                    store.update(acc.id) { a in
                        if let i = a.targets.firstIndex(where: { $0.id == t.id }) {
                            a.targets[i].enabled.toggle()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: t.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(t.enabled ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name.isEmpty ? "未命名" : t.name)
                                .foregroundColor(.primary)
                            if let d = t.lastSent {
                                Text("上次 \(Scheduler.fmt(d)) \(t.lastOk ? "成功" : "失败")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                store.update(acc.id) { a in a.targets.remove(atOffsets: idx) }
            }

            Button {
                pickingFor = SheetTarget(id: acc.id)
            } label: {
                Label("从私信列表抓取好友", systemImage: "arrow.down.circle")
            }
            Button {
                addingTo = SheetTarget(id: acc.id)
            } label: {
                Label("手动添加好友", systemImage: "plus.circle")
            }

            HStack {
                Button("登录") { loginFor = SheetTarget(id: acc.id) }
                    .font(.footnote)
                Spacer()
                Button("刷新登录态") {
                    Task { await SparkRunner.shared.refreshLoginState(for: acc.id) }
                }
                .font(.footnote)
                Spacer()
                Button("只跑这个账号") {
                    Task { await SparkRunner.shared.run(onlyAccount: acc.id, force: true) }
                }
                .font(.footnote)
                Spacer()
                Button("删除") { pendingDelete = acc.id }
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        } header: {
            Text(acc.uniqueId.isEmpty ? acc.title : "\(acc.title) · \(acc.uniqueId)")
        }
    }

    private func resultText(_ acc: Account) -> String {
        if acc.needLogin { return "登录失效" }
        let targets = acc.targets.count
        return targets == 0 ? "未配置好友" : "\(acc.lastResult)"
    }

    // MARK: - 日志

    private var logSection: some View {
        let lines = Array(store.liveLog.suffix(80))
        return Section {
            if lines.isEmpty {
                Text("暂无日志").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // 不用 enumerated() 的元组 keyPath（Swift 不支持元组 key path）
                        ForEach(lines.indices, id: \.self) { i in
                            Text(lines[i])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            Button("清空日志") { store.liveLog.removeAll() }
                .font(.footnote)
        } header: {
            Text("运行日志")
        }
    }
}

// MARK: - 添加账号

struct AddAccountView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    @State private var title = ""
    @State private var uniqueId = ""
    @State private var goLogin = false
    @State private var createdId: UUID?

    var body: some View {
        NavigationView {
            Form {
                Section("账号备注") {
                    TextField("例如：我的主号", text: $title)
                    TextField("抖音号（可留空）", text: $uniqueId)
                }
                Section {
                    Button("保存并去登录") {
                        createdId = store.addAccount(title: title, uniqueId: uniqueId)
                        goLogin = true
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("保存后打开登录页，扫码登录一次即可，登录态会被保存下来。")
                }
            }
            .navigationTitle("添加账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $goLogin) {
                LoginWebView(accountId: createdId)
                    .onDisappear { dismiss() }
            }
        }
    }
}

// MARK: - 手动添加好友

struct AddTargetView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    let accountId: UUID
    @State private var name = ""

    var body: some View {
        NavigationView {
            Form {
                Section("好友昵称（需与私信列表一致）") {
                    TextField("对方昵称", text: $name)
                        .autocapitalization(.none)
                }
                Section {
                    Button("添加") {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else { return }
                        store.update(accountId) { $0.targets.append(Target(name: n)) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("支持片段匹配：填「小王」也能命中「小王同学」。昵称要求完全一致最稳。")
                }
            }
            .navigationTitle("添加好友")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

// MARK: - 便于 .sheet(item:) 的包装

struct SheetTarget: Identifiable {
    let id: UUID
}
