import Foundation
import BackgroundTasks
import UIKit
import AVFoundation
import UserNotifications

/// 定时调度：BGAppRefreshTask（系统到点唤起） + 前台定时器兜底 + 后台保活音频。
///
/// 注意：本类刻意不加 `@MainActor`，因为 `BGTaskScheduler.register` 必须在
/// `application(_:didFinishLaunchingWithOptions:)` 返回前同步调用；所有触碰
/// Store / UI 的代码都在内部通过 `Task { @MainActor in ... }` 回到主线程。
final class Scheduler {

    static let shared = Scheduler()
    static let bgTaskId = "com.yg.sparkkeeper.refresh"
    private init() {}

    private var timer: Timer?

    // MARK: - 注册（App 启动最早期调用）

    func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Scheduler.bgTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Scheduler.shared.handle(refresh)
        }
        if !ok {
            Task { @MainActor in Store.shared.log("BGTask 注册失败：标识 \(Scheduler.bgTaskId) 不在 Info.plist") }
        }
    }

    private var currentTask: Task<Void, Never>?

    private func handle(_ task: BGAppRefreshTask) {
        // BGAppRefresh 通常只给 30 秒左右，而一次页面加载就可能 10 秒。
        // 旧实现 expirationHandler 只打了条日志，工作继续跑但 task 已被系统回收，
        // 结果是「跑了但什么都没发出去」。现在到期就真正取消本轮。
        let work = Task { @MainActor in
            Store.shared.log("后台任务被系统唤起")
            Scheduler.shared.scheduleNext()
            // 30 秒预算下按默认 20 个目标跑必然跑不完，与其被系统掐断在半路，
            // 不如每轮只推进 3 个，靠后续多次唤醒补齐。
            await SparkRunner.shared.run(force: false, maxTargets: 3)
            task.setTaskCompleted(success: true)
        }
        currentTask = work
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
            Task { @MainActor in
                Store.shared.log("后台任务时间用尽，本轮已取消")
                Scheduler.shared.currentTask = nil
            }
        }
    }

    // MARK: - 提交下次任务

    @MainActor
    func scheduleNext() {
        let store = Store.shared
        guard store.settings.schedulerEnabled else {
            store.log("调度已关闭，不提交后台任务")
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Scheduler.bgTaskId)
        let req = BGAppRefreshTaskRequest(identifier: Scheduler.bgTaskId)
        let next = store.nextFireDate()
        req.earliestBeginDate = next
        do {
            try BGTaskScheduler.shared.submit(req)
            store.log("已提交后台任务，最早 \(Scheduler.fmt(next)) 触发")
        } catch {
            store.log("提交后台任务失败：\(error.localizedDescription)")
        }
        Notifier.scheduleLocal(at: next, title: "火花时间到", body: "打开 App 可立即续火花")
        startForegroundTimer(until: next)
    }

    @MainActor
    private func startForegroundTimer(until date: Date) {
        timer?.invalidate()
        // 已经过点就尽快跑（不要死等 20 秒）；还没到就分片上界 30 分钟内醒一次
        let interval = max(2, min(1800, date.timeIntervalSinceNow))
        let t = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                let store = Store.shared
                if store.settings.schedulerEnabled,
                   store.nextFireDate() <= Date().addingTimeInterval(90) {
                    await SparkRunner.shared.run(force: false)
                    Scheduler.shared.scheduleNext()
                } else {
                    Scheduler.shared.startForegroundTimer(until: store.nextFireDate())
                }
            }
        }
        // 默认 mode 下滚动列表/弹出 sheet 时 Timer 不触发，用 .common 覆盖
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 通知

enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func scheduleLocal(at date: Date, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: "spark.daily", content: c, trigger: trigger)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["spark.daily"])
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - 后台保活

/// 静音音频循环：让 App 在被切到后台 / 锁屏时仍能保持一段时间 WebView 存活。
/// 建议充电时开启，否则耗电明显。
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var player: AVAudioPlayer?
    private var active = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private init() {}

    func begin() {
        guard Store.shared.settings.keepAlive else { return }
        beginBackgroundTask()
        guard !active else { return }
        active = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Store.shared.log("音频会话不可用：\(error.localizedDescription)")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sk_silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? BackgroundKeeper.silentWav().write(to: url)
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0.0
            player?.play()
        } catch {
            Store.shared.log("保活音频启动失败：\(error.localizedDescription)")
        }
    }

    func end() {
        player?.stop()
        player = nil
        active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func beginBackgroundTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "spark-send") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTask)
                    self.bgTask = .invalid
                }
            }
        }
    }

    /// 生成 44.1kHz 单声道 16bit 的静音 WAV
    static func silentWav(seconds: Int = 1) -> Data {
        let sampleRate = 44100
        let frames = sampleRate * seconds
        let dataSize = frames * 2
        var d = Data()
        func le32(_ v: Int) {
            var x = UInt32(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func le16(_ v: Int) {
            var x = UInt16(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8))
        le32(36 + dataSize)
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16); le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8))
        le32(dataSize)
        d.append(Data(count: dataSize))
        return d
    }
}
