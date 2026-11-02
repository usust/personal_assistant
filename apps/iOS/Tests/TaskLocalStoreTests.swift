import Foundation

/// 独立手工断言入口；仅需与 TaskLocalStore.swift 一起编译，不依赖登录、网络、UIKit 或其他测试入口。
@main
struct TaskLocalStoreTests {
    /// 运行全部测试；参数：无；返回值：无；失败抛错退出，临时测试目录在结束时删除。
    @MainActor
    static func main() throws {
        // 显式使用进程 TMPDIR，避免 Foundation 临时目录缓存绕过测试沙箱提供的路径。
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("TaskLocalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try lifecycle(root)
        try validation(root)
        try treeAndArchive(root)
        try persistenceFailures(root)
        print("TaskLocalStoreTests passed")
    }

    /// 断言条件；参数：condition 为已求值结果，message 为失败原因；返回值：无；失败抛 NSError，不受优化级别影响。
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "TaskLocalStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    /// 验证预期失败；参数：message 为错误上下文，operation 为无参、可抛错、无返回值的测试动作；返回值：无；动作未抛错时令测试失败。
    @MainActor
    private static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        try check(false, message)
    }

    /// 解开成功响应；参数：data 为 Envelope JSON；返回值：data 字段，缺失时抛错，无副作用。
    private static func payload(_ data: Data) throws -> Any {
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = envelope?["data"] else { throw NSError(domain: "TaskLocalStoreTests", code: 2) }
        return value
    }

    /// 请求对象响应；参数：store 为待测仓库，path/method/body 为请求，body 缺省 nil；返回值：业务对象，非对象抛错；写请求按真实仓库执行。
    @MainActor
    private static func object(_ store: TaskLocalStore, _ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) throws -> [String: Any] {
        guard let result = try payload(store.handle(path, method: method, body: body, query: [])) as? [String: Any] else { throw NSError(domain: "TaskLocalStoreTests", code: 3) }
        return result
    }

    /// 请求数组响应；参数：store 为仓库、path 为 GET 路径；返回值：业务对象数组，非数组抛错，无写副作用。
    @MainActor
    private static func rows(_ store: TaskLocalStore, _ path: String) throws -> [[String: Any]] {
        guard let result = try payload(store.handle(path, method: "GET", body: nil, query: [])) as? [[String: Any]] else { throw NSError(domain: "TaskLocalStoreTests", code: 4) }
        return result
    }

    /// 测试基础 CRUD、排序、事件、零值与 ID 持久化；参数：root 为独占临时目录；返回值：无；断言失败抛错，仅写临时文件。
    @MainActor
    private static func lifecycle(_ root: URL) throws {
        let url = root.appendingPathComponent("lifecycle/tasks.json")
        let store = try TaskLocalStore(url: url)
        try check(try rows(store, "/tasks").isEmpty, "新仓库任务应为空")
        try check(try rows(store, "/task-lists").isEmpty, "新仓库清单应为空")
        try check(!FileManager.default.fileExists(atPath: url.path), "读取不得创建文件")
        let list = try object(store, "/task-lists", "POST", ["name": "本机", "remark": "备注"])
        try check(list["id"] as? Int == 1, "首次清单 ID")
        _ = try object(store, "/task-lists/1", "PATCH", ["remark": "", "color": "#123ABC"])
        try check(try object(store, "/task-lists/1")["remark"] as? String == "", "清单空字符串更新")
        let first = try object(store, "/tasks", "POST", ["title": "具体任务", "listId": 1, "taskType": "subtask", "progressTotal": "3", "progressStep": "2", "progressCompleted": "1"])
        try check(first["id"] as? Int == 1, "首次任务 ID")
        _ = try object(store, "/tasks", "POST", ["title": "主任务", "listId": 1])
        _ = try object(store, "/tasks/1", "PATCH", ["archived": true, "autoArchive": true, "remark": "临时"])
        _ = try object(store, "/tasks/1", "PATCH", ["archived": false, "autoArchive": false, "progressCompleted": 0, "remark": ""])
        let zero = try object(store, "/tasks/1")
        try check(zero["archived"] as? Bool == false && zero["autoArchive"] as? Bool == false && zero["progressCompleted"] as? Int == 0 && zero["remark"] as? String == "", "显式零值必须保存")
        try check(zero["title"] as? String == "具体任务" && zero["progressTotal"] as? Int == 3, "未提交字段不得覆盖")
        _ = try object(store, "/tasks/reorder", "PUT", ["taskIds": [2, 1]])
        try check(try rows(store, "/tasks").map { $0["id"] as! Int } == [2, 1], "排序应稳定")
        _ = try object(store, "/tasks/1/progress", "PATCH", ["operation": "increment"])
        try rejects("超总量需确认") { _ = try object(store, "/tasks/1/progress", "PATCH", ["operation": "increment"]) }
        let clamped = try object(store, "/tasks/1/progress", "PATCH", ["operation": "increment", "allowExceedTotal": true])
        try check(clamped["progressCompleted"] as? Int == 3, "确认超量后截断到总量")
        _ = try object(store, "/tasks/1/progress", "PATCH", ["operation": "decrement"])
        let floored = try object(store, "/tasks/1/progress", "PATCH", ["operation": "decrement"])
        try check(floored["progressCompleted"] as? Int == 0, "减量不低于零")
        let exported = try store.exportSnapshot()
        try check(exported == Data(contentsOf: url), "导出必须为完整已持久快照")
        let reopened = try TaskLocalStore(url: url)
        try check(try reopened.exportSnapshot() == exported, "重启不丢数据")
        let events = try rows(reopened, "/tasks/events")
        try check(events.first?["operation"] as? String == "task.progress", "事件倒序")
        try check(events.first?["source"] as? String == "local", "本机事件来源")
        _ = try reopened.handle("/task-lists/1", method: "DELETE", body: nil, query: [])
        try check(try rows(reopened, "/tasks").isEmpty, "清单删除级联删除任务")
        let nextList = try object(reopened, "/task-lists", "POST", ["name": "第二清单"])
        let nextTask = try object(reopened, "/tasks", "POST", ["title": "新任务", "listId": nextList["id"]!])
        try check(nextList["id"] as? Int == 2 && nextTask["id"] as? Int == 3, "删除重启后不可复用 ID")
    }

    /// 测试白名单和非法输入回滚；参数：root 为独占临时目录；返回值：无；所有无效请求必须保持磁盘与内存完全一致。
    @MainActor
    private static func validation(_ root: URL) throws {
        let url = root.appendingPathComponent("validation.json")
        let store = try TaskLocalStore(url: url)
        _ = try object(store, "/task-lists", "POST", ["name": "清单"])
        _ = try object(store, "/tasks", "POST", ["title": "任务", "listId": 1])
        let before = try store.exportSnapshot()
        let invalid: [[String: Any]] = [
            [:], ["title": " "], ["title": NSNull()], ["title": 1], ["id": 2], ["sortOrder": 8], ["isShared": true], ["ownerId": 42],
            ["priority": "invalid"], ["taskType": "todo"], ["progressTotal": 0], ["progressStep": 101], ["progressCompleted": 101],
            ["progressCompleted": -1], ["progressCompleted": 0.5], ["progressCompleted": "1.5"], ["progressCompleted": "nan"], ["progressCompleted": true],
            ["progressTotal": 1_000_000_001], ["listId": true], ["listId": 999], ["parentId": 0], ["archived": 1],
            ["startDate": "2026-02-30"], ["startTime": "09:00"], ["endDate": "2026-11-02", "endTime": "24:00"],
            ["startDate": "2026-11-03", "endDate": "2026-11-02"]
        ]
        for fields in invalid {
            // 回调无参数/返回值；对每组非法 PATCH 断言抛错，不吞掉成功写入。
            try rejects("非法字段未拒绝: \(fields)") { _ = try object(store, "/tasks/1", "PATCH", fields) }
            try check(try store.exportSnapshot() == before, "非法 PATCH 改变了内存")
            try check(try Data(contentsOf: url) == before, "非法 PATCH 改变了文件")
        }
        try rejects("重复排序应失败") { _ = try object(store, "/tasks/reorder", "PUT", ["taskIds": [1, 1]]) }
        try rejects("不存在排序 ID 应回滚") { _ = try object(store, "/tasks/reorder", "PUT", ["taskIds": [1, 99]]) }
        try rejects("空排序应失败") { _ = try object(store, "/tasks/reorder", "PUT", ["taskIds": []]) }
        try rejects("共享标记应保护") { _ = try object(store, "/task-lists/1", "PATCH", ["shared": true]) }
        try rejects("未知路由不得写入") { _ = try store.handle("/tasks/1/unknown", method: "PATCH", body: ["title": "错误"], query: []) }
        try rejects("非法 cascade") { _ = try store.handle("/tasks/1", method: "DELETE", body: nil, query: [URLQueryItem(name: "cascade", value: "maybe")]) }
        try check(try store.exportSnapshot() == before, "错误请求不得创建事件或消耗序列")
        _ = try object(store, "/tasks/1", "PATCH", ["startDate": "2026-11-02", "startTime": "09:00", "endDate": "2026-11-02", "endTime": "09:00"])
        _ = try object(store, "/tasks/1", "PATCH", ["startDate": "", "startTime": "", "endDate": "", "endTime": ""])
        try check(try object(store, "/tasks/1")["startDate"] as? String == "", "允许清除日期")
    }

    /// 测试树移动、循环、聚合归档与删除约束；参数：root 为独占临时目录；返回值：无；失败抛错，仅修改此测试仓库。
    @MainActor
    private static func treeAndArchive(_ root: URL) throws {
        let store = try TaskLocalStore(url: root.appendingPathComponent("tree.json"))
        _ = try object(store, "/task-lists", "POST", ["name": "A"])
        _ = try object(store, "/task-lists", "POST", ["name": "B"])
        _ = try object(store, "/tasks", "POST", ["title": "根", "listId": 1, "autoArchive": true])
        _ = try object(store, "/tasks", "POST", ["title": "子主任务", "listId": 1, "parentId": 1, "autoArchive": true])
        try check(try object(store, "/tasks/1")["archived"] as? Bool == false, "空主任务不可自动归档")
        _ = try object(store, "/tasks", "POST", ["title": "叶", "listId": 1, "parentId": 2, "taskType": "subtask", "progressTotal": 1, "autoArchive": true])
        try rejects("自环必须拒绝") { _ = try object(store, "/tasks/1", "PATCH", ["parentId": 1]) }
        try rejects("祖先不能挂后代") { _ = try object(store, "/tasks/1", "PATCH", ["parentId": 2]) }
        try rejects("叶节点不能作新父级") { _ = try object(store, "/tasks", "POST", ["title": "非法", "listId": 1, "parentId": 3]) }
        try rejects("有下级主任务不可转叶") { _ = try object(store, "/tasks/2", "PATCH", ["taskType": "subtask"]) }
        try rejects("父级跨清单不能移动") { _ = try object(store, "/tasks/2", "PATCH", ["listId": 2]) }
        _ = try object(store, "/tasks/1", "PATCH", ["listId": 2])
        try check(try rows(store, "/tasks").allSatisfy { $0["listId"] as? Int == 2 }, "移动需迁移全部后代")
        try rejects("带子节点删除需要确认") { _ = try store.handle("/tasks/1", method: "DELETE", body: nil, query: []) }
        try rejects("容器禁止直接进度") { _ = try object(store, "/tasks/2/progress", "PATCH", ["operation": "increment"]) }
        let completed = try object(store, "/tasks/3/progress", "PATCH", ["operation": "increment"])
        try check(completed["archived"] as? Bool == true, "响应必须包含即时自动归档")
        try check(try rows(store, "/tasks").allSatisfy { $0["archived"] as? Bool == true }, "归档叶节点计入祖先聚合")
        try rejects("归档叶禁止进度操作") { _ = try object(store, "/tasks/3/progress", "PATCH", ["operation": "decrement"]) }
        _ = try object(store, "/tasks/3", "PATCH", ["archived": false, "autoArchive": false, "progressCompleted": 0])
        try check(try object(store, "/tasks/1")["archived"] as? Bool == true, "撤销完成不自动取消祖先归档")
        _ = try object(store, "/tasks/2", "PATCH", ["parentId": NSNull()])
        try check(try object(store, "/tasks/2")["parentId"] == nil, "显式 null 可移至根")
        let deleted = try payload(store.handle("/tasks/2", method: "DELETE", body: nil, query: [URLQueryItem(name: "cascade", value: "true")])) as! [String: Any]
        try check(deleted["deletedIds"] as? [Int] == [2, 3], "级联删除返回完整 ID")
        try check(deleted["affectedParent"] is NSNull, "删除响应保留后端 null 字段")
        try check(try rows(store, "/tasks").count == 1, "级联删除不能影响无关任务")
    }

    /// 测试损坏文件、未来版本、写入失败及双实例冲突；参数：root 为独占临时目录；返回值：无；任何错误必须保留原数据，不创建替代空库。
    @MainActor
    private static func persistenceFailures(_ root: URL) throws {
        let corruptURL = root.appendingPathComponent("corrupt.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: corruptURL)
        try rejects("损坏文件必须抛错") { _ = try TaskLocalStore(url: corruptURL) }
        try check(try Data(contentsOf: corruptURL) == corrupt, "损坏原文件不得覆盖")
        let blockedParent = root.appendingPathComponent("blocked-parent")
        let blockedStore = try TaskLocalStore(url: blockedParent.appendingPathComponent("tasks.json"))
        let empty = try blockedStore.exportSnapshot()
        try Data("not a directory".utf8).write(to: blockedParent)
        try rejects("父目录为文件时真实落盘必须失败") { _ = try object(blockedStore, "/task-lists", "POST", ["name": "不得发布"]) }
        try check(try blockedStore.exportSnapshot() == empty, "真实磁盘失败不能消耗 ID 或改变内存")
        try check(try String(contentsOf: blockedParent, encoding: .utf8) == "not a directory", "真实磁盘失败不得覆盖阻挡文件")
        let url = root.appendingPathComponent("failure/tasks.json")
        let store = try TaskLocalStore(url: url)
        _ = try object(store, "/task-lists", "POST", ["name": "原始"])
        let second = try TaskLocalStore(url: url)
        _ = try object(store, "/task-lists/1", "PATCH", ["name": "最新"])
        let latest = try Data(contentsOf: url)
        try rejects("陈旧实例不能覆盖最新文件") { _ = try object(second, "/task-lists/1", "PATCH", ["name": "陈旧"]) }
        try check(try Data(contentsOf: url) == latest, "陈旧写覆盖了原文件")
        let before = try store.exportSnapshot()
        let directory = url.deletingLastPathComponent()
        let moved = root.appendingPathComponent("failure-backup")
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data("blocked parent".utf8).write(to: directory)
        try rejects("磁盘失败应抛错") { _ = try object(store, "/task-lists/1", "PATCH", ["name": "不能保存"]) }
        try check(try store.exportSnapshot() == before, "失败不能发布候选内存")
        try check(try Data(contentsOf: moved.appendingPathComponent("tasks.json")) == before, "失败不能影响原数据")
        var future = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        future["version"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: future)
        try futureData.write(to: corruptURL)
        try rejects("未来版本必须拒绝") { _ = try TaskLocalStore(url: corruptURL) }
        try check(try Data(contentsOf: corruptURL) == futureData, "未知版本应原样保留")
        future["version"] = 1
        future["nextListID"] = 1
        try JSONSerialization.data(withJSONObject: future).write(to: corruptURL)
        try rejects("倒退序列必须拒绝") { _ = try TaskLocalStore(url: corruptURL) }
    }
}
