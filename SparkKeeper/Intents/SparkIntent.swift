import Foundation
import AppIntents

/// 供「快捷指令」调用的动作：跑一次续火花。
/// 快捷指令的个人自动化「每天 HH:mm」触发本动作，是 iOS 上最靠谱的定时方案。
struct SparkIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource("续火花") }
    static var description: IntentDescription? {
        IntentDescription("给已保存的目标好友发送今日火花消息")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "指定账号备注（留空=全部）")
    var accountTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("运行续火花 \(\.$accountTitle)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = await SparkIntentRunner.run(accountTitle: accountTitle)
        return .result(dialog: IntentDialog("今日火花：\(s.ok)/\(s.total) 成功"))
    }
}

/// 真正干活的部分，整体隔离在主线程，perform() 里 await 进来。
@MainActor
private enum SparkIntentRunner {
    /// 刻意不叫 Summary，避免和 AppIntents 的 Summary（ParameterSummary 构建器）撞名
    struct Outcome {
        var ok: Int = 0
        var total: Int = 0
    }

    static func run(accountTitle: String?) async -> Outcome {
        let store = Store.shared
        store.load()

        var only: UUID? = nil
        if let t = accountTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            only = store.accounts.first { $0.title.contains(t) }?.id
        }

        await SparkRunner.shared.run(onlyAccount: only, force: false)

        let today = store.history.filter { Calendar.current.isDateInToday($0.date) }
        return Outcome(ok: today.filter(\.ok).count, total: today.count)
    }
}

struct SparkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SparkIntent(),
            phrases: [
                "用 \(.applicationName) 续火花",
                "\(.applicationName) 帮我续火花"
            ],
            shortTitle: "续火花",
            systemImageName: "flame.fill"
        )
    }
}
