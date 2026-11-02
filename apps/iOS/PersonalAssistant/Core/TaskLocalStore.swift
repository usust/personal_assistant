import Foundation
import CoreFoundation
import Darwin

/// 无登录依赖的本机任务仓库。所有读写在主执行器串行完成；写入失败不发布候选快照。
@MainActor
final class TaskLocalStore {
    /// 本机接口错误；调用方可直接显示 localizedDescription，不把磁盘故障误判为成功。
    enum StoreError: LocalizedError {
        case invalid(String), notFound, conflict(String), unsupported, corrupt, stale

        /// 提供错误文案；参数：无；返回值：简短中文原因，无副作用。
        var errorDescription: String? {
            switch self {
            case .invalid(let message), .conflict(let message): return message
            case .notFound: return "任务或清单不存在"
            case .unsupported: return "不支持的本机任务操作"
            case .corrupt: return "本机任务文件损坏或版本不受支持，原文件已保留"
            case .stale: return "本机任务文件已变化，请重新加载后再试"
            }
        }
    }

    private struct TaskRecord: Codable {
        var id: Int
        var icon = "Folder"
        var title = ""
        var remark = ""
        var listId = 0
        var parentId: Int?
        var taskType = "main"
        var priority = "medium"
        var startDate = ""
        var startTime = ""
        var endDate = ""
        var endTime = ""
        var archived = false
        var autoArchive = false
        var sortOrder = 0
        var progressTotal: Double = 100
        var progressCompleted: Double = 0
        var progressStep: Double = 1
        var progressUnit = ""
    }

    private struct ListRecord: Codable {
        var id: Int
        var name = ""
        var remark = ""
        var color = "#409EFF"
        var icon = "List"
    }

    private struct EventRecord: Codable {
        var id: Int
        var operation: String
        var entityId: Int
        var source = "local"
        var createdAt: String
    }

    /// 独立版本与递增序列防止删除、重启后复用 ID；导出即此结构，不包含账户或令牌。
    private struct Snapshot: Codable {
        var version = 1
        var nextTaskID = 1
        var nextListID = 1
        var nextEventID = 1
        var tasks: [TaskRecord] = []
        var lists: [ListRecord] = []
        var events: [EventRecord] = []
    }

    private struct Response<Value: Encodable>: Encodable { let data: Value }
    private struct DeleteResult: Encodable {
        let deletedIds: [Int]
        private enum CodingKeys: String, CodingKey { case affectedParent, deletedIds }

        /// 编码删除响应；参数：encoder 为响应编码器；返回值：无，编码错误向上传递；显式输出 affectedParent:null 与后端保持一致。
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .affectedParent)
            try container.encode(deletedIds, forKey: .deletedIds)
        }
    }
    private struct ReorderResult: Encodable { let reordered: Int }
    private let url: URL
    private var snapshot: Snapshot
    private var diskData: Data?
    private static let taskFields: Set<String> = ["icon", "title", "remark", "listId", "parentId", "taskType", "priority", "startDate", "startTime", "endDate", "endTime", "archived", "autoArchive", "progressTotal", "progressCompleted", "progressStep", "progressUnit"]
    private static let listFields: Set<String> = ["name", "remark", "color", "icon"]

    /// 打开本机仓库；参数：url 为可注入文件位置，nil 使用 Application Support/Tasks/tasks.json；返回值：无。文件存在但无法解码或校验时抛错，绝不重置或覆盖；不创建默认任务、不要求登录。
    init(url: URL? = nil) throws {
        if let url {
            guard url.isFileURL else { throw StoreError.invalid("任务文件必须为本机路径") }
            self.url = url
        } else {
            self.url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("Tasks", isDirectory: true).appendingPathComponent("tasks.json")
        }
        snapshot = Snapshot()
        if FileManager.default.fileExists(atPath: self.url.path) {
            let data = try Data(contentsOf: self.url)
            do {
                snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                try validateSnapshot(snapshot)
            } catch { throw StoreError.corrupt }
            diskData = data
        }
    }

    /// 导出完整只读快照；参数：无；返回值：含版本、序列、清单、任务和事件的 JSON Data，非 API Envelope。仅复制当前内存，不改文件、不清空数据；编码失败抛错，导入另行实现。
    func exportSnapshot() throws -> Data { try encode(snapshot) }

    /// 执行本机任务 API；参数：path 为 /tasks 或 /task-lists 路径，method 为 HTTP 方法，body 为提交字段（nil 代表无），query 为查询参数；返回值：兼容 Envelope(data) 的 JSON。写操作验证后原子落盘，失败保留文件及内存；未知路径/字段抛错，不访问登录或网络。
    func handle(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem]) throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        let method = method.uppercased()
        guard parts.first == "tasks" || parts.first == "task-lists", !path.contains("?"), parts.count <= 3 else { throw StoreError.unsupported }
        let tasks = parts[0] == "tasks"
        if method == "GET" {
            if parts == ["tasks", "events"] {
                return try response(Array(snapshot.events.reversed().prefix(100)))
            }
            if parts.count == 1 {
                if tasks {
                    // 排序比较输入为两个任务，输出稳定顺序；相同 sortOrder 按持久 ID 决胜，与后端一致。
                    return try response(snapshot.tasks.sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder })
                }
                return try response(snapshot.lists.sorted { $0.id < $1.id })
            }
            guard parts.count == 2, let id = Int(parts[1]), id > 0 else { throw StoreError.unsupported }
            if tasks {
                guard let row = snapshot.tasks.first(where: { $0.id == id }) else { throw StoreError.notFound }
                return try response(row)
            }
            guard let row = snapshot.lists.first(where: { $0.id == id }) else { throw StoreError.notFound }
            return try response(row)
        }

        // 值类型事务：业务变更、自动归档、事件及序列先写候选；编码与磁盘替换成功才发布。
        var candidate = snapshot
        let result: Data
        var eventID = 0
        let operation: String
        if parts == ["tasks", "reorder"], method == "PUT" {
            guard let body, Set(body.keys) == ["taskIds"], let rawIDs = body["taskIds"] as? [Any], !rawIDs.isEmpty, rawIDs.count <= 1000 else { throw StoreError.invalid("排序需要 1 至 1000 个任务") }
            var seen = Set<Int>()
            for (position, value) in rawIDs.enumerated() {
                let id = try integer(value)
                guard seen.insert(id).inserted else { throw StoreError.invalid("排序 ID 重复") }
                guard let index = candidate.tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
                candidate.tasks[index].sortOrder = position
            }
            result = try response(ReorderResult(reordered: rawIDs.count))
            operation = "task.reorder"
        } else if parts.count == 1, method == "POST" {
            if tasks {
                var row = try patch(TaskRecord(id: candidate.nextTaskID), body: body, allowed: Self.taskFields)
                row.sortOrder = candidate.tasks.count
                try validateTask(row)
                try validatePlacement(row, previous: nil, in: candidate)
                candidate.nextTaskID = try nextID(candidate.nextTaskID)
                candidate.tasks.append(row)
                autoArchive(&candidate)
                result = try response(candidate.tasks[candidate.tasks.count - 1])
                operation = "task.create"
                eventID = row.id
            } else {
                let row = try patch(ListRecord(id: candidate.nextListID), body: body, allowed: Self.listFields)
                try validateList(row)
                candidate.nextListID = try nextID(candidate.nextListID)
                candidate.lists.append(row)
                result = try response(row)
                operation = "task_list.create"
                eventID = row.id
            }
        } else {
            guard parts.count >= 2, let id = Int(parts[1]), id > 0 else { throw StoreError.unsupported }
            eventID = id
            if tasks {
                guard let index = candidate.tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
                let previous = candidate.tasks[index]
                if parts.count == 3, parts[2] == "progress", method == "PATCH" {
                    guard let body, Set(body.keys).isSubset(of: ["operation", "allowExceedTotal"]), let action = body["operation"] as? String, ["increment", "decrement"].contains(action) else { throw StoreError.invalid("进度操作无效") }
                    let allow = try boolean(body["allowExceedTotal"] ?? false)
                    guard !previous.archived, previous.taskType == "subtask", !candidate.tasks.contains(where: { $0.parentId == id }) else { throw StoreError.conflict("仅未归档的具体叶任务可调整进度") }
                    var value = max(0, ((previous.progressCompleted + (action == "increment" ? previous.progressStep : -previous.progressStep)) * 100).rounded() / 100)
                    if value > previous.progressTotal {
                        guard allow else { throw StoreError.conflict("进度将超过总量") }
                        value = previous.progressTotal
                    }
                    candidate.tasks[index].progressCompleted = value
                    autoArchive(&candidate)
                    result = try response(candidate.tasks[index])
                    operation = "task.progress"
                } else if parts.count == 2, method == "PATCH" {
                    let row = try patch(previous, body: body, allowed: Self.taskFields)
                    try validateTask(row)
                    try validatePlacement(row, previous: previous, in: candidate)
                    candidate.tasks[index] = row
                    if previous.listId != row.listId {
                        let descendants = descendantIDs(id, in: candidate)
                        for childIndex in candidate.tasks.indices where descendants.contains(candidate.tasks[childIndex].id) {
                            candidate.tasks[childIndex].listId = row.listId
                        }
                    }
                    autoArchive(&candidate)
                    result = try response(candidate.tasks[index])
                    operation = "task.update"
                } else if parts.count == 2, method == "DELETE" {
                    let cascadeValues = query.filter { $0.name == "cascade" }
                    guard cascadeValues.count <= 1 else { throw StoreError.invalid("cascade 无效") }
                    let cascade = try queryBoolean(cascadeValues.first?.value)
                    let ids = descendantIDs(id, in: candidate)
                    guard cascade || ids.count == 1 else { throw StoreError.conflict("任务有下级，请确认级联删除") }
                    candidate.tasks.removeAll { ids.contains($0.id) }
                    result = try response(DeleteResult(deletedIds: ids.sorted()))
                    operation = "task.delete"
                } else { throw StoreError.unsupported }
            } else {
                guard parts.count == 2 else { throw StoreError.unsupported }
                guard let index = candidate.lists.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
                if method == "PATCH" {
                    let row = try patch(candidate.lists[index], body: body, allowed: Self.listFields)
                    try validateList(row)
                    candidate.lists[index] = row
                    result = try response(row)
                    operation = "task_list.update"
                } else if method == "DELETE" {
                    candidate.lists.remove(at: index)
                    candidate.tasks.removeAll { $0.listId == id }
                    result = try response(Optional<Int>.none)
                    operation = "task_list.delete"
                } else { throw StoreError.unsupported }
            }
        }
        candidate.events.append(EventRecord(id: candidate.nextEventID, operation: operation, entityId: eventID, createdAt: ISO8601DateFormatter().string(from: Date())))
        candidate.nextEventID = try nextID(candidate.nextEventID)
        try persist(candidate)
        return result
    }

    /// 计算下一序列；参数：id 为当前正整数；返回值：加一后的 ID；耗尽时抛错，避免溢出崩溃及复用。
    private func nextID(_ id: Int) throws -> Int {
        guard id > 0, id < Int.max else { throw StoreError.conflict("本机任务编号已耗尽") }
        return id + 1
    }

    /// 编码数据；类型参数 T 为 Encodable 值；参数：value 为待编码快照或响应；返回值：稳定排序的 JSON；失败抛错，无副作用。
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// 包装 API 响应；类型参数 T 为 Encodable 业务结果；参数：value 为结果；返回值：Envelope(data) JSON，编码失败抛错，无副作用。
    private func response<T: Encodable>(_ value: T) throws -> Data { try encode(Response(data: value)) }

    /// 原子提交候选快照；参数：candidate 为已经验证的完整事务；返回值：无。磁盘变化、编码或文件保护写入失败抛错，不替换内存；iOS 写入时同时设置完整文件保护，不在替换原文件后执行可能失败的保护设置。
    private func persist(_ candidate: Snapshot) throws {
        let bytes = try encode(candidate)
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == diskData else { throw StoreError.stale }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 临时文件与目标同目录，保证 rename 为同卷原子替换；保护与同步均在替换前完成。
        let temporary = directory.appendingPathComponent(".tasks-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try bytes.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        #else
        try bytes.write(to: temporary, options: .withoutOverwriting)
        #endif
        let file = try FileHandle(forWritingTo: temporary)
        do {
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        snapshot = candidate
        diskData = bytes
    }

    /// 将已提交白名单字段合入候选对象；类型参数 T 为 Codable 记录；参数：original 为原记录，body 为非空 PATCH/POST 对象，allowed 为合法键；返回值：新记录。仅合并实际提交字段，保留 false/0/空字符串，只有 parentId 允许 null；拒绝共享标记、ID 等非白名单字段，失败无副作用。
    private func patch<T: Codable>(_ original: T, body: [String: Any]?, allowed: Set<String>) throws -> T {
        guard let body, !body.isEmpty else { throw StoreError.invalid("必须提交非空字段对象") }
        var fields: [String: Any] = [:]
        for (key, value) in body {
            guard allowed.contains(key) else { throw StoreError.invalid("不允许更新字段: \(key)") }
            guard !(value is NSNull) || key == "parentId" else { throw StoreError.invalid("\(key) 不允许 null") }
            if ["progressTotal", "progressCompleted", "progressStep"].contains(key) {
                let number: Double?
                if let text = value as? String { number = Double(text) }
                else if let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() { number = numeric.doubleValue }
                else { number = nil }
                guard let number, number.isFinite, number >= 0, number <= 1_000_000_000, number.rounded(.towardZero) == number else { throw StoreError.invalid("进度必须为不超过十亿的自然数") }
                fields[key] = number
            } else {
                if key == "listId" || (key == "parentId" && !(value is NSNull)) { _ = try integer(value) }
                if key == "archived" || key == "autoArchive" { _ = try boolean(value) }
                fields[key] = value
            }
        }
        guard var object = try JSONSerialization.jsonObject(with: encode(original)) as? [String: Any] else { throw StoreError.corrupt }
        for (key, value) in fields { object[key] = value }
        do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch { throw StoreError.invalid("字段类型错误") }
    }

    /// 校验 JSON 整数；参数：value 为数字值，不允许布尔、字符串、零或负数；返回值：正 Int，非法或越界抛错，无副作用。
    private func integer(_ value: Any) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let result = Int(number.stringValue), result > 0 else { throw StoreError.invalid("编号必须为正整数") }
        return result
    }

    /// 校验 JSON 布尔；参数：value 必须为真布尔而非 0/1；返回值：Bool，类型错误抛错，无副作用。
    private func boolean(_ value: Any) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw StoreError.invalid("字段必须为布尔值") }
        return number.boolValue
    }

    /// 解析删除查询；参数：value 为可选 cascade 文本；返回值：后端 ParseBool 兼容值，缺省 false，非法抛错，无副作用。
    private func queryBoolean(_ value: String?) throws -> Bool {
        guard let value, !value.isEmpty else { return false }
        if ["1", "t", "T", "true", "TRUE", "True"].contains(value) { return true }
        if ["0", "f", "F", "false", "FALSE", "False"].contains(value) { return false }
        throw StoreError.invalid("cascade 无效")
    }

    /// 验证清单业务值；参数：row 为合并后的清单；返回值：无；名称、备注、图标或颜色非法抛错，无副作用。
    private func validateList(_ row: ListRecord) throws {
        guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.name.unicodeScalars.count <= 128, row.remark.unicodeScalars.count <= 2000,
              !row.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.icon.utf8.count <= 64,
              row.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw StoreError.invalid("清单名称、备注、图标或颜色无效") }
    }

    /// 验证任务业务值；参数：row 为完整候选任务；返回值：无；非法文案、类型、进度或日期抛错。保留后端对历史小数进度的兼容，新增/修改的进度字段由 patch 强制自然数。
    private func validateTask(_ row: TaskRecord) throws {
        guard !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.title.unicodeScalars.count <= 256, row.remark.unicodeScalars.count <= 10000, row.progressUnit.unicodeScalars.count <= 20,
              !row.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.icon.utf8.count <= 64 else { throw StoreError.invalid("标题、备注、图标或单位长度无效") }
        guard ["main", "subtask"].contains(row.taskType), ["high", "medium", "low"].contains(row.priority) else { throw StoreError.invalid("任务类型或优先级无效") }
        guard row.progressTotal.isFinite, row.progressCompleted.isFinite, row.progressStep.isFinite,
              row.progressTotal > 0, row.progressTotal <= 1_000_000_000, row.progressStep > 0, row.progressStep <= row.progressTotal,
              row.progressCompleted >= 0, row.progressCompleted <= row.progressTotal else { throw StoreError.invalid("进度总量和步长必须为正数，步长及完成量不能超过总量") }
        for (date, time) in [(row.startDate, row.startTime), (row.endDate, row.endTime)] {
            if !date.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                      let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw StoreError.invalid("日期格式应为 YYYY-MM-DD") }
            }
            if !time.isEmpty {
                guard !date.isEmpty, time.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { throw StoreError.invalid("时间必须附带日期且格式为 HH:mm") }
            }
        }
        let start = row.startDate + " " + (row.startTime.isEmpty ? "00:00" : row.startTime)
        let end = row.endDate + " " + (row.endTime.isEmpty ? "23:59" : row.endTime)
        guard row.startDate.isEmpty || row.endDate.isEmpty || start <= end else { throw StoreError.invalid("结束时间不能早于开始时间") }
    }

    /// 校验树关系与类型转换；参数：row 为新值，previous 为旧值（新建 nil），state 为当前候选快照；返回值：无。拒绝不存在清单、跨清单父级及环；历史具体任务容器允许普通编辑，但新挂载必须选择主任务。
    private func validatePlacement(_ row: TaskRecord, previous: TaskRecord?, in state: Snapshot) throws {
        guard state.lists.contains(where: { $0.id == row.listId }) else { throw StoreError.notFound }
        if previous?.taskType == "main", row.taskType != "main", state.tasks.contains(where: { $0.parentId == row.id }) { throw StoreError.invalid("有下级的主任务不能改为具体任务") }
        var visited: Set<Int> = [row.id]
        var parentID = row.parentId
        while let id = parentID {
            guard visited.insert(id).inserted else { throw StoreError.invalid("父级关系循环") }
            guard let parent = state.tasks.first(where: { $0.id == id }) else { throw StoreError.notFound }
            guard parent.listId == row.listId else { throw StoreError.invalid("父级不能跨清单") }
            if id == row.parentId, previous == nil || previous?.parentId != row.parentId {
                guard parent.taskType == "main" else { throw StoreError.invalid("父级必须为主任务") }
            }
            parentID = parent.parentId
        }
    }

    /// 收集整棵子树；参数：id 为根任务 ID，state 为快照；返回值：含根的 ID 集合；迭代遍历避免深层递归溢出，并以集合阻止历史循环。
    private func descendantIDs(_ id: Int, in state: Snapshot) -> Set<Int> {
        var result: Set<Int> = [id]
        var queue = [id]
        var cursor = 0
        let children = Dictionary(grouping: state.tasks, by: \.parentId)
        while cursor < queue.count {
            for child in children[queue[cursor]] ?? [] where result.insert(child.id).inserted { queue.append(child.id) }
            cursor += 1
        }
        return result
    }

    /// 聚合具体叶节点并自动归档；参数：state 为可修改候选快照；返回值：无。包括归档叶节点，空主任务贡献零，只归档满足条件的节点、不级联归档孩子，取消自动归档不会自动恢复已归档记录。
    private func autoArchive(_ state: inout Snapshot) {
        let parentIDs = Set(state.tasks.compactMap(\.parentId))
        var totals: [Int: Double] = [:]
        var completed: [Int: Double] = [:]
        let byID = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        for leaf in state.tasks where leaf.taskType == "subtask" && !parentIDs.contains(leaf.id) {
            var current: Int? = leaf.id
            var visited = Set<Int>()
            while let id = current, visited.insert(id).inserted, let row = byID[id] {
                // 与后端按百分之一汇总；使用 Double 避免大量任务累加整数溢出。
                totals[id, default: 0] += (leaf.progressTotal * 100).rounded()
                completed[id, default: 0] += (leaf.progressCompleted * 100).rounded()
                current = row.parentId
            }
        }
        for index in state.tasks.indices {
            let row = state.tasks[index]
            if row.autoArchive, !row.archived, let total = totals[row.id], total > 0, (completed[row.id] ?? 0) >= total { state.tasks[index].archived = true }
        }
    }

    /// 校验磁盘结构；参数：state 为已解码快照；返回值：无。拒绝未来版本、重复 ID、倒退序列、孤儿及环，避免损坏文件进入写路径；不修复或覆盖原文件。
    private func validateSnapshot(_ state: Snapshot) throws {
        let taskIDs = state.tasks.map(\.id), listIDs = state.lists.map(\.id), eventIDs = state.events.map(\.id)
        guard state.version == 1, Set(taskIDs).count == taskIDs.count, Set(listIDs).count == listIDs.count, Set(eventIDs).count == eventIDs.count,
              state.nextTaskID > (taskIDs.max() ?? 0), state.nextListID > (listIDs.max() ?? 0), state.nextEventID > (eventIDs.max() ?? 0),
              taskIDs.allSatisfy({ $0 > 0 }), listIDs.allSatisfy({ $0 > 0 }), eventIDs.allSatisfy({ $0 > 0 }), eventIDs == eventIDs.sorted() else { throw StoreError.corrupt }
        for row in state.lists { try validateList(row) }
        for row in state.tasks {
            try validateTask(row)
            try validatePlacement(row, previous: row, in: state)
        }
    }
}
