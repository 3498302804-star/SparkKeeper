import Foundation

// MARK: - 目标好友

struct Target: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var enabled: Bool = true
    var lastSent: Date? = nil
    var lastOk: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, lastSent, lastOk
    }

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        lastSent = try? c.decodeIfPresent(Date.self, forKey: .lastSent)
        lastOk = (try? c.decode(Bool.self, forKey: .lastOk)) ?? false
    }
}

// MARK: - Cookie 快照

struct StoredCookie: Codable, Hashable {
    var name: String = ""
    var value: String = ""
    var domain: String = ""
    var path: String = "/"
    var expires: Double = 0
    var secure: Bool = false
}

// MARK: - 账号

struct Account: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String = "账号"
    var uniqueId: String = ""
    /// 对应 WKWebsiteDataStore 的容器标识
    var storeId: String = UUID().uuidString
    var targets: [Target] = []
    var cookies: [StoredCookie] = []
    var enabled: Bool = true
    var lastRun: Date? = nil
    var lastResult: String = "未运行"
    var needLogin: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, uniqueId, storeId, targets, cookies
        case enabled, lastRun, lastResult, needLogin
    }

    init(title: String, uniqueId: String) {
        self.title = title
        self.uniqueId = uniqueId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "账号"
        uniqueId = (try? c.decode(String.self, forKey: .uniqueId)) ?? ""
        storeId = (try? c.decode(String.self, forKey: .storeId)) ?? UUID().uuidString
        targets = (try? c.decode([Target].self, forKey: .targets)) ?? []
        cookies = (try? c.decode([StoredCookie].self, forKey: .cookies)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        lastRun = try? c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = (try? c.decode(String.self, forKey: .lastResult)) ?? "未运行"
        needLogin = (try? c.decode(Bool.self, forKey: .needLogin)) ?? false
    }
}

// MARK: - 运行记录

struct RunRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var date: Date = Date()
    var account: String = ""
    var target: String = ""
    var ok: Bool = false
    var detail: String = ""
}

// MARK: - 设置

struct AppSettings: Codable {
    var schedulerEnabled: Bool = true
    var fireHour: Int = 9
    var fireMinute: Int = 0
    /// 触发时间随机抖动窗口（分钟），0 表示准点
    var jitterMinutes: Int = 25
    /// 消息模板，支持 {date} {time} {random} {account} {target}
    var template: String = "🔥 火花续上 {date}"
    var randomLines: [String] = ["🔥", "今日份火花已续", "滴，火花卡", "火花 +1", "续上了，别断"]
    /// 只演练：找到好友、输入内容，但不点发送
    var dryRun: Bool = false
    /// 后台保活（静音音频）
    var keepAlive: Bool = true
    var chatURL: String = "https://creator.douyin.com/creator-micro/data/following/chat"
    var homeURL: String = "https://creator.douyin.com/"
    /// 单次运行最多处理多少个好友
    var maxTargetsPerRun: Int = 20
    /// 单个好友的等待上限（秒）
    var perTargetTimeout: Int = 45
    /// 好友列表最多向下滚动多少次
    var maxScrolls: Int = 12

    enum CodingKeys: String, CodingKey {
        case schedulerEnabled, fireHour, fireMinute, jitterMinutes
        case template, randomLines, dryRun, keepAlive
        case chatURL, homeURL, maxTargetsPerRun, perTargetTimeout, maxScrolls
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schedulerEnabled = (try? c.decode(Bool.self, forKey: .schedulerEnabled)) ?? d.schedulerEnabled
        fireHour = (try? c.decode(Int.self, forKey: .fireHour)) ?? d.fireHour
        fireMinute = (try? c.decode(Int.self, forKey: .fireMinute)) ?? d.fireMinute
        jitterMinutes = (try? c.decode(Int.self, forKey: .jitterMinutes)) ?? d.jitterMinutes
        template = (try? c.decode(String.self, forKey: .template)) ?? d.template
        randomLines = (try? c.decode([String].self, forKey: .randomLines)) ?? d.randomLines
        dryRun = (try? c.decode(Bool.self, forKey: .dryRun)) ?? d.dryRun
        keepAlive = (try? c.decode(Bool.self, forKey: .keepAlive)) ?? d.keepAlive
        chatURL = (try? c.decode(String.self, forKey: .chatURL)) ?? d.chatURL
        homeURL = (try? c.decode(String.self, forKey: .homeURL)) ?? d.homeURL
        maxTargetsPerRun = (try? c.decode(Int.self, forKey: .maxTargetsPerRun)) ?? d.maxTargetsPerRun
        perTargetTimeout = (try? c.decode(Int.self, forKey: .perTargetTimeout)) ?? d.perTargetTimeout
        maxScrolls = (try? c.decode(Int.self, forKey: .maxScrolls)) ?? d.maxScrolls
    }
}
