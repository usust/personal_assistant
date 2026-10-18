import Foundation

/// 任务本机展示偏好；仅控制浏览，不改变清单、归档范围或服务端数据。
nonisolated enum TaskDisplayMode: String, CaseIterable {
    case tree
    case levels

    static let storageKey = "taskDisplayMode"

    /// 展示选项名称；参数：无；返回值：简短中文名称；无副作用。
    var title: String { self == .tree ? "树状展示" : "逐级展示" }
}

/// 待办的智能范围；只改变显示，不新增独立任务数据或改变任务树。
nonisolated enum TaskTodoFilter: String, CaseIterable {
    case pending, today, overdue, upcoming, important, unscheduled, completed

    /// 读取范围名称；参数：无；返回值：界面显示的简短名称；无副作用。
    var title: String {
        switch self {
        case .pending: return "待办"
        case .today: return "今日"
        case .overdue: return "逾期"
        case .upcoming: return "近七天"
        case .important: return "重要"
        case .unscheduled: return "未安排"
        case .completed: return "已完成"
        }
    }
}

/// 待办排序偏好；排序不回写任务树，手动顺序沿用服务端完整快照。
nonisolated enum TaskTodoSort: String, CaseIterable {
    case deadline, priority, manual

    /// 读取排序名称；参数：无；返回值：排序菜单文案；无副作用。
    var title: String {
        switch self {
        case .deadline: return "截止时间"
        case .priority: return "优先级"
        case .manual: return "清单顺序"
        }
    }
}

/// 待办分组顺序；仅对可执行叶节点分组，容器仍在任务树中浏览。
nonisolated enum TaskTodoGroup: String, CaseIterable {
    case overdue, today, scheduled, anytime, completed

    /// 读取分组名称；参数：无；返回值：列表分组标题；无副作用。
    var title: String {
        switch self {
        case .overdue: return "已逾期"
        case .today: return "今日安排"
        case .scheduled: return "接下来"
        case .anytime: return "未安排"
        case .completed: return "已完成"
        }
    }
}

/// 日常待办的纯规则；复用已存在的具体任务与进度，不引入第二套持久化或伪造完成日期。
nonisolated enum TaskTodoRules {
    /// 获取可执行任务；参数：all 为同一身份的完整快照，listID 为清单 ID、0 表示全部；返回值：排除归档祖先、主任务及历史容器的具体叶节点；无副作用。
    static func actionable(in all: [AssistantTask], listID: Int = 0) -> [AssistantTask] {
        let parents = Set(all.compactMap(\.parentId))
        return Values.tasks(in: "active", all: all, listID: listID).filter {
            $0.taskType == "subtask" && !parents.contains($0.id)
        }
    }

    /// 判断叶任务完成；参数：task 为具体叶节点；返回值：有效总量已达到时 true；无副作用。
    static func isCompleted(_ task: AssistantTask) -> Bool {
        task.progressTotal > 0 && task.progressCompleted >= task.progressTotal
    }

    /// 判断今日安排；参数：task 为任务，now 为可注入本地当前时间；返回值：开始或截止恰为今天时 true，不将所有历史完成任务算作今日完成；无副作用。
    static func isScheduledToday(_ task: AssistantTask, now: Date) -> Bool {
        task.startDate == Values.day(now) || task.endDate == Values.day(now)
    }

    /// 匹配智能范围；参数：task 为可执行叶，filter 为范围，now 为本地时间；返回值：是否匹配，今日包含逾期待办，近七天不含今天；无副作用。
    static func matches(_ task: AssistantTask, filter: TaskTodoFilter, now: Date) -> Bool {
        let completed = isCompleted(task)
        if filter == .completed { return completed }
        guard !completed else { return false }
        switch filter {
        case .pending: return true
        case .today: return isScheduledToday(task, now: now) || Values.taskIsOverdue(task, all: [task], now: now)
        case .overdue: return Values.taskIsOverdue(task, all: [task], now: now)
        case .important: return task.priority == "high"
        case .unscheduled: return task.startDate.isEmpty && task.endDate.isEmpty
        case .upcoming:
            let day = Values.day(now)
            let week = Values.day(Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: now) ?? now)
            let date = task.endDate.isEmpty ? task.startDate : task.endDate
            return date > day && date <= week
        case .completed: return false
        }
    }

    /// 确定显示分组；参数：task 为可执行叶，now 为本地当前时刻；返回值：完成、逾期、今日或其他安排分组；无副作用。
    static func group(for task: AssistantTask, now: Date) -> TaskTodoGroup {
        if isCompleted(task) { return .completed }
        if Values.taskIsOverdue(task, all: [task], now: now) { return .overdue }
        if isScheduledToday(task, now: now) { return .today }
        return task.startDate.isEmpty && task.endDate.isEmpty ? .anytime : .scheduled
    }

    /// 筛选并稳定排序；参数：all 为完整快照，listID 为清单范围，filter 为智能范围，query 为标题/备注搜索，sort 为排序，now 为当前时刻；返回值：有序可执行叶节点；相同键保持服务端顺序，不写任务。
    static func tasks(in all: [AssistantTask], listID: Int = 0, filter: TaskTodoFilter, query: String = "", sort: TaskTodoSort = .deadline, now: Date = .now) -> [AssistantTask] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = actionable(in: all, listID: listID).filter {
            matches($0, filter: filter, now: now) && (keyword.isEmpty || $0.title.localizedCaseInsensitiveContains(keyword) || $0.remark.localizedCaseInsensitiveContains(keyword))
        }
        // 稳定索引避免同日期、同优先级任务在刷新后随机跳动；所有排序都不改变父子结构。
        let indices = Dictionary(all.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        return candidates.sorted { left, right in
            let leftPriority = priorityRank(left.priority), rightPriority = priorityRank(right.priority)
            let leftDate = scheduledKey(left), rightDate = scheduledKey(right)
            if sort == .priority && leftPriority != rightPriority { return leftPriority < rightPriority }
            if sort != .manual && leftDate != rightDate { return leftDate < rightDate }
            if sort != .manual && leftPriority != rightPriority { return leftPriority < rightPriority }
            return (indices[left.id] ?? 0) < (indices[right.id] ?? 0)
        }
    }

    /// 判断能否直接勾选；参数：task 为历史或当前叶节点；返回值：准备提交的完成量为有限自然数且不超过业务上限时 true；旧小数未完成任务需先显式编辑校正，无副作用。
    static func canToggleCompletion(_ task: AssistantTask) -> Bool {
        let target = isCompleted(task) ? 0 : task.progressTotal
        return target.isFinite && target >= 0 && target <= 1_000_000_000 && target.rounded(.towardZero) == target && task.progressTotal > 0
    }

    /// 构造一键完成或撤销的白名单更新；参数：task 为当前可执行叶快照，调用前需通过 canToggleCompletion；返回值：仅 progressCompleted 的 PATCH 字段；恢复到 0，不覆盖标题、总量及其他未提交字段，无副作用。
    static func completionPatch(for task: AssistantTask) -> [String: Any] {
        ["progressCompleted": isCompleted(task) ? 0.0 : task.progressTotal]
    }

    /// 构造明日截止字段；参数：task 为当前叶任务，now 为当前时间；返回值：仅更新本地下一日截止的字段，保留时分；若会早于已有开始则返回 nil，要求显式编辑而非清除用户安排；无副作用。
    static func tomorrowPatch(for task: AssistantTask, now: Date = .now) -> [String: Any]? {
        let tomorrow = Values.day(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now)
        let endTime = task.endTime.isEmpty ? "23:59" : task.endTime
        if !task.startDate.isEmpty && task.startDate + " " + (task.startTime.isEmpty ? "00:00" : task.startTime) > tomorrow + " " + endTime { return nil }
        return ["endDate": tomorrow]
    }

    /// 构造日期排序键；参数：task 为叶节点；返回值：截止优先、其次开始、未安排最后的本地日期时分键，全天截止按 23:59；无副作用。
    private static func scheduledKey(_ task: AssistantTask) -> String {
        if !task.endDate.isEmpty { return task.endDate + " " + (task.endTime.isEmpty ? "23:59" : task.endTime) }
        if !task.startDate.isEmpty { return task.startDate + " " + (task.startTime.isEmpty ? "00:00" : task.startTime) }
        return "9999-99-99 23:59"
    }

    /// 将优先级映射为排序键；参数：priority 为后端优先级，未知值视为中；返回值：越小越优先的整数；无副作用。
    private static func priorityRank(_ priority: String) -> Int {
        priority == "high" ? 0 : priority == "low" ? 2 : 1
    }
}

/// 无 UI 依赖的任务层级规则；所有输入均为同一身份的当前快照，不执行网络或持久化写入。
nonisolated enum TaskBrowsing {
    /// 进入容器时保存的归属签名；归档或移动后不能继续沿用旧路径。
    struct Location: Equatable {
        let taskID: Int
        let listID: Int
        let parentID: Int?
        let archived: Bool

        /// 捕获容器位置；参数：task 为进入时的任务快照；返回值：无；仅初始化值类型，无外部副作用。
        init(_ task: AssistantTask) {
            taskID = task.id
            listID = task.listId
            parentID = task.parentId
            archived = task.archived
        }
    }

    /// 获取范围内的树根；参数：scoped 为已经 Values.tasks 过滤的有序任务；返回值：保持顺序的范围边界根，真正缺父的旧数据保留；无副作用。
    static func roots(in scoped: [AssistantTask]) -> [AssistantTask] {
        let ids = Set(scoped.map(\.id))
        return scoped.filter { !ids.contains($0.parentId ?? 0) }
    }

    /// 获取当前直接子层；参数：parentID 为空表示范围根，非空必须仍在 scoped 中，scoped 为已过滤范围；返回值：保持顺序的一层任务，失效父级返回空而非错误提升后代；无副作用。
    static func children(of parentID: Int?, in scoped: [AssistantTask]) -> [AssistantTask] {
        guard let parentID else { return roots(in: scoped) }
        guard scoped.contains(where: { $0.id == parentID }) else { return [] }
        return scoped.filter { $0.parentId == parentID }
    }

    /// 搜索整个清单/归档范围；参数：query 为原生搜索输入，scoped 为完整范围而非当前子层；返回值：标题匹配任务（含匹配容器本身），空查询返回原范围，顺序不变；无副作用。
    static func search(_ query: String, in scoped: [AssistantTask]) -> [AssistantTask] {
        query.isEmpty ? scoped : scoped.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// 判断是否可进入下级；参数：task 为节点，all 为完整快照；返回值：主任务（含空主任务）或已有下级的历史容器为 true；无副作用。
    static func isContainer(_ task: AssistantTask, all: [AssistantTask]) -> Bool {
        task.taskType == "main" || all.contains { $0.parentId == task.id }
    }

    /// 判断能否在父节点新建；参数：parent 为最新父任务，all 为完整快照；返回值：父节点仍存在、为主任务且自身及所有祖先均未归档时 true；共享 busy/blocked 另由调用方校验，无副作用。
    static func canCreateChild(of parent: AssistantTask, all: [AssistantTask]) -> Bool {
        parent.taskType == "main" && Values.tasks(in: "active", all: all).contains { $0.id == parent.id && $0.taskType == "main" }
    }

    /// 修剪已失效浏览路径；参数：path 为进入时的容器签名，scoped 为当前范围，all 为完整快照；返回值：仍连续有效的最长前缀；删除、归档、移动或变叶时退回有效上层，重复节点终止，无副作用。
    static func validPath(_ path: [Location], in scoped: [AssistantTask], all: [AssistantTask]) -> [Location] {
        var result: [Location] = []
        var visited = Set<Int>()
        for location in path {
            guard visited.insert(location.taskID).inserted,
                  let task = scoped.first(where: { $0.id == location.taskID }),
                  Location(task) == location,
                  isContainer(task, all: all),
                  children(of: result.last?.taskID, in: scoped).contains(where: { $0.id == task.id }) else { break }
            result.append(location)
        }
        return result
    }
}
