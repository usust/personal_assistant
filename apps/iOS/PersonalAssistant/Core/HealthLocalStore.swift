import Foundation
import CoreFoundation
import Darwin

/// 本机健康仓库；不依赖登录、网络或 HealthKit，不保存照片。单一实例由主线程持有。
@MainActor final class HealthLocalStore {
    enum StoreError: LocalizedError {
        case invalid(String), notFound, notLocalRoute, corrupt, unsupportedVersion(Int), changedOnDisk
        /// 返回可展示错误；参数：无；返回值：不包含健康正文或磁盘路径的说明；无副作用。
        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            case .notFound: return "健康记录不存在"
            case .notLocalRoute: return "此操作不属于本地健康路由"
            case .corrupt: return "本机健康数据损坏，原文件已保留"
            case .unsupportedVersion: return "本机健康数据版本不受支持，原文件已保留"
            case .changedOnDisk: return "本机健康文件已变化，请重新打开后重试"
            }
        }
    }

    struct Day: Codable, Equatable {
        let id: Int
        let date: String
        let timezone: String
        let steps: Double?
        let active_energy: Double?
        let distance: Double?
        let resting_heart_rate: Double?
        let weight: Double?
        let updated_at: String
    }
    struct Item: Codable, Equatable {
        let name: String
        let grams: Double
        let calories: Double
    }
    struct Meal: Codable, Equatable {
        let id: String
        let date: String
        let meal_type: String
        let items: [Item]
        let note: String
        let created_at: String
    }
    struct Report: Codable, Equatable {
        let id: Int
        let content: String
        let snapshot: String
        let config_id: Int
        let created_at: String
    }
    /// 值类型只读副本；完整历史不限 overview 的 30 日/20 份窗口，可编码用于明确授权后的 AI 输入。
    struct Snapshot: Codable, Equatable {
        let days: [Day]
        let daily_goal: Double?
        let meals: [Meal]
        let reports: [Report]
    }
    private struct Records: Codable {
        var version = 1
        var nextID = 1
        var days: [Day] = []
        var daily_goal: Double?
        var meals: [Meal] = []
        var reports: [Report] = []
    }
    private let url: URL
    private var records: Records
    private var diskData: Data?

    /// 打开版本化仓库；参数：url 为测试或迁移文件位置，nil 使用 Application Support/Health/records.json；返回值：仓库；损坏、未知版本和读取失败抛错且不覆盖文件，无网络副作用。
    init(url: URL? = nil) throws {
        self.url = try url ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Health", isDirectory: true).appendingPathComponent("records.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            let data = try Data(contentsOf: self.url)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = root["version"] as? Int else { throw StoreError.corrupt }
            guard version == 1 else { throw StoreError.unsupportedVersion(version) }
            guard let decoded = try? JSONDecoder().decode(Records.self, from: data) else { throw StoreError.corrupt }
            try Self.validateStored(decoded)
            records = decoded
            diskData = data
        } else {
            records = Records()
            diskData = nil
        }
    }

    /// 获取独立只读快照；参数：无；返回值：完整健康历史、目标、餐食、报告的值副本；无磁盘或网络副作用。
    var snapshot: Snapshot {
        Snapshot(days: records.days, daily_goal: records.daily_goal, meals: records.meals, reports: records.reports)
    }

    /// 判断是否本机普通操作；参数：path 为不带查询串的 API 路径，method 为 HTTP 方法；返回值：支持时 true，AI 分析与报告生成始终 false；无副作用。
    static func handles(_ path: String, method: String) -> Bool {
        let method = method.uppercased()
        switch (path, method) {
        case ("/health-management", "GET"), ("/health-management", "DELETE"),
             ("/health-management/sync", "POST"), ("/health-management/nutrition", "GET"),
             ("/health-management/nutrition/goal", "GET"), ("/health-management/nutrition/goal", "PUT"),
             ("/health-management/meals", "GET"), ("/health-management/meals", "POST"),
             ("/health-management/reports", "GET"): return true
        default:
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0].isEmpty, parts[1] == "health-management", !parts[3].isEmpty else { return false }
            return (parts[2] == "meals" && method == "DELETE") ||
                (parts[2] == "reports" && ["GET", "DELETE"].contains(method))
        }
    }

    /// 执行离线 API；参数：path 为精确路由，method 为 HTTP 方法，body 为 JSON 字段或 nil，query 为查询参数；返回值：{"data":...} JSON；校验/存储错误抛出，失败不修改内存，无网络请求。
    func handle(_ path: String, method: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) throws -> Data {
        let method = method.uppercased()
        guard Self.handles(path, method: method) else { throw StoreError.notLocalRoute }
        var next = records
        var result: Any = NSNull()
        switch (path, method) {
        case ("/health-management", "GET"):
            result = ["days": try Self.object(Array(records.days.sorted { $0.date > $1.date }.prefix(30))),
                      "reports": try Self.object(Array(records.reports.sorted { $0.id > $1.id }.prefix(20)))]
        case ("/health-management", "DELETE"):
            next = Records(); next.nextID = records.nextID
        case ("/health-management/sync", "POST"):
            guard let days = body?["days"] as? [[String: Any]], (1...31).contains(days.count) else { throw StoreError.invalid("每次需提交1–31天数据") }
            var seen = Set<String>()
            for input in days {
                guard let date = input["date"] as? String, let timezone = input["timezone"] as? String,
                      let zone = TimeZone(identifier: timezone), let parsed = Self.date(date, zone: zone),
                      parsed <= Date(), parsed >= Calendar(identifier: .gregorian).date(byAdding: .year, value: -2, to: Date())!,
                      seen.insert(date).inserted else { throw StoreError.invalid("日期或时区无效、日期重复或超出两年范围") }
                let old = next.days.first { $0.date == date }
                let id = try old?.id ?? Self.allocateID(&next)
                // /sync 是按日期完整快照而非 PATCH：缺失/显式 null 清除旧指标，0 仍是有效观测值。
                let day = Day(id: id, date: date, timezone: timezone,
                              steps: try Self.metric(input, "steps", max: 200_000),
                              active_energy: try Self.metric(input, "active_energy", max: 20_000),
                              distance: try Self.metric(input, "distance", max: 300_000),
                              resting_heart_rate: try Self.metric(input, "resting_heart_rate", max: 300),
                              weight: try Self.metric(input, "weight", max: 1_000), updated_at: Self.timestamp())
                next.days.removeAll { $0.date == date }; next.days.append(day)
            }
            result = ["synced": days.count]
        case ("/health-management/nutrition", "GET"), ("/health-management/meals", "GET"):
            guard let date = query.first(where: { $0.name == "date" })?.value, Self.date(date) != nil else { throw StoreError.invalid("日期须为有效的yyyy-MM-dd") }
            let meals = records.meals.filter { $0.date == date }.sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at < $1.created_at }
            if path.hasSuffix("/meals") { result = try Self.object(meals) }
            else { result = ["daily_goal": records.daily_goal as Any? ?? NSNull(), "meals": try Self.object(meals)] }
        case ("/health-management/nutrition/goal", "GET"):
            result = ["daily_goal": records.daily_goal as Any? ?? NSNull()]
        case ("/health-management/nutrition/goal", "PUT"):
            let input = try Self.fields(body, keys: ["daily_goal"])
            guard let goal = Self.number(input["daily_goal"]), (1000...6000).contains(goal) else { throw StoreError.invalid("每日目标须为1000–6000千卡") }
            next.daily_goal = goal; result = ["daily_goal": goal]
        case ("/health-management/meals", "POST"):
            let input = try Self.fields(body, keys: ["id", "date", "meal_type", "items", "note"])
            guard let id = input["id"] as? String, Self.validUUID(id),
                  let date = input["date"] as? String, Self.date(date) != nil,
                  let type = input["meal_type"] as? String, ["breakfast", "lunch", "dinner", "snack"].contains(type),
                  let note = input["note"] as? String, note.utf8.count <= 1500,
                  let rawItems = input["items"] as? [[String: Any]], (1...20).contains(rawItems.count) else { throw StoreError.invalid("餐食字段无效") }
            var items: [Item] = []
            for raw in rawItems {
                let value = try Self.fields(raw, keys: ["name", "grams", "calories"])
                guard let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 120,
                      let grams = Self.number(value["grams"]), grams > 0, grams <= 10_000,
                      let calories = Self.number(value["calories"]), calories > 0, calories <= 20_000 else { throw StoreError.invalid("食物名称或估算数值无效") }
                items.append(Item(name: name, grams: grams, calories: calories))
            }
            let meal = Meal(id: id.lowercased(), date: date, meal_type: type, items: items, note: note, created_at: Self.timestamp())
            if let old = records.meals.first(where: { $0.id == meal.id }) {
                guard old.date == meal.date, old.meal_type == meal.meal_type, old.items == meal.items, old.note == meal.note else { throw StoreError.invalid("此餐食ID已用于不同内容") }
                return try Self.envelope(Self.object(old))
            }
            next.meals.append(meal); result = try Self.object(meal)
        case ("/health-management/reports", "GET"):
            result = try Self.object(records.reports.sorted { $0.id > $1.id })
        default:
            let id = String(path.split(separator: "/").last!)
            if path.hasPrefix("/health-management/meals/") {
                guard Self.validUUID(id) else { throw StoreError.invalid("餐食ID无效") }
                next.meals.removeAll { $0.id == id.lowercased() }
            } else {
                guard let reportID = Int(id), reportID > 0 else { throw StoreError.invalid("报告ID无效") }
                if method == "GET" {
                    guard let report = records.reports.first(where: { $0.id == reportID }) else { throw StoreError.notFound }
                    result = try Self.object(report)
                } else { next.reports.removeAll { $0.id == reportID } }
            }
        }
        let response = try Self.envelope(result)
        if method != "GET" { try persist(next) }
        return response
    }

    /// 保存外部已生成报告，不执行 AI；参数：content 为非空报告，snapshot 为生成时快照 JSON 字符串（默认空），configID 为非负配置编号（默认0）；返回值：带本地编号及时间的报告；落盘失败抛错，无外发。
    @discardableResult func saveGeneratedReport(content: String, snapshot: String = "", configID: Int = 0) throws -> Report {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, configID >= 0 else { throw StoreError.invalid("报告内容或配置编号无效") }
        var next = records
        let report = Report(id: try Self.allocateID(&next), content: content, snapshot: snapshot, config_id: configID, created_at: Self.timestamp())
        next.reports.append(report)
        try persist(next)
        return report
    }

    /// 原子提交整个版本文件；参数：next 为已校验的新状态；返回值：无；先校验磁盘未变更，写入成功后才替换内存，iOS 启用完整文件保护；磁盘失败保留内存。
    private func persist(_ next: Records) throws {
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == diskData else { throw StoreError.changedOnDisk }
        let data = try JSONEncoder().encode(next)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 同目录暂存确保 rename 为同卷原子替换；保护在发布前生效，不出现未保护的正式文件。
        let staging = directory.appendingPathComponent(".records-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        #if os(iOS)
        try data.write(to: staging, options: [.withoutOverwriting, .completeFileProtection])
        #else
        try data.write(to: staging, options: .withoutOverwriting)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        records = next; diskData = data
    }

    /// 校验存盘结构及业务值；参数：value 为已解码文件；返回值：无；非法数据抛损坏错误，不按当前日期拒绝合法历史。
    private static func validateStored(_ value: Records) throws {
        guard value.nextID > 0, value.daily_goal == nil || (value.daily_goal!.isFinite && (1000...6000).contains(value.daily_goal!)),
              Set(value.days.map(\.date)).count == value.days.count,
              Set(value.days.map(\.id)).count == value.days.count,
              Set(value.meals.map(\.id)).count == value.meals.count,
              Set(value.reports.map(\.id)).count == value.reports.count else { throw StoreError.corrupt }
        for day in value.days {
            guard day.id > 0, day.id < value.nextID, date(day.date) != nil, TimeZone(identifier: day.timezone) != nil, !day.updated_at.isEmpty else { throw StoreError.corrupt }
            for (number, max) in [(day.steps, 200_000.0), (day.active_energy, 20_000), (day.distance, 300_000), (day.resting_heart_rate, 300), (day.weight, 1_000)] {
                if let number, !number.isFinite || number < 0 || number > max { throw StoreError.corrupt }
            }
        }
        for meal in value.meals {
            guard validUUID(meal.id), meal.id == meal.id.lowercased(), date(meal.date) != nil,
                  ["breakfast", "lunch", "dinner", "snack"].contains(meal.meal_type), (1...20).contains(meal.items.count), meal.note.utf8.count <= 1500, !meal.created_at.isEmpty else { throw StoreError.corrupt }
            for item in meal.items {
                guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.utf8.count <= 120,
                      item.grams.isFinite, item.grams > 0, item.grams <= 10_000, item.calories.isFinite, item.calories > 0, item.calories <= 20_000 else { throw StoreError.corrupt }
            }
        }
        for report in value.reports {
            guard report.id > 0, report.id < value.nextID, report.config_id >= 0, !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !report.created_at.isEmpty else { throw StoreError.corrupt }
        }
    }

    /// 生成递增编号；参数：value 为待提交副本；返回值：新编号；耗尽抛错而不溢出，仅修改副本。
    private static func allocateID(_ value: inout Records) throws -> Int {
        guard value.nextID < Int.max else { throw StoreError.invalid("健康记录编号已耗尽") }
        let id = value.nextID; value.nextID += 1; return id
    }
    /// 严格解析有限 JSON 数字；参数：value 为任意字段；返回值：数值或 nil，拒绝布尔、字符串及非有限值；无副作用。
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    /// 解析可空指标；参数：input 为快照字段、key 为白名单键、max 为上限；返回值：缺失/null 为 nil，其余为合法非负值；非法抛错。
    private static func metric(_ input: [String: Any], _ key: String, max: Double) throws -> Double? {
        guard let raw = input[key], !(raw is NSNull) else { return nil }
        guard let value = number(raw), value >= 0, value <= max else { throw StoreError.invalid("健康数值超出允许范围") }
        return value
    }
    /// 检查营养请求白名单；参数：body 为 JSON 对象、keys 为所有必填且允许字段；返回值：合法对象；未知/缺失/null 或大于64KiB抛错。
    private static func fields(_ body: [String: Any]?, keys: Set<String>) throws -> [String: Any] {
        guard let body, Set(body.keys) == keys, !body.values.contains(where: { $0 is NSNull }), JSONSerialization.isValidJSONObject(body),
              try JSONSerialization.data(withJSONObject: body).count <= 64 * 1024 else { throw StoreError.invalid("餐食请求格式或字段无效") }
        return body
    }
    /// 严格解析公历自然日；参数：text 为 yyyy-MM-dd，zone 默认为 UTC；返回值：当地午夜或 nil；拒绝不存在日期和非四位年份，无副作用。
    private static func date(_ text: String, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Date? {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil, !text.hasPrefix("0000") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
    /// 校验标准 UUID 文本；参数：text 为餐食编号；返回值：是否为36字符规范形状；不要求特定UUID版本，无副作用。
    private static func validUUID(_ text: String) -> Bool { text.count == 36 && UUID(uuidString: text) != nil }
    /// 生成 RFC3339 时间；参数：无；返回值：当前 UTC 时间字符串；无副作用。
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    /// 转为 JSON 兼容对象；类型参数 T 必须可编码，参数：value 为结构化值；返回值：JSON对象或数组；编码失败抛错，无副作用。
    private static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    /// 包装 API 成功信封；参数：value 为 JSON 兼容对象或 NSNull；返回值：UTF-8 JSON Data；无副作用，序列化失败抛错。
    private static func envelope(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": value], options: [.sortedKeys]) }
}
