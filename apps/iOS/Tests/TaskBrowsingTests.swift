import Foundation

/// 任务展示规则的纯 Foundation 回归；由主测试入口调用 run，不访问真实账号或服务器。
enum TaskBrowsingTests {
    private enum Failure: Error { case assertion(String) }

    /// 检查测试条件；参数：condition 为待验证布尔值，message 为失败说明；返回值：无；条件不满足抛出 Failure，不修改外部状态。
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    /// 构造任务样本；参数：id 为唯一标识，parent 为可选父 ID，type 为保存类型，list 为清单 ID，archived 为自身归档标记；返回值：纯内存任务；无副作用。
    private static func task(_ id: Int, parent: Int? = nil, type: String = "main", list: Int = 1, archived: Bool = false) -> AssistantTask {
        AssistantTask(id: id, title: "任务\(id)", remark: "", listId: list, parentId: parent, taskType: type, priority: "medium", startDate: "", startTime: "", endDate: "", endTime: "", archived: archived, sortOrder: id, progressTotal: 1, progressCompleted: 0, progressStep: 1, progressUnit: "次")
    }

    /// 执行浏览规则测试；参数：无；返回值：无；失败抛出断言错误，临时 UserDefaults suite 在结束时清理，不影响真实本机偏好。
    static func run() throws {
        let root = task(1)
        let branch = task(2, parent: 1)
        let leaf = task(3, parent: 2, type: "subtask")
        let empty = task(4)
        let legacy = task(5, type: "subtask")
        let legacyLeaf = task(6, parent: 5, type: "subtask")
        let orphan = task(7, parent: 999)
        let secondList = task(8, list: 2)
        let all = [root, branch, leaf, empty, legacy, legacyLeaf, orphan, secondList]
        let active = Values.tasks(in: "active", all: all)
        try check(TaskBrowsing.roots(in: active).map(\.id) == [1, 4, 5, 7, 8], "根层不包含后代，真正缺父保留，全部清单顺序不变")
        try check(TaskBrowsing.children(of: 1, in: active).map(\.id) == [2], "逐级仅显示直接下级")
        try check(TaskBrowsing.children(of: 2, in: active).map(\.id) == [3], "可继续进入第二层")
        try check(TaskBrowsing.children(of: 999, in: active).isEmpty, "失效父级不把孤儿后代提升到当前层")
        try check(TaskBrowsing.isContainer(empty, all: all), "空主任务可进入")
        try check(TaskBrowsing.isContainer(legacy, all: all), "历史具体容器可进入")
        try check(!TaskBrowsing.isContainer(leaf, all: all), "具体叶任务应打开详情")
        try check(TaskBrowsing.canCreateChild(of: empty, all: all), "空主任务可新建下级")
        try check(!TaskBrowsing.canCreateChild(of: legacy, all: all), "历史具体容器不能绕过主父候选规则新建")
        try check(!TaskBrowsing.canCreateChild(of: empty, all: all.filter { $0.id != empty.id }), "已删除父节点不能新建")

        let path = [TaskBrowsing.Location(root), TaskBrowsing.Location(branch)]
        try check(TaskBrowsing.validPath(path, in: active, all: all) == path, "正常路径保持")
        try check(TaskBrowsing.children(of: path.last?.taskID, in: active).map(\.id) == [3], "按有效路径读取当前层")
        let deleted = all.filter { $0.id != branch.id && $0.id != leaf.id }
        try check(TaskBrowsing.validPath(path, in: deleted, all: deleted) == Array(path.prefix(1)), "删除当前层安全返回上层")
        var movedBranch = branch; movedBranch.parentId = empty.id
        let moved = [root, movedBranch, leaf, empty]
        try check(TaskBrowsing.validPath(path, in: moved, all: moved) == Array(path.prefix(1)), "移动当前层不沿用旧路径")
        var movedRoot = root; movedRoot.listId = 2
        let movedAcrossLists = [movedRoot, branch, leaf, empty]
        try check(TaskBrowsing.validPath(path, in: movedAcrossLists, all: movedAcrossLists).isEmpty, "全部任务中跨清单移动也清理旧路径")
        var renamed = branch; renamed.title = "改名不应返回"
        let renamedAll = [root, renamed, leaf, empty]
        try check(TaskBrowsing.validPath(path, in: renamedAll, all: renamedAll) == path, "改名不影响路径")
        let becameLeaf = [root, task(2, parent: 1, type: "subtask"), empty]
        try check(TaskBrowsing.validPath(path, in: becameLeaf, all: becameLeaf) == Array(path.prefix(1)), "变为叶节点后退出旧容器")
        try check(TaskBrowsing.validPath(path + path, in: active, all: all) == path, "重复路径不会循环")

        var archivedRoot = root; archivedRoot.archived = true
        let archivedAll = [archivedRoot, branch, leaf, empty]
        let activeWithoutArchived = Values.tasks(in: "active", all: archivedAll)
        try check(TaskBrowsing.roots(in: activeWithoutArchived).map(\.id) == [4], "归档祖先的下级不错误升为活跃根")
        try check(TaskBrowsing.validPath(path, in: activeWithoutArchived, all: archivedAll).isEmpty, "归档路径祖先退出活跃层级")
        try check(TaskBrowsing.validPath(path, in: archivedAll, all: archivedAll).isEmpty, "包含归档范围也退出刚归档的旧路径")
        try check(!TaskBrowsing.canCreateChild(of: branch, all: archivedAll), "未归档主任务处于归档祖先下时不能新建")
        let archivedScope = Values.tasks(in: "archived", all: archivedAll)
        try check(TaskBrowsing.roots(in: archivedScope).map(\.id) == [1], "归档范围保留完整归档子树")
        let archivedChild = task(9, parent: 4, archived: true)
        try check(TaskBrowsing.roots(in: Values.tasks(in: "archived", all: [empty, archivedChild])).map(\.id) == [9], "单独归档子任务在归档范围仍有可达入口")
        let listTwo = Values.tasks(in: "all", all: all, listID: 2)
        try check(TaskBrowsing.roots(in: listTwo).map(\.id) == [8], "清单筛选独立于展示类型")
        let cycle = [task(10, parent: 11), task(11, parent: 10)]
        try check(TaskBrowsing.roots(in: cycle).isEmpty, "环状旧数据不无限遍历或错误提升根")
        try check(TaskBrowsing.validPath([TaskBrowsing.Location(cycle[0])], in: cycle, all: cycle).isEmpty, "环状路径安全终止")

        try check(TaskBrowsing.search("任务3", in: active).map(\.id) == [3], "搜索找到深层叶任务")
        try check(TaskBrowsing.search("任务2", in: active).map(\.id) == [2], "匹配父节点本身也输出结果，点击可查看详情")
        try check(TaskBrowsing.search("", in: active) == active, "空查询顺序不变")
        try check(TaskBrowsing.search("任务3", in: activeWithoutArchived).isEmpty, "搜索尊重归档祖先范围")
        try check(TaskBrowsing.search("任务3", in: archivedScope).map(\.id) == [3], "归档搜索仍覆盖所有层")
        try check((TaskDisplayMode(rawValue: "unknown") ?? .tree) == .tree, "未知展示值默认树状")

        let suite = "TaskBrowsingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.assertion("创建隔离偏好存储失败") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(defaults.string(forKey: TaskDisplayMode.storageKey) == nil, "新本机默认无已保存偏好")
        defaults.set(TaskDisplayMode.levels.rawValue, forKey: TaskDisplayMode.storageKey)
        try check(TaskDisplayMode(rawValue: defaults.string(forKey: TaskDisplayMode.storageKey) ?? "tree") == .levels, "逐级偏好可持久读取")
        defaults.set(TaskDisplayMode.tree.rawValue, forKey: TaskDisplayMode.storageKey)
        try check(defaults.string(forKey: TaskDisplayMode.storageKey) == "tree", "可切回树状偏好")
        try todoRules()
    }

    /// 验证待办范围、时间边界与写入白名单；参数：无；返回值：无；纯内存样本，失败抛出断言，不联网也不读取真实偏好。
    private static func todoRules() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let day = Values.day(now)
        let tomorrow = Values.day(calendar.date(byAdding: .day, value: 1, to: now)!)
        let week = Values.day(calendar.date(byAdding: .day, value: 7, to: now)!)
        let eighth = Values.day(calendar.date(byAdding: .day, value: 8, to: now)!)
        var today = task(101, type: "subtask"); today.endDate = day
        var overdue = task(102, type: "subtask"); overdue.endDate = day; overdue.endTime = "10:00"
        var later = task(103, type: "subtask"); later.endDate = tomorrow; later.priority = "high"
        var done = task(104, type: "subtask"); done.endDate = day; done.progressCompleted = 1
        let unplanned = task(105, type: "subtask")
        var started = task(106, type: "subtask"); started.startDate = day
        var boundary = task(107, type: "subtask"); boundary.endDate = week
        var outside = task(108, type: "subtask"); outside.endDate = eighth
        let archivedParent = task(109, archived: true)
        let hiddenChild = task(110, parent: 109, type: "subtask")
        let legacyContainer = task(111, type: "subtask")
        let legacyChild = task(112, parent: 111, type: "subtask")
        let main = task(113)
        var otherList = task(114, type: "subtask", list: 2); otherList.remark = "待联系 Supplier"
        let all = [main, today, overdue, later, done, unplanned, started, boundary, outside, archivedParent, hiddenChild, legacyContainer, legacyChild, otherList]
        let actionable = TaskTodoRules.actionable(in: all)
        try check(!actionable.contains { [109, 110, 111, 113].contains($0.id) }, "待办排除主任务、归档祖先后代及历史具体容器")
        try check(actionable.contains { $0.id == legacyChild.id }, "历史具体容器的可执行叶仍可执行")
        try check(TaskTodoRules.actionable(in: all, listID: 2).map(\.id) == [114], "待办清单筛选不串数据")
        try check(!TaskTodoRules.matches(done, filter: .pending, now: now), "待办不混入完成任务")
        try check(TaskTodoRules.matches(done, filter: .completed, now: now), "完成任务可重新打开")
        try check(TaskTodoRules.matches(today, filter: .today, now: now), "全天截止今天中午尚未逾期")
        try check(TaskTodoRules.group(for: today, now: now) == .today, "全天任务留在今日安排")
        try check(TaskTodoRules.group(for: overdue, now: now) == .overdue, "具体截止时分生效")
        try check(TaskTodoRules.matches(overdue, filter: .today, now: now), "今日视图包含需要处理的逾期")
        try check(TaskTodoRules.matches(started, filter: .today, now: now), "今日开始但未设截止仍进入今日")
        try check(TaskTodoRules.matches(later, filter: .upcoming, now: now), "明天在近七天内")
        try check(TaskTodoRules.matches(boundary, filter: .upcoming, now: now), "近七天包含第七天")
        try check(!TaskTodoRules.matches(outside, filter: .upcoming, now: now), "近七天不包含第八天")
        try check(!TaskTodoRules.matches(today, filter: .upcoming, now: now), "近期范围不重复今日")
        try check(TaskTodoRules.matches(later, filter: .important, now: now), "重要只对应高优先级")
        try check(TaskTodoRules.matches(unplanned, filter: .unscheduled, now: now), "无起止才视为未安排")
        try check(!TaskTodoRules.matches(started, filter: .unscheduled, now: now), "仅有开始也属于已安排")
        try check(TaskTodoRules.tasks(in: all, filter: .pending, query: " supplier ", now: now).map(\.id) == [114], "搜索去空白并匹配备注且忽略英文大小写")
        try check(TaskTodoRules.tasks(in: all, filter: .pending, sort: .priority, now: now).first?.id == later.id, "优先级排序将重要任务提前")
        try check(TaskTodoRules.tasks(in: [unplanned, legacyChild], filter: .pending, now: now).map(\.id) == [105, 112], "相同排序键保持原顺序")
        try check(TaskTodoRules.tasks(in: [unplanned, today], filter: .pending, sort: .manual, now: now).map(\.id) == [105, 101], "清单顺序不被日期排序覆盖")
        try check(TaskTodoRules.completionPatch(for: today)["progressCompleted"] as? Double == 1, "简单待办一次完成")
        try check(TaskTodoRules.completionPatch(for: done)["progressCompleted"] as? Double == 0, "撤销显式提交零值")
        try check(TaskTodoRules.completionPatch(for: today).keys.sorted() == ["progressCompleted"], "勾选不覆盖未提交字段")
        var quantified = today; quantified.progressTotal = 100; quantified.progressCompleted = 35
        try check(TaskTodoRules.completionPatch(for: quantified)["progressCompleted"] as? Double == 100, "量化叶可直接补齐总量")
        try check(TaskTodoRules.tomorrowPatch(for: overdue, now: now)?["endDate"] as? String == tomorrow, "延期使用本地下一日")
        try check(TaskTodoRules.tomorrowPatch(for: overdue, now: now)?.keys.sorted() == ["endDate"], "延期不覆盖既有截止时分")
        var futureStart = today; futureStart.startDate = week
        try check(TaskTodoRules.tomorrowPatch(for: futureStart, now: now) == nil, "明日早于开始时拒绝，不清除已有安排")
        var oldDone = done; oldDone.endDate = "2026-10-01"
        try check(!TaskTodoRules.isScheduledToday(oldDone, now: now), "历史完成任务不能伪造为今日完成")
        let afterMidnight = calendar.date(byAdding: .day, value: 1, to: now)!
        try check(TaskTodoRules.group(for: today, now: afterMidnight) == .overdue, "跨日后今日任务转入逾期")
        try check(TaskTodoRules.matches(overdue, filter: .overdue, now: now), "逾期范围只取已过截止的待办")
        try check(!TaskTodoRules.matches(today, filter: .overdue, now: now), "逾期范围不混入当天未到期任务")
        try check(TaskTodoRules.tasks(in: [today, overdue], filter: .pending, now: now).map(\.id) == [102, 101], "同日按具体截止时分排序，全天任务放在当天末尾")
        var fractional = today; fractional.progressTotal = 2.5
        try check(!TaskTodoRules.canToggleCompletion(fractional), "历史小数总量先编辑校正，不直接提交非法完成量")
        try check(TaskTodoRules.canToggleCompletion(quantified), "自然数量化任务可以一键完成")
        try check(TaskTodoRules.canToggleCompletion(done), "完成任务可以显式恢复零进度")
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0))!
        try check(TaskTodoRules.tomorrowPatch(for: today, now: midnight)?["endDate"] as? String == "2026-10-19", "午夜后以操作时刻计算明天，而非沿用昨天的显示时间")
    }
}
