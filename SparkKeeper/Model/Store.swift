import Foundation
import Combine

@MainActor
final class Store: ObservableObject {

    static let shared = Store()

    @Published var accounts: [Account] = []
    @Published var history: [RunRecord] = []
    @Published var settings: AppSettings = AppSettings()
    @Published var running: Bool = false
    @Published var liveLog: [String] = []

    private let fileURL: URL
    private var suppressSave = false

    private struct Payload: Codable {
        var accounts: [Account] = []
        var history: [RunRecord] = []
        var settings: AppSettings = AppSettings()
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("sparkkeeper.json")
        load()
    }

    // MARK: - 持久化

    func load() {
        suppressSave = true
        defer { suppressSave = false }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }
        accounts = payload.accounts
        history = Array(payload.history.suffix(400))
        settings = payload.settings
    }

    func save() {
        if suppressSave { return }
        let payload = Payload(accounts: accounts, history: Array(history.suffix(400)), settings: settings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 账号操作

    func addAccount(title: String, uniqueId: String) -> UUID {
        let acc = Account(title: title.isEmpty ? "账号" : title, uniqueId: uniqueId)
        accounts.append(acc)
        save()
        return acc.id
    }

    func index(of id: UUID) -> Int? {
        accounts.firstIndex { $0.id == id }
    }

    func update(_ id: UUID, _ body: (inout Account) -> Void) {
        guard let i = index(of: id) else { return }
        body(&accounts[i])
        save()
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    // MARK: - 记录

    func log(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(line)"
        liveLog.append(entry)
        if liveLog.count > 500 { liveLog.removeFirst(liveLog.count - 500) }
        #if DEBUG
        print(entry)
        #endif
    }

    func record(_ r: RunRecord) {
        history.append(r)
        if history.count > 400 { history.removeFirst(history.count - 400) }
        save()
    }

    // MARK: - 下次触发时间

    func nextFireDate(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = settings.fireHour
        comps.minute = settings.fireMinute
        comps.second = 0
        var base = cal.date(from: comps) ?? now
        // 每天一个稳定的抖动偏移，避免整点扎堆，同时保证同一天多次计算一致
        if settings.jitterMinutes > 0 {
            let day = cal.ordinality(of: .day, in: .era, for: now) ?? 0
            let offset = (day &* 37 &+ settings.fireHour &* 7) % max(1, settings.jitterMinutes * 60)
            base = base.addingTimeInterval(TimeInterval(offset))
        }
        if base <= now {
            base = cal.date(byAdding: .day, value: 1, to: base) ?? base.addingTimeInterval(86_400)
        }
        return base
    }

    // MARK: - 消息内容

    func buildMessage(account: String, target: String) -> String {
        var text = settings.template
        let df = DateFormatter()
        df.dateFormat = "MM月dd日"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        text = text.replacingOccurrences(of: "{date}", with: df.string(from: Date()))
        text = text.replacingOccurrences(of: "{time}", with: tf.string(from: Date()))
        text = text.replacingOccurrences(of: "{account}", with: account)
        text = text.replacingOccurrences(of: "{target}", with: target)
        if text.contains("{random}") {
            let pick = settings.randomLines.randomElement() ?? "🔥"
            text = text.replacingOccurrences(of: "{random}", with: pick)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
