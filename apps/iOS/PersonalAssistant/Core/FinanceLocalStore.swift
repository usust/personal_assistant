import Foundation
import Observation
import SQLite3

/// 本地账本和上传队列在同一个 SQLite 文档事务中持久化；账号空间以服务器及用户共同隔离。
@MainActor @Observable
final class FinanceLocalStore {
    /// 仅供当前识别请求使用的图片，不写入账本；任务结束立即移除。
    var screenshotImages: [String: String] = [:]
    var revision = 0
    var syncing = false
    var syncError: String?
    private(set) var document: [String: Any]
    private let databaseURL: URL
    var onChange: (() -> Void)?
    var onMutation: (() -> Void)?

    /// 打开受设备保护的本地数据库；参数：url 为测试可注入路径，nil 使用 Application Support；返回值：账本；读写失败抛错，绝不覆盖损坏的原文件。
    init(url: URL? = nil) throws {
        let directory = try url?.deletingLastPathComponent() ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Finance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = url ?? directory.appendingPathComponent("ledger.sqlite")
        document = ["schemaVersion": 1, "active": "guest", "spaces": ["guest": Self.emptySpace()]]
        if let data = try Self.database(databaseURL, writing: nil) {
            guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any], saved["schemaVersion"] as? Int == 1 else { throw Self.failure("本机账本版本不兼容") }
            guard let active = saved["active"] as? String, let all = saved["spaces"] as? [String: [String: Any]], all[active] != nil else { throw Self.failure("本机账本结构损坏") }
            for space in all.values {
                for table in ["accounts", "categories", "transactions", "presets", "queue"] {
                    guard space[table] is [[String: Any]] else { throw Self.failure("本机账本集合损坏") }
                }
            }
            document = saved
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: databaseURL.path)
        #endif
    }

    /// 生成空账本；参数：无；返回值：集合和队列为空的持久化字典，无副作用。
    static func emptySpace() -> [String: Any] {
        ["accounts": [[String: Any]](), "categories": [[String: Any]](), "transactions": [[String: Any]](), "presets": [[String: Any]](), "queue": [[String: Any]](), "aliases": [String: Int](), "cache": [String: Any](), "enabled": false]
    }
    var activeKey: String { document["active"] as? String ?? "guest" }
    var spaces: [String: [String: Any]] { document["spaces"] as? [String: [String: Any]] ?? [:] }
    var space: [String: Any] { spaces[activeKey] ?? Self.emptySpace() }
    var queue: [[String: Any]] { space["queue"] as? [[String: Any]] ?? [] }
    var enabled: Bool { space["enabled"] as? Bool ?? false }
    var lastSync: Date? { (space["lastSync"] as? Double).map(Date.init(timeIntervalSince1970:)) }
    var cachedProfile: Profile? {
        guard let raw = space["profile"], let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    /// 构造可向用户展示的本地错误；参数：message 为简短原因；返回值：API 错误，无副作用。
    static func failure(_ message: String) -> APIError { APIError(status: 0, message: message) }
    /// 读写唯一文档行；参数：url 为数据库文件，writing 为完整 JSON 或 nil；返回值：读取字节，写入时为 nil；SQLite 单语句事务保证账本和队列共同提交，失败抛错。
    private static func database(_ url: URL, writing: Data?) throws -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { if db != nil { sqlite3_close(db) }; throw failure("无法打开本机账本") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS ledger (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw failure("无法初始化本机账本") }
        if let writing {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ledger(id,payload) VALUES(1, ?)", -1, &statement, nil) == SQLITE_OK else { throw failure("无法保存本机账本") }
            defer { sqlite3_finalize(statement) }
            // 字节回调输入为本次 JSON 的借用内存；返回 SQLite 状态，step 完成前内存保持有效。
            let result = writing.withUnsafeBytes { bytes -> Int32 in
                guard sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), nil) == SQLITE_OK else { return SQLITE_ERROR }
                return sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw failure("本机保存失败，请检查存储空间") }
            return nil
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM ledger WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw failure("本机账本读取失败") }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure("本机账本读取失败") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    /// 原子提交整个文档；参数：next 为已验证的新状态；返回值：无；磁盘成功后才替换内存并通知界面，失败保留旧状态。
    func commit(_ next: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        _ = try Self.database(databaseURL, writing: data)
        let nextKey = next["active"] as? String ?? "guest"
        let nextSpace = (next["spaces"] as? [String: [String: Any]])?[nextKey] ?? [:]
        var visibleChanged = nextKey != activeKey
        for key in ["accounts", "categories", "transactions", "presets", "plans", "installments", "screenshotBookkeeping"] {
            if !NSDictionary(dictionary: [key: space[key] ?? NSNull()]).isEqual(to: [key: nextSpace[key] ?? NSNull()]) { visibleChanged = true }
        }
        document = next
        if visibleChanged { revision += 1; onChange?() }
    }
    /// 保存当前空间；参数：next 为完整账本空间；返回值：无；与队列一同落盘，失败抛错。
    func saveSpace(_ next: [String: Any]) throws {
        var updated = document; var all = spaces; all[activeKey] = next; updated["spaces"] = all
        try commit(updated)
    }
    /// 开启账号同步并自动接收未归属游客记录；参数：server 为规范化地址，profile 为已认证身份；返回值：无；保留同名独立记录，原游客队列原子转移，仅绑定一次。
    func enable(server: String, profile: Profile) throws {
        let key = server + "#" + String(profile.id)
        var all = spaces; var target = all[key] ?? Self.emptySpace()
        let guest = all["guest"] ?? Self.emptySpace()
        for table in ["accounts", "categories", "transactions", "presets", "queue"] {
            target[table] = (target[table] as? [[String: Any]] ?? []) + (guest[table] as? [[String: Any]] ?? [])
        }
        target["enabled"] = true; target["server"] = server
        target["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        all[key] = target; all["guest"] = Self.emptySpace()
        var next = document; next["spaces"] = all; next["active"] = key
        try commit(next); syncError = nil
    }
    /// 退出到独立游客空间；参数：无；返回值：无；不删除原账号及未同步记录，旧网络响应由空间键校验丢弃。
    func useGuest() throws {
        var next = document; next["active"] = "guest"; try commit(next); syncError = nil
    }
    /// 返回表记录；参数：name 为固定集合名；返回值：当前空间的记录副本，无副作用。
    func rows(_ name: String) -> [[String: Any]] { space[name] as? [[String: Any]] ?? [] }
    /// 解析整数 ID；参数：row 为业务字典，key 为字段；返回值：整数或 0，无副作用。
    static func id(_ row: [String: Any], _ key: String = "id") -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
    /// 解析金额为整数分；参数：value 必须为两位以内十进制字符串；返回值：分，非法或超限抛错，不使用浮点。
    static func cents(_ value: Any?) throws -> Int64 {
        guard let raw = value as? String, Values.validMoney(raw), let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { throw failure("金额格式无效") }
        return NSDecimalNumber(decimal: decimal * 100).int64Value
    }
    /// 格式化整数分；参数：value 为范围内金额；返回值：两位小数字符串，无副作用。
    static func money(_ value: Int64) -> String { "\(value < 0 ? "-" : "")\(abs(value) / 100)." + String(format: "%02lld", abs(value) % 100) }
    /// 编码 API 信封；参数：value 为 JSON 兼容数据；返回值：字节，编码失败抛错。
    static func envelope(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": value]) }
}
