import SwiftUI

struct TasksView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var listID = 0
    @State private var scope = "active"
    @State private var creating = false
    @State private var managing = false
    @State private var error: String?
    @State private var loading = false
    /// 当前清单与归档范围内的有效根；参数：无；返回值：可见任务，搜索可匹配子任务；归档父级不会隐藏活跃子级。
    private var visible: [AssistantTask] {
        let scoped = store.tasks.filter { (listID == 0 || $0.listId == listID) && ($0.archived == (scope == "archived")) }
        let ids = Set(scoped.map(\.id))
        return scoped.filter { search.isEmpty ? !ids.contains($0.parentId ?? 0) : $0.title.localizedCaseInsensitiveContains(search) }
    }
    /// 构建任务界面；参数：无；返回值：原生视图；状态回调只更新草稿或启动单次明确操作。
    var body: some View {
        List {
            Section {
                Picker("任务状态", selection: $scope) { Text("任务").tag("active"); Text("已归档").tag("archived") }.pickerStyle(.segmented)
                Picker("清单", selection: $listID) { Text("全部清单").tag(0); ForEach(store.lists) { Text($0.name).tag($0.id) } }
            }
            if let notice = store.taskNotice { Section { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } } }
            if loading && store.tasks.isEmpty { ProgressView("加载任务…") }
            else if let error, store.tasks.isEmpty { Section { InlineError(message: error); Button("重新加载") { Task { await reload() } } } }
            else {
                if let error { InlineError(message: error) }
                if visible.isEmpty {
                    ContentUnavailableView(search.isEmpty ? (store.lists.isEmpty ? "创建第一个清单" : scope == "archived" ? "暂无归档任务" : "暂无任务") : "没有匹配的任务", systemImage: "checklist")
                    if search.isEmpty && scope != "archived" { Button(store.lists.isEmpty ? "新建清单" : "新建任务") { if store.lists.isEmpty { managing = true } else { creating = true } } }
                }
            }
            ForEach(visible) { task in NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task) } }
                // 拖动回调：输入为原索引与目标位置；返回无；向服务端提交完整 ID 顺序，不在失败时假装保存成功。
                .onMove { source, destination in Task { await reorder(source, to: destination) } }
        }.navigationTitle("任务").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索任务与子任务")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("清单", systemImage: "folder") { managing = true } }
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(loading || !search.isEmpty || store.taskWriteBusy || store.taskWriteBlocked) }
                ToolbarItem(placement: .primaryAction) { Button("新建任务", systemImage: "plus") { creating = true }.disabled(store.lists.isEmpty || store.taskWriteBusy || store.taskWriteBlocked) }
            }
            .task { await reload() }.refreshable { await reload() }
            .sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil, preferredListID: listID) }
            // 清单变更回调输入前后清单；返回无；删除选中清单后恢复总览，保留搜索。
            .onChange(of: store.lists) { _, lists in if listID != 0 && !lists.contains(where: { $0.id == listID }) { listID = 0 } }
            .sheet(isPresented: $managing) { NavigationStack { ListsView() } }
    }
    /// 保存可见任务排序；参数：source 为移动索引，destination 为插入索引；返回值：无；保留其他节点位置，失败不修改本地顺序。
    private func reorder(_ source: IndexSet, to destination: Int) async {
        var ordered = visible
        ordered.move(fromOffsets: source, toOffset: destination)
        let movedIDs = Set(ordered.map(\.id))
        var iterator = ordered.makeIterator()
        // 顺序转换回调输入原节点、输出完整排序ID；仅替换当前可见节点，保留隐藏子节点位置。
        let ids = store.tasks.map { movedIDs.contains($0.id) ? iterator.next()!.id : $0.id }
        guard ids.count <= 1000 else { error = "任务超过 1000 个，当前服务端不支持一次排序这么多任务。"; return }
        let generation = store.cloudSessionID
        loading = true; defer { if generation == store.cloudSessionID { loading = false } }
        // 写回调输入无、输出无；只提交一次排序或删除请求，副作用由共享写保护约束。
        do { try await store.writeTask { try await store.api.mutate("/tasks/reorder", method: "PUT", body: ["taskIds": ids]) }; error = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 刷新任务页；参数：无；返回值：无；错误保留原列表，支持重试。
    private func reload() async { let generation = store.cloudSessionID; loading = true; defer { if generation == store.cloudSessionID { loading = false } }; do { try await store.loadTasks(); error = nil } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription } }
}
struct TaskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: AssistantTask
    private var progress: TaskProgress { Values.progress(task, all: store.tasks) }
    /// 构建任务界面；参数：无；返回值：原生视图；状态回调只更新草稿或启动单次明确操作。
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().stroke(.teal.opacity(0.13), lineWidth: 3)
                Circle().trim(from: 0, to: progress.fraction).stroke(.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                if progress.fraction >= 1 { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.teal) }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(task.archived ? .secondary : .primary)
                if let list = store.lists.first(where: { $0.id == task.listId }) { Text(list.name).font(.caption).foregroundStyle(.secondary) }
                if let parent = store.tasks.first(where: { $0.id == task.parentId }) { Label(parent.title, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary) }
                // 辅助字号需要完整保留日期与状态；纵向排列避免元信息竞争横向空间，普通字号沿用原横向层次。
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) { metadata }
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { metadata }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    /// 构建共用任务元信息；参数：无；返回值：优先级、完整截止日期时分和百分比视图；两种字号布局共用同一业务表达，无副作用。
    @ViewBuilder private var metadata: some View {
        if task.priority == "high" { Label("高优先级", systemImage: "flag.fill").foregroundStyle(.orange) }
        if !task.endDate.isEmpty { Text(taskDate(task.endDate, time: task.endTime)).foregroundStyle(Values.taskIsOverdue(task, all: store.tasks) ? .red : .secondary) }
        Text("\(Int(progress.fraction * 100))%")
    }

}
struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: Int
    @State private var editing = false
    @State private var addingChild = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    private var item: AssistantTask? { store.tasks.first { $0.id == taskID } }
    private var children: [AssistantTask] { store.tasks.filter { $0.parentId == taskID } }
    /// 构建任务界面；参数：无；返回值：原生视图；状态回调只更新草稿或启动单次明确操作。
    var body: some View {
        Group {
            if let task = item {
                List {
                    Section {
                        Text(task.title).font(.title2.bold())
                        if !task.remark.isEmpty { Text(task.remark).foregroundStyle(.secondary).textSelection(.enabled) }
                        let progress = Values.progress(task, all: store.tasks)
                        ProgressView(value: progress.fraction) { Text("完成进度") } currentValueLabel: { Text("\(Int(progress.fraction * 100))%") }
                        }
                    Section("安排") {
                        if !task.startDate.isEmpty { LabeledContent("开始", value: taskDate(task.startDate, time: task.startTime)) }
                        if !task.endDate.isEmpty { LabeledContent("截止", value: taskDate(task.endDate, time: task.endTime)) }
                        LabeledContent("优先级", value: task.priority == "high" ? "高" : task.priority == "low" ? "低" : "中")
                        LabeledContent("清单", value: store.lists.first { $0.id == task.listId }?.name ?? "—")
                    }
                    if !task.archived && children.isEmpty && task.taskType == "subtask" {
                        Section("进度 · \(task.progressUnit)") {
                            LabeledContent("完成 / 总量", value: "\(task.progressCompleted.formatted()) / \(task.progressTotal.formatted())")
                            HStack {
                                Button("减少", systemImage: "minus.circle") { Task { await progress("decrement") } }.disabled(task.progressCompleted <= 0 || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                Spacer()
                                Button("增加", systemImage: "plus.circle.fill") { Task { await progress("increment") } }.disabled(task.progressCompleted >= task.progressTotal || busy || store.taskWriteBusy || store.taskWriteBlocked)
                            }.buttonStyle(.borderless)
                        }
                    }
                    Section("子任务") {
                        ForEach(children) { child in NavigationLink { TaskDetailView(taskID: child.id) } label: { TaskRow(task: child) } }
                        if !task.archived { Button("添加子任务", systemImage: "plus") { addingChild = true }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked) }
                    }
                    if let error { InlineError(message: error) }
                    if let notice = store.taskNotice { InlineError(message: notice) }
                    Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } }
                    Section {
                        Button(task.archived ? "恢复任务" : "归档任务", systemImage: "archivebox") { Task { await archive(task) } }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked)
                        Button("删除任务", role: .destructive) { deleting = true }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked)
                    }
                }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("编辑") { editing = true }.disabled(task.archived || busy || store.taskWriteBusy || store.taskWriteBlocked) }
                    .sheet(isPresented: $editing) { TaskEditor(task: task, parent: nil) }
                    .sheet(isPresented: $addingChild) { TaskEditor(task: nil, parent: task) }
                    .confirmationDialog("删除此任务及全部子任务？此操作无法撤销。", isPresented: $deleting, titleVisibility: .visible) {
                        Button("删除任务及子任务", role: .destructive) { Task { await remove() } }
                    }
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
    @State private var busy = false
    @State private var error: String?
    private var fields: [String: Any] {
        ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "remark": remark, "priority": priority, "taskType": taskType,
         "progressTotal": total, "progressCompleted": completed, "progressStep": step, "progressUnit": unit,
         "startDate": hasStart ? Values.day(start) : "", "endDate": hasEnd ? Values.day(end) : "",
         "startTime": hasStart ? startTime : "", "endTime": hasEnd ? endTime : ""]
    }
    /// 校验白名单草稿；参数：无；返回值：首个具体错误或 nil；小数精度沿用后端两位规则，日期时间采用本地日历。
    private var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入任务名称。" }
        if title.unicodeScalars.count > 256 { return "任务名称最多 256 个字符。" }
        if remark.unicodeScalars.count > 10000 { return "备注最多 10000 个字符。" }
        if unit.unicodeScalars.count > 20 { return "单位最多 20 个字符。" }
        if !store.lists.contains(where: { $0.id == listID }) { return "请选择有效清单。" }
        if !Values.validMoney(total, positive: true) || !Values.validMoney(step, positive: true) || !Values.validMoney(completed) { return "进度需为最多两位小数的有效数值。" }
        let target = Decimal(string: total) ?? 0, increment = Decimal(string: step) ?? 0, done = Decimal(string: completed) ?? -1
        if target > 1_000_000_000 || increment > target || done < 0 || done > target { return "进度应在目标总量内，每次增加不能超过总量。" }
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
                Section("任务内容") {
                    TaskFloatingField(title: "任务名称", text: $title)
                    TaskFloatingField(title: "备注", text: $remark, multiline: true)
                    Picker("清单", selection: $listID) { ForEach(store.lists) { Text($0.name).tag($0.id) } }.disabled(task != nil || parent != nil)
                    Picker("优先级", selection: $priority) { Text("高").tag("high"); Text("中").tag("medium"); Text("低").tag("low") }
                    if task == nil && parent == nil {
                        Picker("类型", selection: $taskType) { Text("可执行任务").tag("subtask"); Text("主任务（汇总子任务）").tag("main") }
                    }
                }
                Section("时间安排") {
                    Toggle("设置开始日期", isOn: $hasStart)
                    if hasStart { DatePicker("开始日期", selection: $start, displayedComponents: .date); TimeInput(title: "开始时间", value: $startTime) }
                    Toggle("设置截止日期", isOn: $hasEnd)
                    if hasEnd { DatePicker("截止日期", selection: $end, displayedComponents: .date); TimeInput(title: "截止时间", value: $endTime) }
                }
                if configuresProgress { Section("进度配置") {
                    TaskFloatingField(title: "目标总量", text: $total).keyboardType(.decimalPad)
                    TaskFloatingField(title: "已完成量", text: $completed).keyboardType(.decimalPad)
                    TaskFloatingField(title: "每次增加", text: $step).keyboardType(.decimalPad)
                    TaskFloatingField(title: "单位", text: $unit)
                } }
                if !title.isEmpty, let validationError { InlineError(message: validationError) }
            }.navigationTitle(task == nil ? "新建任务" : "编辑任务").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: valid) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                // 日期开关回调输入前后布尔值；返回无；关闭立即清空时分，避免重新开启恢复隐藏旧时间。
                .onChange(of: hasStart) { _, value in if !value { startTime = "" } }
                .onChange(of: hasEnd) { _, value in if !value { endTime = "" } }
                .task { populate() }
        }
    }
    /// 装载编辑初值；参数：无；返回值：无；保存原字段快照以构造最小 PATCH。
    private func populate() {
        listID = task?.listId ?? parent?.listId ?? (store.lists.contains(where: { $0.id == preferredListID }) ? preferredListID : store.lists.first?.id ?? 0)
        if let task {
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
                var body = fields; body["listId"] = listID; body["parentId"] = parent?.id as Any? ?? NSNull()
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
