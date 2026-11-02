import Foundation

/// 备份协议独立于数据库结构；原始 JSON 保留未在界面模型中声明的业务字段和精确金额。
enum DataBackup {
    static let format = "personal-assistant-backup"
    static let schemaVersion = 1

    enum Scope: String, CaseIterable {
        case account, local
        /// 提供导出范围名称；参数：无；返回值：用于设置选择器的中文标题，无副作用。
        var title: String { self == .account ? "全部数据" : "本机账本" }
    }

    enum Failure: LocalizedError {
        case invalidLocal, invalidServer, unsupportedVersion, wrongOwner
        /// 提供文件生成失败原因；参数：无；返回值：简短中文错误，不包含数据正文或凭证。
        var errorDescription: String? {
            switch self {
            case .invalidLocal: return "本机账本无效，无法导出"
            case .invalidServer: return "服务器备份不完整，请更新服务端后重试"
            case .unsupportedVersion: return "服务器备份版本不兼容，请更新 App"
            case .wrongOwner: return "账号已变化，请重新导出"
            }
        }
    }

    /// 捕获单个空间的不可变备份字节；参数：key 为当前空间键，space 为完整空间，preferences 为白名单偏好，date 为捕获时刻，appVersion/build 为应用版本；返回值：独立 JSON 字节；非法集合抛错，不读磁盘、不修改源字典，不导出其他账号空间。
    static func captureLocal(key: String, space: [String: Any], preferences: [String: Any], date: Date = Date(), appVersion: String, build: String) throws -> Data {
        guard !key.isEmpty else { throw Failure.invalidLocal }
        for name in ["accounts", "categories", "transactions", "presets", "queue"] {
            guard space[name] is [[String: Any]] else { throw Failure.invalidLocal }
        }
        // 复制原始文档而非界面 DTO，保留临时 ID、别名、待同步命令和完整卡号；旧版残留截图图片也不进入文件。
        var savedSpace = space
        if var screenshot = savedSpace["screenshotBookkeeping"] as? [String: Any], var jobs = screenshot["jobs"] as? [[String: Any]] {
            for index in jobs.indices { jobs[index].removeValue(forKey: "image") }
            screenshot["jobs"] = jobs; savedSpace["screenshotBookkeeping"] = screenshot
        }
        let client: [String: Any] = [
            "platform": "iOS", "appVersion": appVersion, "build": build, "capturedAt": timestamp(date),
            "financeLedger": ["schemaVersion": 1, "active": key, "spaces": [key: savedSpace]],
            "preferences": preferences
        ]
        guard JSONSerialization.isValidJSONObject(client) else { throw Failure.invalidLocal }
        return try JSONSerialization.data(withJSONObject: client, options: [.sortedKeys])
    }

    /// 生成单文件备份；参数：local 为 captureLocal 的不可变字节，server 为账号导出信封且本机导出时为 nil，ownerID 为账号导出要求的用户 ID，serverURL 为规范地址，date 为生成时刻；返回值：UTF-8 JSON 文件；缺模块、版本不符或归属不匹配抛错，绝不降级为成功的空备份。
    static func makeFile(local: Data, server: Data?, ownerID: Int?, serverURL: String, date: Date = Date()) throws -> Data {
        guard let client = try JSONSerialization.jsonObject(with: local) as? [String: Any],
              let ledger = client["financeLedger"] as? [String: Any],
              ledger["schemaVersion"] as? Int == 1,
              let active = ledger["active"] as? String,
              let spaces = ledger["spaces"] as? [String: [String: Any]], spaces.count == 1, spaces[active] != nil else { throw Failure.invalidLocal }
        var file: [String: Any]
        if let server {
            guard let ownerID, let envelope = try JSONSerialization.jsonObject(with: server) as? [String: Any],
                  envelope["code"] as? Int == 200, let snapshot = envelope["data"] as? [String: Any],
                  snapshot["format"] as? String == format else { throw Failure.invalidServer }
            guard snapshot["schemaVersion"] as? Int == schemaVersion else { throw Failure.unsupportedVersion }
            guard let source = snapshot["source"] as? [String: Any], let owner = source["owner"] as? [String: Any],
                  owner["id"] as? Int == ownerID else { throw Failure.wrongOwner }
            guard let exportedAt = snapshot["exportedAt"] as? String, !exportedAt.isEmpty else { throw Failure.invalidServer }
            // 整份云端备份必须具有全部集合；原样保留扩展字段，不用会丢字段的展示模型重新编码。
            let required = ["task": ["lists", "tasks", "events"], "finance": ["accounts", "categories", "transactions", "presets", "events", "snapshots"], "health": ["days", "reports", "meals", "nutritionGoals"]]
            for (module, tables) in required {
                guard let data = snapshot[module] as? [String: Any] else { throw Failure.invalidServer }
                for table in tables { guard data[table] is [[String: Any]] else { throw Failure.invalidServer } }
            }
            guard snapshot["modelConfigs"] is [[String: Any]] else { throw Failure.invalidServer }
            file = snapshot
            file["serverExportedAt"] = exportedAt
            file["scope"] = Scope.account.rawValue
        } else {
            file = ["format": format, "schemaVersion": schemaVersion, "scope": Scope.local.rawValue]
        }
        var source = file["source"] as? [String: Any] ?? [:]
        source["serverURL"] = serverURL
        file["source"] = source
        file["exportedAt"] = timestamp(date)
        file["client"] = client
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// 格式化协议时间；参数：date 为绝对时间；返回值：UTC ISO8601 时间，含毫秒，无副作用。
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// 生成可保存的默认文件名；参数：date 为导出时间；返回值：包含时间和 JSON 后缀的名称，不包含账号或隐私字段。
    static func filename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "PersonalAssistant-backup-\(formatter.string(from: date)).json"
    }

    /// 读取允许备份的本机偏好；参数：defaults 为偏好存储，spaceKey 为当前空间键；返回值：白名单字段字典，不包含凭证、系统通知缓存和图片外发授权。
    static func preferences(defaults: UserDefaults = .standard, spaceKey: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["appearance", "taskDisplayMode", "taskWorkspace", "taskTodoSort", "transactionCategoryListLayout"] {
            if let value = defaults.object(forKey: key) { result[key] = value }
        }
        if let order = defaults.object(forKey: "wallet-order:" + spaceKey) { result["walletOrder"] = order }
        return result
    }
}
