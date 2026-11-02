import Foundation

@MainActor
enum DataBackupTests {
    static var count = 0

    /// 验证备份断言；参数：condition 为断言结果，name 为案例名；返回值：无；失败终止测试，不访问真实数据。
    private static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        count += 1
        print("PASS \(name)")
    }

    /// 验证导出失败；参数：name 为断言名，operation 为预期抛错的无参生成回调；返回值：无；未抛错时终止测试，回调只处理虚构数据。
    private static func rejects(_ name: String, operation: () throws -> Data) {
        do { _ = try operation(); check(false, name) }
        catch { check(true, name) }
    }

    /// 创建完整服务端导出信封；参数：无；返回值：无凭证的虚构跨模块备份，包含大整数、金额、删除记录和内部扩展字段；无外部副作用。
    private static func serverFixture() -> [String: Any] {
        let task: [String: Any] = ["lists": [["id": 9]], "tasks": [["id": 10, "listId": 9, "parentId": NSNull(), "archived": true]], "events": [["id": 11]]]
        let finance: [String: Any] = ["accounts": [["id": Int64(9_007_199_254_740_993), "balance": "999999999999.99", "loanScheduleJSON": "[]"]], "categories": [["id": 15, "deleted": true, "nameVersion": 15]], "transactions": [["id": 16, "categoryId": 15, "amount": "0.01", "deleted": true]], "presets": [], "events": [], "snapshots": []]
        let health: [String: Any] = ["days": [["date": "2020-01-01", "steps": 100]], "reports": [["id": 17, "report": "旧报告"]], "meals": [["id": "meal-fixture", "date": "2020-01-01"]], "nutritionGoals": [["daily_goal": 2000]]]
        let data: [String: Any] = [
            "format": DataBackup.format, "schemaVersion": 1, "exportedAt": "2026-10-18T10:00:00.123456789Z",
            "source": ["owner": ["id": 42, "account": "fixture", "nickname": "测试"]],
            "task": task, "finance": finance, "health": health,
            "modelConfigs": [["id": 18, "name": "自用配置"]], "futureField": ["preserve": true]
        ]
        return ["code": 200, "message": "ok", "data": data]
    }

    /// 执行格式回归；参数：无；返回值：无；只使用虚构 JSON 和内存偏好域，覆盖空间隔离、不可变队列快照、精度、全部集合及错误拒绝，不读取数据库、实际账号或卡号。
    static func run() throws {
        let key = "https://fixture.invalid/api#42"
        var space: [String: Any] = ["accounts": [[String: Any]](), "categories": [[String: Any]](), "transactions": [[String: Any]](), "presets": [[String: Any]](), "queue": [[String: Any]]()]
        space["accounts"] = [["id": Int64(8_000_000_000_000_001), "balance": "123456789.01", "cards": [["number": "1234567890123456"]]]]
        space["categories"] = [["id": 15, "deleted": true]]
        space["transactions"] = [["id": Int64(8_000_000_000_000_002), "categoryId": 15]]
        space["queue"] = [["operationId": "operation-fixture", "entityId": Int64(8_000_000_000_000_001), "body": ["amount": "0.01"]]]
        space["aliases"] = ["8000000000000001": 1]
        space["screenshotBookkeeping"] = ["settings": ["enabled": true], "jobs": [["id": "job-fixture", "image": "old-image-must-not-export", "state": "review"]]]
        let suite = "backup-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.register(defaults: ["appearance": "dark", "token": "secret-never-export", "wallet-order:" + key: ["1", "2"]])
        defer { defaults.removeVolatileDomain(forName: UserDefaults.registrationDomain) }
        let preferences = DataBackup.preferences(defaults: defaults, spaceKey: key)
        check(preferences["token"] == nil && preferences["appearance"] as? String == "dark", "备份仅导出白名单偏好")
        check(preferences["walletOrder"] as? [String] == ["1", "2"], "备份保留当前空间卡片排序")
        let local = try DataBackup.captureLocal(key: key, space: space, preferences: preferences, date: Date(timeIntervalSince1970: 1), appVersion: "test", build: "1")
        // 捕获后模拟同步确认、删除队列；文件必须继续保有之前捕获的独立命令，不依赖可变内存。
        space["queue"] = [[String: Any]]()
        let data = try DataBackup.makeFile(local: local, server: nil, ownerID: nil, serverURL: "https://fixture.invalid/api")
        let file = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let client = file["client"] as! [String: Any]
        let savedLedger = client["financeLedger"] as! [String: Any]
        let savedSpaces = savedLedger["spaces"] as! [String: [String: Any]]
        let saved = savedSpaces[key]!
        check(savedSpaces.count == 1 && savedSpaces[key] != nil, "文件只包含当前空间及其绑定")
        check((saved["queue"] as! [[String: Any]]).first?["operationId"] as? String == "operation-fixture", "捕获后确认同步不丢备份中的待上传队列")
        check((saved["aliases"] as! [String: Int])["8000000000000001"] == 1, "备份保留离线别名及原始 ID")
        let account = (saved["accounts"] as! [[String: Any]])[0]
        check((account["id"] as! NSNumber).int64Value == 8_000_000_000_000_001 && account["balance"] as? String == "123456789.01", "备份保留本机大整数 ID 和精确金额")
        check((account["cards"] as! [[String: Any]])[0]["number"] as? String == "1234567890123456", "备份保留仅本机完整卡号")
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("secret-never-export") && !text.contains("old-image-must-not-export"), "备份不带非白名单凭证或截图图片")
        check(file["scope"] as? String == "local" && file["task"] == nil, "离线文件明确标记仅本机范围")
        let originalBook = space["screenshotBookkeeping"] as! [String: Any]
        check((originalBook["jobs"] as! [[String: Any]])[0]["image"] as? String == "old-image-must-not-export", "剔除备份图片不修改源字典")
        let fixture = serverFixture()
        let server = try JSONSerialization.data(withJSONObject: fixture)
        let full = try DataBackup.makeFile(local: local, server: server, ownerID: 42, serverURL: "https://fixture.invalid/api")
        let complete = try JSONSerialization.jsonObject(with: full) as! [String: Any]
        let finance = complete["finance"] as! [String: Any]
        let cloudAccount = (finance["accounts"] as! [[String: Any]])[0]
        check((cloudAccount["id"] as! NSNumber).int64Value == 9_007_199_254_740_993 && cloudAccount["balance"] as? String == "999999999999.99", "云端 JSON 重编码不丢大整数或金额精度")
        check((finance["categories"] as! [[String: Any]])[0]["deleted"] as? Bool == true && cloudAccount["loanScheduleJSON"] as? String == "[]", "导出保留分类墓碑与恢复所需内部字段")
        check(complete["scope"] as? String == "account" && complete["futureField"] != nil && complete["modelConfigs"] != nil && complete["health"] != nil && complete["task"] != nil, "完整备份保留所有模块及未知扩展字段")
        check(complete["serverExportedAt"] as? String == "2026-10-18T10:00:00.123456789Z" && client["capturedAt"] as? String == "1970-01-01T00:00:01.000Z", "文件记录本机与服务端各自快照时间")
        rejects("跨账号服务端数据拒绝导出") { try DataBackup.makeFile(local: local, server: server, ownerID: 99, serverURL: "https://fixture.invalid/api") }
        var newer = fixture
        var newerData = newer["data"] as! [String: Any]; newerData["schemaVersion"] = 2; newer["data"] = newerData
        rejects("未知未来协议拒绝导出") { try DataBackup.makeFile(local: local, server: JSONSerialization.data(withJSONObject: newer), ownerID: 42, serverURL: "https://fixture.invalid/api") }
        var incomplete = fixture
        var incompleteData = incomplete["data"] as! [String: Any]; incompleteData.removeValue(forKey: "health"); incomplete["data"] = incompleteData
        rejects("云端缺模块不能生成成功备份") { try DataBackup.makeFile(local: local, server: JSONSerialization.data(withJSONObject: incomplete), ownerID: 42, serverURL: "https://fixture.invalid/api") }
        rejects("错误信封不能生成空备份") { try DataBackup.makeFile(local: local, server: Data("{\"code\":500,\"data\":null}".utf8), ownerID: 42, serverURL: "https://fixture.invalid/api") }
        rejects("损坏本机快照拒绝导出") { try DataBackup.makeFile(local: Data("{}".utf8), server: nil, ownerID: nil, serverURL: "https://fixture.invalid/api") }
        var invalid = space; invalid.removeValue(forKey: "queue")
        rejects("队列缺失不静默丢本机数据") { try DataBackup.captureLocal(key: "guest", space: invalid, preferences: [:], appVersion: "test", build: "1") }
        check(DataBackup.filename(date: Date(timeIntervalSince1970: 1)) == "PersonalAssistant-backup-19700101-000001-000.json", "默认文件名稳定且不包含个人身份")
        print("DataBackupTests: \(count) passed")
    }
}

#if DATA_BACKUP_TEST_MAIN
@main
struct DataBackupTestRunner {
    /// 独立运行格式测试；参数：无；返回值：无；失败抛错并以非零状态退出，不需要 Swift 宏插件或模拟器。
    @MainActor static func main() throws { try DataBackupTests.run() }
}
#endif
