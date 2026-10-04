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
    private var visible: [AssistantTask] {
        store.tasks.filter {
            (listID == 0 || $0.listId == listID) && (scope == "archived" ? $0.archived : !$0.archived)
            && (search.isEmpty ? scope == "archived" || $0.parentId == nil || $0.parentId == 0 : $0.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            Section {
                Picker("任务状态", selection: $scope) { Text("进行中").tag("active"); Text("已归档").tag("archived") }.pickerStyle(.segmented)
                Picker("清单", selection: $listID) { Text("全部清单").tag(0); ForEach(store.lists) { Text($0.name).tag($0.id) } }
            }
            if let error { Section { InlineError(message: error); Button("重新加载") { Task { await reload() } } } }
            if loading && store.tasks.isEmpty { ProgressView("加载任务…") }
            else if visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? "留一点空间给新的计划" : "没有匹配的任务", systemImage: "checklist", description: Text("创建清单，再把计划拆成可以完成的小事。"))
            }
            ForEach(visible) { task in NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task) } }
                // 拖动回调：输入为原索引与目标位置；返回无；向服务端提交完整 ID 顺序，不在失败时假装保存成功。
                .onMove { source, destination in Task { await reorder(source, to: destination) } }
        }.navigationTitle("任务").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索任务与子任务")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("清单", systemImage: "folder") { managing = true } }
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(loading || !search.isEmpty) }
                ToolbarItem(placement: .primaryAction) { Button("新建任务", systemImage: "plus") { creating = true }.disabled(store.lists.isEmpty) }
            }
            .task { await reload() }.refreshable { await reload() }
            .sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil) }
            .sheet(isPresented: $managing) { NavigationStack { ListsView() } }
    }
    /// 保存可见任务排序；参数：source 为移动索引，destination 为插入索引；返回值：无；保留其他节点位置，失败不修改本地顺序。
    private func reorder(_ source: IndexSet, to destination: Int) async {
        var ordered = visible
        ordered.move(fromOffsets: source, toOffset: destination)
        let movedIDs = Set(ordered.map(\.id))
        var iterator = ordered.makeIterator()
        let ids = store.tasks.map { movedIDs.contains($0.id) ? iterator.next()!.id : $0.id }
        guard ids.count <= 1000 else { error = "任务超过 1000 个，当前服务端不支持一次排序这么多任务。"; return }
        loading = true; defer { loading = false }
        do { try await store.api.mutate("/tasks/reorder", method: "PUT", body: ["taskIds": ids]); try await store.loadTasks(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    /// 刷新任务页；参数：无；返回值：无；错误保留原列表，支持重试。
    private func reload() async { loading = true; defer { loading = false }; do { try await store.loadTasks(); error = nil } catch { self.error = error.localizedDescription } }
}
struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: AssistantTask
    private var progress: TaskProgress { Values.progress(task, all: store.tasks) }
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.teal.opacity(0.13), lineWidth: 3)
                Circle().trim(from: 0, to: progress.fraction).stroke(.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                if progress.fraction >= 1 { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.teal) }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(task.archived ? .secondary : .primary)
                HStack {
                    if task.priority == "high" { Label("高优先级", systemImage: "flag.fill").foregroundStyle(.orange) }
                    if !task.endDate.isEmpty { Text(task.endDate).foregroundStyle(task.endDate < Values.day() && progress.fraction < 1 ? .red : .secondary) }
                    Text("\(Int(progress.fraction * 100))%")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
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
    var body: some View {
        Group {
            if let task = item {
                List {
                    Section {
                        Text(task.title).font(.title2.bold())
                        if !task.remark.isEmpty { Text(task.remark).foregroundStyle(.secondary).textSelection(.enabled) }
                        let progress = Values.progress(task, all: store.tasks)
                        ProgressView(value: progress.fraction) { Text("完成进度") } currentValueLabel: { Text("\(Int(progress.fraction * 100))%") }
                        if !task.startDate.isEmpty { LabeledContent("开始", value: task.startDate + " " + task.startTime) }
                        if !task.endDate.isEmpty { LabeledContent("截止", value: task.endDate + " " + task.endTime) }
                        LabeledContent("清单", value: store.lists.first { $0.id == task.listId }?.name ?? "—")
                    }
                    if !task.archived && children.isEmpty && task.taskType == "subtask" {
                        Section("进度 · \(task.progressUnit)") {
                            LabeledContent("完成 / 总量", value: "\(task.progressCompleted.formatted()) / \(task.progressTotal.formatted())")
                            HStack {
                                Button("减少", systemImage: "minus.circle") { Task { await progress("decrement") } }.disabled(task.progressCompleted <= 0)
                                Spacer()
                                Button("增加", systemImage: "plus.circle.fill") { Task { await progress("increment") } }.disabled(task.progressCompleted >= task.progressTotal)
                            }.buttonStyle(.borderless)
                        }
                    }
                    Section("子任务") {
                        ForEach(children) { child in NavigationLink { TaskDetailView(taskID: child.id) } label: { TaskRow(task: child) } }
                        if !task.archived { Button("添加子任务", systemImage: "plus") { addingChild = true } }
                    }
                    if let error { InlineError(message: error) }
                    Section {
                        Button(task.archived ? "恢复任务" : "归档任务", systemImage: "archivebox") { Task { await archive(task) } }
                        Button("删除任务", role: .destructive) { deleting = true }
                    }
                }.disabled(busy).navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("编辑") { editing = true }.disabled(task.archived) }
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
        busy = true; defer { busy = false }
        do { try await store.api.mutate("/tasks/\(taskID)/progress", method: "PATCH", body: ["operation": operation, "allowExceedTotal": true]); try await store.loadTasks(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    /// 设置归档状态；参数：task 为原任务；返回值：无；仅发送 archived 字段，支持 false。
    private func archive(_ task: AssistantTask) async {
        busy = true; defer { busy = false }
        do { try await store.api.mutate("/tasks/\(taskID)", method: "PATCH", body: ["archived": !task.archived]); try await store.loadTasks(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    /// 确认后级联删除；参数：无；返回值：无；删除成功关闭页面，刷新失败不诱导重复删除。
    private func remove() async {
        busy = true; defer { busy = false }
        do {
            try await store.api.mutate("/tasks/\(taskID)?cascade=true", method: "DELETE")
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
            await store.refreshAfterMutation(.tasks)
        } catch { self.error = error.localizedDescription }
    }
}

struct TaskEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: AssistantTask?
    let parent: AssistantTask?
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
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 256 && listID > 0 &&
        Values.validMoney(total, positive: true) && Values.validMoney(step, positive: true) && Values.validMoney(completed) &&
        (Double(total) ?? 0) <= 1e9 && (Double(step) ?? 0) <= (Double(total) ?? 0) &&
        (Double(completed) ?? -1) >= 0 && (Double(completed) ?? 0) <= (Double(total) ?? 0) &&
        (!hasStart || !hasEnd || Values.day(start) <= Values.day(end))
    }
    var body: some View {
        NavigationStack {
            Form {
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
                Section("进度配置") {
                    TaskFloatingField(title: "目标总量", text: $total).keyboardType(.decimalPad)
                    TaskFloatingField(title: "已完成量", text: $completed).keyboardType(.decimalPad)
                    TaskFloatingField(title: "每次增加", text: $step).keyboardType(.decimalPad)
                    TaskFloatingField(title: "单位", text: $unit)
                    if taskType == "main" { Text("主任务的展示进度由子任务汇总；空主任务与 Web 一样显示 100%。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { InlineError(message: error) }
            }.navigationTitle(task == nil ? "新建任务" : "编辑任务").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: valid) { Task { await save() } } }
                .interactiveDismissDisabled(busy).task { populate() }
        }
    }
    /// 装载编辑初值；参数：无；返回值：无；保存原字段快照以构造最小 PATCH。
    private func populate() {
        listID = task?.listId ?? parent?.listId ?? store.lists.first?.id ?? 0
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
        busy = true; defer { busy = false }
        do {
            if let task {
                let patch = Values.patch(original: original, edited: fields)
                if !patch.isEmpty { try await store.api.mutate("/tasks/\(task.id)", method: "PATCH", body: patch) }
            } else {
                var body = fields; body["listId"] = listID; body["parentId"] = parent?.id as Any? ?? NSNull()
                try await store.api.mutate("/tasks", body: body)
            }
            dismiss(); await store.refreshAfterMutation(.tasks)
        } catch { self.error = error.localizedDescription }
    }
}
