import SwiftUI

/// 唯一任务模块根：以清单组织入口，任务树和详情使用系统推入导航。
struct TasksView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var edited: TaskList?
    /// 构建清单根页面；参数：无；返回值：连续列表与原全局Tab；回调仅修改呈现状态或启动只读刷新。
    var body: some View {
        List {
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } }
            if loading && store.lists.isEmpty { ProgressView("加载清单…") }
            else if let error, store.lists.isEmpty { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            else {
                if let error { InlineError(message: error) }
                Section("我的清单") {
                    // 清单回调输入已保存清单、输出内容页导航；数量仅统计清单当前未归档节点。
                    ForEach(store.lists.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { list in
                        NavigationLink { TaskCollectionView(listID: list.id, title: list.name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: TaskListAppearance.symbol(list.icon)).font(.title3).foregroundStyle(Color.listColor(list.color))
                                    .frame(width: 38, height: 38).background(Color.listColor(list.color).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) { Text(list.name).font(.body.weight(.medium)); if !list.remark.isEmpty { Text(list.remark).font(.caption).foregroundStyle(.secondary) } }
                                Spacer()
                                Text(store.tasks.filter { $0.listId == list.id && !$0.archived }.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 7)
                        }.swipeActions { Button("编辑") { edited = list } }
                    }
                    if store.lists.isEmpty { ContentUnavailableView("创建第一个清单", systemImage: "folder.badge.plus"); Button("新建清单") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
                    else if !search.isEmpty && !store.lists.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) { ContentUnavailableView.search(text: search) }
                }
                Section { NavigationLink { TaskCollectionView(listID: 0, title: "已归档", scope: "archived") } label: { Label("已归档", systemImage: "archivebox") } }
            }
        }.listStyle(.plain).navigationTitle("任务").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索清单")
            .toolbar { Button("新建清单", systemImage: "plus") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
            .sheet(isPresented: $creating) { ListEditor(list: nil) }.sheet(item: $edited) { ListEditor(list: $0) }
            .task { await reload() }.refreshable { await reload() }
    }
    /// 刷新清单及任务快照；参数：无；返回值：无；失败保留缓存，取消及旧云身份反馈静默。
    private func reload() async {
        let generation = store.cloudSessionID
        loading = true; defer { if generation == store.cloudSessionID { loading = false } }
        do { try await store.loadTasks(); guard generation == store.cloudSessionID else { return }; error = nil }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
}

/// 推入的清单内容页，连续内容面展示可展开树，不增加独立模块导航。
struct TaskCollectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let listID: Int
    let title: String
    var scope = "active"
    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var initializedTree = false
    @State private var editMode: EditMode = .inactive
    @State private var creating = false
    @State private var editingList = false
    @State private var deletingList = false
    @State private var error: String?
    @State private var loading = false
    private var list: TaskList? { store.lists.first { $0.id == listID } }
    /// 当前范围的树节点；参数：无；返回值：节点与缩进深度，父不在当前范围的节点成为有效根；搜索平列实际匹配节点。
    private var rows: [(task: AssistantTask, depth: Int)] {
        let scoped = store.tasks.filter { (listID == 0 || $0.listId == listID) && $0.archived == (scope == "archived") }
        if !search.isEmpty { return scoped.filter { $0.title.localizedCaseInsensitiveContains(search) }.map { ($0, 0) } }
        let ids = Set(scoped.map(\.id))
        var result: [(task: AssistantTask, depth: Int)] = []
        var visited: Set<Int> = []
        /// 深度遍历树；参数：task为当前节点，depth为缩进深度；返回值：无；循环节点跳过，最多缩进三层以保留可读宽度。
        func append(_ task: AssistantTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            result.append((task, min(depth, 3)))
            if expanded.contains(task.id) { for child in scoped where child.parentId == task.id { append(child, depth: depth + 1) } }
        }
        for task in scoped where !ids.contains(task.parentId ?? 0) { append(task, depth: 0) }
        return result
    }
    /// 构建清单树；参数：无；返回值：普通内容面与原生推入导航；展开按钮与详情入口分离，写入口遵循共享保护。
    var body: some View {
        List {
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } }
            if let error { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            if rows.isEmpty && error == nil {
                ContentUnavailableView(search.isEmpty ? scope == "archived" ? "暂无归档任务" : "暂无任务" : "没有匹配的任务", systemImage: "checklist")
                if search.isEmpty && scope != "archived" && list != nil { Button("新建任务") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
            }
            Section("任务") {
                // 树行回调输入节点与深度、输出详情导航及独立展开操作；展开不修改业务数据。
                ForEach(rows, id: \.task.id) { row in
                    HStack(spacing: 8) {
                        NavigationLink { TaskDetailView(taskID: row.task.id) } label: { TaskRow(task: row.task, showsContext: !search.isEmpty || listID == 0) }
                        if search.isEmpty && store.tasks.contains(where: { $0.parentId == row.task.id && $0.archived == (scope == "archived") }) {
                            Button { if expanded.contains(row.task.id) { expanded.remove(row.task.id) } else { expanded.insert(row.task.id) } } label: { Image(systemName: expanded.contains(row.task.id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityLabel(expanded.contains(row.task.id) ? "收起下级" : "展开下级")
                        }
                    }.padding(.leading, CGFloat(row.depth) * 16)
                }
                // 拖动回调输入源索引和插入位置、输出无；仅在同父序列中写入排序，不改变任务归属。
                .onMove { source, destination in Task { await reorder(source, to: destination) } }
            }
        }.environment(\.editMode, $editMode).listStyle(.plain).navigationTitle(list?.name ?? title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .searchable(text: $search, prompt: "搜索任务")
            .toolbar {
                if list != nil {
                    Menu {
                        Button("编辑清单") { editingList = true }
                        Button("删除清单", role: .destructive) { deletingList = true }
                        // 排序回调输入无、输出无；切换本地系统EditMode，不增加顶部按钮，排序写入仍受共享保护。
                        Button(editMode.isEditing ? "完成排序" : "排序") { editMode = editMode.isEditing ? .inactive : .active }
                            .disabled(loading || !search.isEmpty || store.taskWriteBusy || store.taskWriteBlocked)
                    } label: { Image(systemName: "ellipsis") }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    Button("新建任务", systemImage: "plus") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked || scope == "archived")
                }
            }
            .sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil, preferredListID: listID) }
            .sheet(isPresented: $editingList) { if let list { ListEditor(list: list) } }
            .confirmationDialog("删除清单及其中全部任务？", isPresented: $deletingList, titleVisibility: .visible) { Button("删除清单", role: .destructive) { Task { await removeList() } } }
            // 首次树展示回调输入无、输出无；默认展开已有主容器，后续用户折叠状态由本页State保留。
            .task { if !initializedTree { expanded = Set(store.tasks.filter { $0.listId == listID && $0.taskType == "main" }.map(\.id)); initializedTree = true } }
            .refreshable { await reload() }
    }
    /// 刷新任务内容；参数：无；返回值：无；旧云身份与取消不显示错误。
    private func reload() async {
        let generation = store.cloudSessionID
        loading = true; defer { if generation == store.cloudSessionID { loading = false } }
        do { try await store.loadTasks(); guard generation == store.cloudSessionID else { return }; error = nil }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 保存同父级顺序；参数：source为单行源索引，destination为目标位置；返回值：无；跨层级拖动拒绝，成功后独立刷新。
    private func reorder(_ source: IndexSet, to destination: Int) async {
        let original = rows.map(\.task)
        guard let index = source.first, source.count == 1, original.indices.contains(index) else { return }
        var ordered = original; ordered.move(fromOffsets: source, toOffset: destination)
        let siblings = ordered.filter { $0.parentId == original[index].parentId }
        let originalSiblings = original.filter { $0.parentId == original[index].parentId }
        guard siblings.map(\.id) != originalSiblings.map(\.id) else { return }
        let ids = Values.taskOrderPreservingHidden(store.tasks, orderedVisibleIDs: siblings.map(\.id))
        guard ids.count <= 1000 else { error = "任务超过 1000 个，当前服务端不支持一次排序这么多任务。"; return }
        let generation = store.cloudSessionID
        // 排序写回调输入无、输出无；提交保留隐藏槽位的全ID顺序，服务确认后再独立刷新。
        do { try await store.writeTask { try await store.api.mutate("/tasks/reorder", method: "PUT", body: ["taskIds": ids]) }; await store.refreshTaskWrite() }
        catch { if generation == store.cloudSessionID && !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    /// 删除已确认清单；参数：无；返回值：无；服务端确认后本地移除并返回，未知结果不重发。
    private func removeList() async {
        let generation = store.cloudSessionID
        do { try await store.writeTask { try await store.api.mutate("/task-lists/\(listID)", method: "DELETE") }; store.lists.removeAll { $0.id == listID }; store.tasks.removeAll { $0.listId == listID }; dismiss(); await store.refreshTaskWrite() }
        catch { guard generation == store.cloudSessionID, !(error is CancellationError) else { return }; self.error = error.localizedDescription }
    }
}

struct TaskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: AssistantTask
    var showsContext = true
    private var progress: TaskProgress { Values.progress(task, all: store.tasks) }
    private var container: Bool { task.taskType == "main" || store.tasks.contains { $0.parentId == task.id } }
    /// 构建数量优先的任务行；参数：无；返回值：主任务图标或具体进度环，辅助字号纵排元信息；无业务写入。
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if container {
                Image(systemName: TaskIcons.symbol(task.icon)).font(.title3).foregroundStyle(.teal)
                    .frame(width: 38, height: 38).background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            } else {
                ZStack {
                    Circle().stroke(.teal.opacity(0.14), lineWidth: 3)
                    Circle().trim(from: 0, to: progress.fraction).stroke(.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    if progress.fraction >= 1 { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.teal) }
                }.frame(width: 28, height: 28).padding(5).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                if dynamicTypeSize.isAccessibilitySize { Text(task.title).font(.body.weight(.medium)); if !(container && progress.total == 0) { Text(taskQuantity(progress)).font(.caption).foregroundStyle(.secondary) } }
                else { HStack { Text(task.title).font(.body.weight(.medium)); Spacer(minLength: 6); if !(container && progress.total == 0) { Text(taskQuantity(progress)).font(.caption).foregroundStyle(.secondary) } } }
                if container {
                    if progress.total == 0 { Text("暂无任务").font(.caption).foregroundStyle(.secondary) }
                    else { Text(taskPercent(progress)).font(.caption).foregroundStyle(.secondary); ProgressView(value: progress.fraction).tint(.teal).accessibilityHidden(true) }
                }
                if showsContext { Text(taskPath(task, tasks: store.tasks, lists: store.lists)).font(.caption).foregroundStyle(.secondary) }
                if dynamicTypeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 5) { metadata }.font(.caption).foregroundStyle(.secondary) }
                else { HStack { metadata }.font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 7).foregroundStyle(task.archived ? .secondary : .primary).accessibilityElement(children: .combine)
    }
    /// 构建辅助元信息；参数：无；返回值：必要优先级及完整日期时分；两种字号共用，不截断日期。
    @ViewBuilder private var metadata: some View {
        if task.priority == "high" { Label("高优先级", systemImage: "flag").foregroundStyle(.orange) }
        if !task.endDate.isEmpty { Text(taskDate(task.endDate, time: task.endTime)).foregroundStyle(Values.taskIsOverdue(task, all: store.tasks) ? .red : .secondary) }
    }
}
struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    let taskID: Int
    @State private var editing = false
    @State private var addingChild = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    private var item: AssistantTask? { store.tasks.first { $0.id == taskID } }
    private var children: [AssistantTask] { store.tasks.filter { $0.parentId == taskID } }
    /// 构建主任务或具体任务详情；参数：无；返回值：对象层次、细进度条和系统底部工具栏；历史具体容器只显示下级，不允许新增或直接步进。
    var body: some View {
        Group {
            if let task = item {
                let summary = Values.progress(task, all: store.tasks)
                let container = task.taskType == "main" || !children.isEmpty
                List {
                    Section {
                        HStack(alignment: .top, spacing: 14) {
                            if container { Image(systemName: TaskIcons.symbol(task.icon)).font(.title2).foregroundStyle(.teal).frame(width: 44, height: 44).background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)) }
                            VStack(alignment: .leading, spacing: 7) { Text(task.title).font(.title2.weight(.semibold)); Text(taskPath(task, tasks: store.tasks, lists: store.lists)).font(.caption).foregroundStyle(.secondary) }
                        }
                        if container && summary.total == 0 { Text("暂无任务").foregroundStyle(.secondary) }
                        else {
                            // 数量布局按辅助字号纵排；保留完整量化值，不缩小文字以塞入固定横排。
                            if dynamicTypeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 6) { Text(taskQuantity(summary)).font(.title.weight(.regular)); Text(taskPercent(summary)).foregroundStyle(.secondary) } }
                            else { HStack(alignment: .firstTextBaseline) { Text(taskQuantity(summary)).font(.title.weight(.regular)); Spacer(); Text(taskPercent(summary)).foregroundStyle(.secondary) } }
                            ProgressView(value: summary.fraction).tint(.teal)
                        }
                    }
                    // 对象标题、数量与细条属于同一摘要，隐藏摘要内部行分隔；下级与字段分隔保持系统样式。
                    .listRowSeparator(.hidden)
                    if container {
                        Section("下级") { ForEach(children) { child in NavigationLink { TaskDetailView(taskID: child.id) } label: { TaskRow(task: child, showsContext: false) } } }
                    } else {
                        Section {
                            LabeledContent("优先级", value: task.priority == "high" ? "高" : task.priority == "low" ? "低" : "中")
                            LabeledContent("开始", value: task.startDate.isEmpty ? "未设置" : taskDate(task.startDate, time: task.startTime))
                            LabeledContent("截止", value: task.endDate.isEmpty ? "未设置" : taskDate(task.endDate, time: task.endTime))
                        }
                        Section("进度配置") { LabeledContent("总量", value: task.progressTotal.formatted() + " " + task.progressUnit); LabeledContent("步长", value: task.progressStep.formatted() + " " + task.progressUnit) }
                    }
                    if !task.remark.isEmpty { Section("备注") { Text(task.remark).foregroundStyle(.secondary).textSelection(.enabled) } }
                    if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } } }
                    else if let error { InlineError(message: error) }
                }.listStyle(.plain).navigationTitle(task.taskType == "main" ? "主任务详情" : "任务详情").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("编辑") { editing = true }.disabled(task.archived || busy || store.taskWriteBusy || store.taskWriteBlocked) }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button(task.archived ? "恢复任务" : "归档任务", systemImage: "archivebox") { Task { await archive(task) } }
                                Button("删除任务", role: .destructive) { deleting = true }
                            } label: { Image(systemName: "ellipsis") }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked)
                        }
                        if !task.archived && task.taskType == "main" {
                            ToolbarItem(placement: .bottomBar) { Button("新建下级", systemImage: "plus") { addingChild = true }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked) }
                        } else if !task.archived && !container {
                            ToolbarItemGroup(placement: .bottomBar) {
                                Button("减少", systemImage: "minus") { Task { await progress("decrement") } }.disabled(task.progressCompleted <= 0 || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                Spacer()
                                Text(task.progressCompleted.formatted() + " " + task.progressUnit).foregroundStyle(.secondary)
                                Spacer()
                                Button("+" + task.progressStep.formatted() + " " + task.progressUnit) { Task { await progress("increment") } }.disabled(task.progressCompleted >= task.progressTotal || busy || store.taskWriteBusy || store.taskWriteBlocked)
                            }
                        }
                    }
                    .sheet(isPresented: $editing) { TaskEditor(task: task, parent: nil) }
                    .sheet(isPresented: $addingChild) { TaskEditor(task: nil, parent: task) }
                    .confirmationDialog("删除此任务及全部下级？", isPresented: $deleting, titleVisibility: .visible) { Button("删除任务及下级", role: .destructive) { Task { await remove() } } }
            } else { ContentUnavailableView("任务已不存在", systemImage: "checkmark.circle") }
        }
    }
    /// 更改叶任务进度；参数：operation 为 increment/decrement；返回值：无；后端检查溢出和归档，成功刷新。
    private func progress(_ operation: String) async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        // 写回调输入无、输出服务器任务实体；仅一次 PATCH，成功实体先合并，读失败不重发。
        do { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(taskID)/progress", method: "PATCH", body: ["operation": operation, "allowExceedTotal": true]) }; store.upsertTask(saved); error = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 设置归档状态；参数：task 为原任务；返回值：无；仅发送 archived 字段，支持 false。
    private func archive(_ task: AssistantTask) async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        // 写回调输入无、输出服务器任务实体；仅一次 PATCH，成功实体先合并，读失败不重发。
        do { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(taskID)", method: "PATCH", body: ["archived": !task.archived]) }; store.upsertTask(saved); error = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 确认后级联删除；参数：无；返回值：无；删除成功关闭页面，刷新失败不诱导重复删除。
    private func remove() async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        do {
            // 删除回调输入无、输出无；结构化 cascade 查询保留在真实请求URL中。
            try await store.writeTask { try await store.api.mutate("/tasks/\(taskID)", method: "DELETE", query: [URLQueryItem(name: "cascade", value: "true")]) }
            // 从本地任务树计算后代，删除接口统一返回 data:null。
            var removed: Set<Int> = [taskID]
            var expanded = true
            while expanded {
                expanded = false
                for item in store.tasks {
                    if let parent = item.parentId, removed.contains(parent), removed.insert(item.id).inserted { expanded = true }
                }
            }
            store.tasks.removeAll { removed.contains($0.id) }
            dismiss()
            await store.refreshTaskWrite()
        } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
}

struct TaskEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: AssistantTask?
    let parent: AssistantTask?
    var preferredListID = 0
    @State private var uncertainCreation = false
    @State private var title = ""
    @State private var remark = ""
    @State private var listID = 0
    @State private var parentID = 0
    @State private var icon = "Folder"
    @State private var priority = "medium"
    @State private var taskType = "subtask"
    @State private var total = "1"
    @State private var completed = "0"
    @State private var step = "1"
    @State private var unit = "次"
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var startTime = ""
    @State private var endTime = ""
    @State private var original: [String: Any] = [:]
    @State private var populated = false
    @State private var busy = false
    @State private var error: String?
    /// 生成提交字段白名单；参数：无；返回值：归属和当前类型字段，主任务不提交隐藏进度；未提交字段保留原值。
    private var fields: [String: Any] {
        var result: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "remark": remark, "priority": priority, "taskType": taskType,
         "startDate": hasStart ? Values.day(start) : "", "endDate": hasEnd ? Values.day(end) : "",
         "startTime": hasStart ? startTime : "", "endTime": hasEnd ? endTime : "", "listId": listID, "parentId": parentID == 0 ? NSNull() : parentID]
        if taskType == "main" { result["icon"] = icon }
        // 合并回调输入默认旧值和量化草稿值、输出新值；仅具体类型提交进度，主任务原配置不覆盖。
        else { result.merge(["progressTotal": total, "progressCompleted": completed, "progressStep": step, "progressUnit": unit]) { _, new in new } }
        return result
    }
    /// 主父候选；参数：无；返回值：同清单未归档主任务，排除自身和后代；旧具体父节点不作为新候选。
    private var parentCandidates: [AssistantTask] {
        var excluded: Set<Int> = task.map { [$0.id] } ?? []
        var changed = true
        while changed { changed = false; for item in store.tasks { if let parent = item.parentId, excluded.contains(parent), excluded.insert(item.id).inserted { changed = true } } }
        return store.tasks.filter { $0.listId == listID && $0.taskType == "main" && !$0.archived && !excluded.contains($0.id) }
    }
    /// 校验白名单草稿；参数：无；返回值：首个具体错误或 nil；小数精度沿用后端两位规则，日期时间采用本地日历。
    private var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入任务名称。" }
        if title.unicodeScalars.count > 256 { return "任务名称最多 256 个字符。" }
        if remark.unicodeScalars.count > 10000 { return "备注最多 10000 个字符。" }
        if let task, task.taskType == "main", taskType != "main", store.tasks.contains(where: { $0.parentId == task.id }) { return "有下级的主任务不能改为具体任务。" }
        if icon.utf8.count > 64 || icon.trimmingCharacters(in: .whitespaces).isEmpty { return "请选择有效图标。" }
        if parentID != 0 && !parentCandidates.contains(where: { $0.id == parentID }) && !(task?.parentId == parentID && task?.listId == listID) { return "请选择有效父主任务。" }
        if unit.unicodeScalars.count > 20 { return "单位最多 20 个字符。" }
        if !store.lists.contains(where: { $0.id == listID }) { return "请选择有效清单。" }
        if configuresProgress && (!Values.validMoney(total, positive: true) || !Values.validMoney(step, positive: true) || !Values.validMoney(completed)) { return "进度需为最多两位小数的有效数值。" }
        let target = Decimal(string: total) ?? 0, increment = Decimal(string: step) ?? 0, done = Decimal(string: completed) ?? -1
        if configuresProgress && (target > 1_000_000_000 || increment > target || done < 0 || done > target) { return "进度应在目标总量内，每次增加不能超过总量。" }
        for time in [hasStart ? startTime : "", hasEnd ? endTime : ""] {
            if !time.isEmpty && time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil { return "时间格式应为 HH:mm。" }
        }
        if hasStart && hasEnd && (Values.day(start) + " " + (startTime.isEmpty ? "00:00" : startTime)) > (Values.day(end) + " " + (endTime.isEmpty ? "23:59" : endTime)) { return "截止时间不能早于开始时间。" }
        return nil
    }
    /// 判断可保存草稿；参数：无；返回值：校验和共享保护都通过为 true；结果不明的原创建表单永久禁止再次提交。
    private var valid: Bool { validationError == nil && !uncertainCreation && !store.taskWriteBlocked && !store.taskWriteBusy }
    /// 判断进度配置入口；参数：无；返回值：仅可执行叶节点或新建可执行任务为 true；汇总节点保留原字段。
    private var configuresProgress: Bool {
        guard taskType == "subtask" else { return false }
        guard let task else { return true }
        return !store.tasks.contains(where: { $0.parentId == task.id })
    }
    /// 构建任务界面；参数：无；返回值：原生视图；状态回调只更新草稿或启动单次明确操作。
    var body: some View {
        NavigationStack {
            Form {
                if uncertainCreation { InlineError(message: "创建结果未确认。请关闭此表单并刷新列表，确认后再创建。") }
                else if let error { InlineError(message: error) }
                Section {
                    TaskFloatingField(title: "名称", text: $title)
                    TaskFloatingField(title: "备注", text: $remark, multiline: true)
                    if task == nil || (task?.taskType == "subtask" && !configuresProgress) {
                        Picker("类型", selection: $taskType) { Text("具体任务").tag("subtask"); Text("主任务").tag("main") }
                    }
                }
                if taskType == "main" { Section { NavigationLink { TaskIconPicker(selection: $icon) } label: { HStack { Text("图标"); Spacer(); Image(systemName: TaskIcons.symbol(icon)).foregroundStyle(.teal) } } } }
                Section("归属") {
                    Picker("清单", selection: $listID) { ForEach(store.lists) { Text($0.name).tag($0.id) } }
                    Picker("父主任务", selection: $parentID) {
                        Text("无").tag(0)
                        ForEach(parentCandidates) { candidate in Label(taskPath(candidate, tasks: store.tasks, lists: store.lists) + " › " + candidate.title, systemImage: TaskIcons.symbol(candidate.icon)).tag(candidate.id) }
                        if let originalParent = store.tasks.first(where: { $0.id == task?.parentId }), !parentCandidates.contains(where: { $0.id == originalParent.id }), parentID == originalParent.id { Text(originalParent.title).tag(originalParent.id).disabled(true) }
                    }
                }
                Section("时间") {
                    // 日期入口回调输入无、输出共享草稿子页；返回只保留编辑状态，整个编辑取消时不发送写入。
                    NavigationLink { TaskDateDraft(title: "开始", enabled: $hasStart, date: $start, time: $startTime) } label: { LabeledContent("开始", value: hasStart ? taskDate(Values.day(start), time: startTime) : "未设置") }
                    NavigationLink { TaskDateDraft(title: "截止", enabled: $hasEnd, date: $end, time: $endTime) } label: { LabeledContent("截止", value: hasEnd ? taskDate(Values.day(end), time: endTime) : "未设置") }
                }
                if configuresProgress { Section("进度配置") {
                    TaskFloatingField(title: "目标总量", text: $total).keyboardType(.decimalPad)
                    TaskFloatingField(title: "已完成量", text: $completed).keyboardType(.decimalPad)
                    TaskFloatingField(title: "每次增加", text: $step).keyboardType(.decimalPad)
                    TaskFloatingField(title: "单位", text: $unit)
                } }
                Section { Picker("优先级", selection: $priority) { Text("高").tag("high"); Text("中").tag("medium"); Text("低").tag("low") } }
                if !title.isEmpty, let validationError { InlineError(message: validationError) }
            }.navigationTitle(task == nil ? "新建任务" : taskType == "main" ? "编辑主任务" : "编辑任务").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: valid) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                // 日期开关回调输入前后布尔值；返回无；关闭立即清空时分，避免重新开启恢复隐藏旧时间。
                .onChange(of: hasStart) { _, value in if !value { startTime = "" } }
                .onChange(of: hasEnd) { _, value in if !value { endTime = "" } }
                // 清单变更回调输入前后清单ID、输出无；真正跨清单草稿清原父，PATCH必须明确null或重新选有效主父。
                .onChange(of: listID) { old, new in if old != 0 && old != new { parentID = 0 } }
                // 生命周期回调输入无、输出无；新编辑实例只装载一次，图标或日期子页返回时保留草稿与最初PATCH快照。
                .task { populate() }
        }
    }
    /// 一次装载编辑初值；参数：无；返回值：无；本编辑实例仅首次初始化，子页返回不覆盖草稿或最初PATCH快照，新sheet新State重新装载。
    private func populate() {
        guard !populated else { return }
        populated = true
        listID = task?.listId ?? parent?.listId ?? (store.lists.contains(where: { $0.id == preferredListID }) ? preferredListID : store.lists.first?.id ?? 0)
        parentID = task?.parentId ?? parent?.id ?? 0
        if let task {
            icon = task.icon ?? "Folder"
            title = task.title; remark = task.remark; priority = task.priority; taskType = task.taskType
            total = String(task.progressTotal); completed = String(task.progressCompleted); step = String(task.progressStep); unit = task.progressUnit
            hasStart = !task.startDate.isEmpty; hasEnd = !task.endDate.isEmpty
            start = Values.date(task.startDate); end = Values.date(task.endDate); startTime = task.startTime; endTime = task.endTime
        }
        original = fields
    }
    /// 保存白名单字段；参数：无；返回值：无；创建附带清单/父节点，编辑只提交变化字段；失败保留输入，成功关闭。
    private func save() async {
        guard valid else { error = validationError; return }
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        do {
            // 共享写保护覆盖所有详情和表单，服务端成功实体先合并，再独立刷新。
            if let task {
                let patch = Values.patch(original: original, edited: fields)
                // 编辑回调输入无、输出服务器实体；仅提交变化字段，不覆盖未提交字段。
                if !patch.isEmpty { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(task.id)", method: "PATCH", body: patch) }; store.upsertTask(saved) }
            } else {
                let body = fields
                // 创建回调输入无、输出服务器实体；POST结果不明后原草稿禁止再次提交。
                let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks", method: "POST", body: body) }; store.upsertTask(saved)
            }
            dismiss(); await store.refreshTaskWrite()
        } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); self.error = error.localizedDescription; if task == nil && store.taskWriteBlocked { uncertainCreation = true } }
    }
}

/// 本地化任务日期；参数：day 为服务端 yyyy-MM-dd，time 为可选 HH:mm；返回值：本地日期及原时分；无副作用。
private func taskDate(_ day: String, time: String) -> String {
    Values.date(day).formatted(date: .abbreviated, time: .omitted) + (time.isEmpty ? "" : " " + time)
}

/// 格式化量化进度；参数：progress为实际叶汇总；返回值：最多两位小数的完成/总量与一致单位，混合单位不伪装；无副作用。
private func taskQuantity(_ progress: TaskProgress) -> String {
    progress.completed.formatted(.number.precision(.fractionLength(0...2))) + " / " + progress.total.formatted(.number.precision(.fractionLength(0...2))) + (progress.unit.isEmpty ? "" : " " + progress.unit)
}
/// 格式化完成比例；参数：progress为汇总；返回值：最多一位小数百分比，如54.5%；无副作用。
private func taskPercent(_ progress: TaskProgress) -> String { (progress.fraction * 100).formatted(.number.precision(.fractionLength(0...1))) + "%" }
/// 构建对象归属路径；参数：task为当前节点，tasks为缓存树，lists为清单；返回值：清单与父级名称，不重复当前标题，环检测防死循环。
private func taskPath(_ task: AssistantTask, tasks: [AssistantTask], lists: [TaskList]) -> String {
    var parts: [String] = []
    var parent = task.parentId
    var visited: Set<Int> = [task.id]
    while let id = parent, visited.insert(id).inserted, let item = tasks.first(where: { $0.id == id }) { parts.insert(item.title, at: 0); parent = item.parentId }
    if let list = lists.first(where: { $0.id == task.listId }) { parts.insert(list.name, at: 0) }
    return parts.joined(separator: " › ")
}

/// 图标选择只操作编辑绑定草稿，离开编辑或取消不会持久化。
private struct TaskIconPicker: View {
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    /// 构建六列图标目录；参数：无；返回值：44pt以上按钮与搜索，读屏含名称和选中状态；点击只更新草稿。
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 4), count: 6), spacing: 12) {
                // 图标回调输入目录记录、输出选择按钮；更新绑定后保留选择页，完成返回编辑。
                ForEach(TaskIcons.options.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search) }) { option in
                    Button { selection = option.key } label: {
                        Image(systemName: option.symbol).font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(selection == option.key ? Color.teal : Color.primary)
                            .background(selection == option.key ? Color.teal.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            // 选中角标是非文本装饰，不随辅助字号放大；固定尺寸并角落内缩，避免遮盖主图标，读屏由isSelected表达。
                            .overlay(alignment: .topTrailing) { if selection == option.key { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).frame(width: 14, height: 14).foregroundStyle(.teal).padding(3).accessibilityHidden(true) } }
                    }.buttonStyle(.plain).accessibilityLabel(option.label).accessibilityAddTraits(selection == option.key ? .isSelected : [])
                }
            }.padding(16)
        }.navigationTitle("选择图标").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索图标")
            .toolbar { Button("完成") { dismiss() } }.toolbar(.hidden, for: .tabBar)
    }
}

/// 日期子页共享编辑草稿；返回保留输入，持久化仅由整个任务表单保存触发。
private struct TaskDateDraft: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var date: Date
    @Binding var time: String
    /// 构建日期草稿页；参数：无；返回值：原有系统开关、日期和时分组件；清除同步移除隐藏时分，无网络或保存副作用。
    var body: some View {
        Form {
            Toggle("设置日期", isOn: $enabled)
            if enabled { DatePicker("日期", selection: $date, displayedComponents: .date); TimeInput(title: "时间", value: $time) }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            // 开关回调输入旧新布尔值、输出无；关闭立即清空时分，重新开启不恢复旧时间。
            .onChange(of: enabled) { _, value in if !value { time = "" } }
    }
}
