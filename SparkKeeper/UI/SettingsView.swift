import Foundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("启用每日自动", isOn: $store.settings.schedulerEnabled)
                    Stepper("触发时间 \(String(format: "%02d:%02d", store.settings.fireHour, store.settings.fireMinute))",
                            value: Binding(
                                get: { store.settings.fireHour * 60 + store.settings.fireMinute },
                                set: { store.settings.fireHour = $0 / 60 % 24; store.settings.fireMinute = $0 % 60 }
                            ),
                            in: 0...(23 * 60 + 59), step: 5)
                    Stepper("随机抖动 \(store.settings.jitterMinutes) 分钟",
                            value: $store.settings.jitterMinutes, in: 0...180, step: 5)
                    Toggle("演练模式（只输入不发送）", isOn: $store.settings.dryRun)
                    Toggle("后台保活音频（建议充电时开）", isOn: $store.settings.keepAlive)
                } header: {
                    Text("定时")
                } footer: {
                    Text("iOS 的后台刷新由系统决定，不保证准点。想要“准点”，把快捷指令设为每天固定时间触发本 App 的「续火花」动作。")
                }

                Section("消息模板") {
                    TextEditor(text: $store.settings.template)
                        .frame(minHeight: 80)
                        .font(.system(.body, design: .monospaced))
                    Text("可用变量：{date} {time} {random} {account} {target}")
                        .font(.caption).foregroundColor(.secondary)
                    NavigationLink("随机短语（\(store.settings.randomLines.count) 条）") {
                        RandomLinesEditor()
                    }
                }

                Section("执行参数") {
                    Stepper("单次最多 \(store.settings.maxTargetsPerRun) 个好友",
                            value: $store.settings.maxTargetsPerRun, in: 1...100)
                    Stepper("单好友超时 \(store.settings.perTargetTimeout) 秒",
                            value: $store.settings.perTargetTimeout, in: 10...180, step: 5)
                    Stepper("列表最多滚动 \(store.settings.maxScrolls) 次",
                            value: $store.settings.maxScrolls, in: 1...60)
                }

                Section("页面地址") {
                    TextField("首页", text: $store.settings.homeURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("私信页", text: $store.settings.chatURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section("维护") {
                    Button("立即重排定时任务") {
                        Scheduler.shared.scheduleNext()
                    }
                    Button("清空 Web 数据（会退出登录）", role: .destructive) {
                        Task {
                            await WebSession.shared.wipeWebData()
                            store.log("已清空 Web 数据")
                        }
                    }
                    Button("保存配置") { store.save(); store.log("配置已保存") }
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-") }
                    HStack { Text("Bundle ID"); Spacer(); Text(Bundle.main.bundleIdentifier ?? "-").font(.caption) }
                }
            }
            .navigationTitle("设置")
            .onDisappear { store.save() }
        }
        .navigationViewStyle(.stack)
    }
}

struct RandomLinesEditor: View {
    @EnvironmentObject var store: Store
    @State private var text = ""

    var body: some View {
        Form {
            Section("每行一条") {
                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .font(.system(.body, design: .monospaced))
            }
            Section {
                Button("保存") {
                    let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.settings.randomLines = lines.isEmpty ? ["🔥"] : lines
                    store.save()
                }
            }
        }
        .navigationTitle("随机短语")
        .onAppear { text = store.settings.randomLines.joined(separator: "\n") }
    }
}
