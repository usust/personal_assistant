import Foundation

/// 独立离线可执行测试；仅编译 HealthLocalStore.swift 与本文件，不链接 APIClient/URLSession。
@main struct HealthLocalStoreTests {
    /// 执行仓库回归；参数：无；返回值：无；失败抛错或断言终止，仅使用临时目录，不访问真实健康数据或网络。
    @MainActor static func main() throws {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = temporary.appendingPathComponent("health-local-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("records.json")
        let store = try HealthLocalStore(url: url)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let query = [URLQueryItem(name: "date", value: today)]
        let empty = try payload(store.handle("/health-management/nutrition", method: "GET", query: query)) as! [String: Any]
        precondition(empty["daily_goal"] is NSNull && (empty["meals"] as! [Any]).isEmpty)
        _ = try store.handle("/health-management/sync", method: "POST", body: ["days": [["date": today, "timezone": "UTC", "steps": 24, "weight": 70]]])
        _ = try store.handle("/health-management/sync", method: "POST", body: ["days": [["date": today, "timezone": "UTC", "steps": 0, "distance": NSNull()]]])
        precondition(store.snapshot.days.count == 1 && store.snapshot.days[0].steps == 0 && store.snapshot.days[0].weight == nil)
        _ = try store.handle("/health-management/nutrition/goal", method: "PUT", body: ["daily_goal": 2000])
        let id = UUID().uuidString
        let meal: [String: Any] = ["id": id, "date": today, "meal_type": "lunch", "items": [["name": "测试食物", "grams": 100, "calories": 200]], "note": ""]
        let first = try store.handle("/health-management/meals", method: "POST", body: meal)
        let second = try store.handle("/health-management/meals", method: "POST", body: meal)
        precondition(first == second && store.snapshot.meals.count == 1)
        let report = try store.saveGeneratedReport(content: "测试报告", snapshot: "[]", configID: 3)
        let beforeRestart = store.snapshot
        let mealList = try payload(store.handle("/health-management/meals", method: "GET", query: query)) as! [Any]
        let reportList = try payload(store.handle("/health-management/reports", method: "GET")) as! [Any]
        let goal = try payload(store.handle("/health-management/nutrition/goal", method: "GET")) as! [String: Any]
        precondition(mealList.count == 1 && reportList.count == 1 && goal["daily_goal"] as? Double == 2000)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restarted = try HealthLocalStore(url: url)
        precondition(restarted.snapshot == beforeRestart)
        let overview = try payload(restarted.handle("/health-management", method: "GET")) as! [String: Any]
        precondition((overview["days"] as! [Any]).count == 1 && (overview["reports"] as! [Any]).count == 1)
        let nutrition = try payload(restarted.handle("/health-management/nutrition", method: "GET", query: query)) as! [String: Any]
        precondition(nutrition["daily_goal"] as? Double == 2000 && (nutrition["meals"] as! [Any]).count == 1)
        let readReport = try payload(restarted.handle("/health-management/reports/\(report.id)", method: "GET")) as! [String: Any]
        precondition(readReport["content"] as? String == "测试报告")
        try mustThrow { _ = try restarted.handle("/health-management/nutrition/goal", method: "PUT", body: ["daily_goal": 0]) }
        try mustThrow { _ = try restarted.handle("/health-management/sync", method: "POST", body: ["days": [["date": today, "timezone": "UTC", "steps": true]]]) }
        try mustThrow { _ = try restarted.handle("/health-management/sync", method: "POST", body: ["days": [["date": today, "timezone": "UTC", "steps": -1]]]) }
        try mustThrow { _ = try restarted.handle("/health-management/nutrition", method: "GET", query: [URLQueryItem(name: "date", value: "2026-02-30")]) }
        var conflicting = meal; conflicting["note"] = "不同内容"
        try mustThrow { _ = try restarted.handle("/health-management/meals", method: "POST", body: conflicting) }
        var unknown = meal; unknown["image"] = "不应保存"
        try mustThrow { _ = try restarted.handle("/health-management/meals", method: "POST", body: unknown) }
        try mustThrow { _ = try restarted.handle("/health-management/sync", method: "POST", body: ["days": [["date": today, "timezone": "UTC", "steps": 1], ["date": today, "timezone": "UTC", "steps": 2]]]) }
        precondition(restarted.snapshot == beforeRestart)
        let afterInvalid = try HealthLocalStore(url: url)
        precondition(afterInvalid.snapshot == beforeRestart)
        precondition(!HealthLocalStore.handles("/health-management/reports", method: "POST"))
        precondition(!HealthLocalStore.handles("/health-management/meal-analysis", method: "POST"))
        try mustThrow { _ = try restarted.handle("/health-management/reports", method: "POST") }
        try mustThrow { _ = try restarted.handle("/health-management/meal-analysis", method: "POST") }
        _ = try restarted.handle("/health-management/meals/\(id)", method: "DELETE")
        _ = try restarted.handle("/health-management/meals/\(id)", method: "DELETE")
        _ = try restarted.handle("/health-management/reports/\(report.id)", method: "DELETE")
        precondition(restarted.snapshot.meals.isEmpty && restarted.snapshot.reports.isEmpty)
        try mustThrow { _ = try restarted.handle("/health-management/reports/\(report.id)", method: "GET") }
        // 旧实例不得覆盖已提交的新状态。
        try mustThrow { _ = try store.saveGeneratedReport(content: "旧实例") }
        _ = try restarted.handle("/health-management", method: "DELETE")
        let cleared = try HealthLocalStore(url: url).snapshot
        precondition(cleared.days.isEmpty && cleared.meals.isEmpty && cleared.reports.isEmpty && cleared.daily_goal == nil)
        // 损坏和未来版本均必须失败且原字节保持不变。
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        try mustThrow { _ = try HealthLocalStore(url: url) }
        try mustThrow { _ = try restarted.saveGeneratedReport(content: "不得覆盖损坏文件") }
        let retained = try Data(contentsOf: url); precondition(retained == corrupt)
        let future = Data("{\"version\":99}".utf8)
        try future.write(to: url)
        try mustThrow { _ = try HealthLocalStore(url: url) }
        let retainedFuture = try Data(contentsOf: url); precondition(retainedFuture == future)
        // 写入失败不能先修改内存：让父路径成为普通文件。
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let unwritable = try HealthLocalStore(url: blocker.appendingPathComponent("records.json"))
        try mustThrow { _ = try unwritable.saveGeneratedReport(content: "无法保存") }
        precondition(unwritable.snapshot.reports.isEmpty)
        print("HealthLocalStoreTests passed: offline CRUD, restart, zero/null, validation, idempotency, AI exclusion, corruption, version, stale writer, rollback")
    }

    /// 读取成功信封；参数：data 为本地 API 返回；返回值：data 字段 JSON 值；格式不符抛错或断言失败，无副作用。
    static func payload(_ data: Data) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Set(object.keys) == ["data"])
        return object["data"]!
    }
    /// 断言操作失败；参数：operation 为预期抛错的主线程闭包，输入与返回值均无；返回值：无；意外成功会终止测试，不吞断言。
    @MainActor static func mustThrow(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        preconditionFailure("Expected an error")
    }
}
