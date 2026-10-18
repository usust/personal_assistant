import SwiftUI
import UIKit

/// 日常执行工作区；复用任务树中的具体叶节点，所有写入遵循 AppStore 的身份与结果不明保护。
struct TaskTodoView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedListID: Int
    @State private var filter = TaskTodoFilter.pending
    @AppStorage("taskTodoSort") private var sortRaw = TaskTodoSort.deadline.rawValue
    @State private var query = ""
    @State private var now = Date.now
    @State private var loading = true
    @State private var loaded = false
    @State private var error: String?
    @State private var readSequence = 0
    @State private var creating = false
    @State private var creatingList = false
    @State private var editedTask: AssistantTask?
    @State private var openedTaskID: Int?
    @State private var pendingID: Int?

    /// 读取当前清单叶任务；参数：无；返回值：活动且可执行的节点，含完成节点以支持重新打开；无副作用。
    private var actionable: [AssistantTask] { TaskTodoRules.actionable(in: store.tasks, listID: selectedListID) }
    /// 读取当前列表；参数：无；返回值：按范围、搜索和本机排序筛选的叶节点；无副作用。
    private var visible: [AssistantTask] {
        TaskTodoRules.tasks(in: store.tasks, listID: selectedListID, filter: filter, query: query, sort: TaskTodoSort(rawValue: sortRaw) ?? .deadline, now: now)
    }
    /// 读取今日实际安排；参数：无；返回值：开始或截止是今天的叶节点，不把历史完成量冒充今日完成量；无副作用。
    private var todayTasks: [AssistantTask] { actionable.filter { TaskTodoRules.isScheduledToday($0, now: now) } }
    /// 读取逾期待办数量；参数：无；返回值：按完整快照和本地时间计算的数量；无副作用。
    private var overdueCount: Int { actionable.filter { Values.taskIsOverdue($0, all: store.tasks, now: now) }.count }
    /// 读取共享写保护；参数：无；返回值：任务写入、未知结果锁或本页操作期间为 true；无副作用。
    private var writeDisabled: Bool { store.taskWriteBusy || store.taskWriteBlocked || pendingID != nil }

    /// 构建待办工作区；参数：无；返回值：原生分组列表、筛选、搜索及详情导航，刷新不重置筛选，分钟时钟处理跨日与具体时分截止。
    var body: some View {
        VStack(spacing: 0) {
            filterBar
            todoList
        }
        .background(AppVisualStyle.canvas)
        .navigationTitle("任务").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索待办与备注")
        .toolbar { toolbar }
        .sheet(isPresented: $creating) {
            TaskEditor(task: nil, parent: nil, preferredListID: selectedListID,
                       initialDeadline: filter == .today ? .now : nil,
                       initialPriority: filter == .important ? "high" : "medium")
        }
        .sheet(isPresented: $creatingList) { ListEditor(list: nil) }
        .sheet(item: $editedTask) { TaskEditor(task: $0, parent: nil) }
        .navigationDestination(isPresented: Binding(
            get: { openedTaskID != nil },
            // 导航关闭回调输入呈现状态、返回无；关闭详情后保留待办筛选与搜索。
            set: { if !$0 { openedTaskID = nil } }
        )) {
            if let openedTaskID { TaskDetailView(taskID: openedTaskID) }
        }
        .task(id: store.cloudSessionID) {
            // 页面任务回调无输入、返回无；身份改变后取消旧时钟与读取，任务只读刷新不触发写入。
            await reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                now = .now
            }
        }
        .onChange(of: store.cloudSessionID) { _, _ in
            // 身份回调输入旧新标识、返回无；不让原身份草稿、详情及请求反馈进入新身份。
            readSequence += 1; error = nil; loaded = false; creating = false; creatingList = false
            editedTask = nil; openedTaskID = nil; pendingID = nil; selectedListID = 0; query = ""
        }
        .onChange(of: store.lists) { _, lists in
            // 清单回调输入新旧快照、返回无；清单删除后回到全部，不遗留不可见的新建归属。
            if selectedListID != 0 && !lists.contains(where: { $0.id == selectedListID }) { selectedListID = 0 }
        }
        .onChange(of: store.tasks) { _, tasks in
            // 快照回调输入新旧数组、返回无；只关闭已删除详情，不因勾选后离开筛选而闪退详情。
            if let openedTaskID, !tasks.contains(where: { $0.id == openedTaskID }) { self.openedTaskID = nil }
            if let editedTask, !tasks.contains(where: { $0.id == editedTask.id }) { self.editedTask = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in now = .now }
    }

    /// 构建横向智能范围；参数：无；返回值：至少 44 点高的可滚动选择，不压缩小屏文字；只改变本页筛选。
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TaskTodoFilter.allCases, id: \.rawValue) { option in
                    Button { filter = option } label: {
                        Text(option.title).font(.subheadline.weight(filter == option ? .semibold : .regular))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .foregroundStyle(filter == option ? Color.accentColor : Color.secondary)
                            .background(filter == option ? Color.accentColor.opacity(0.1) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(filter == option ? [.isSelected] : [])
                        .accessibilityIdentifier("todoFilter.\(option.rawValue)")
                }
            }.padding(.horizontal, AppVisualStyle.pageInset)
        }.scrollIndicators(.hidden).padding(.bottom, 4).accessibilityIdentifier("todoFilters")
    }

    /// 构建原生待办列表；参数：无；返回值：今日进度、错误和按时间组织的待办；未知结果时保留快照并提供只读刷新。
    private var todoList: some View {
        // 分组只计算一次，避免每个 Section 重复筛选、排序和解析全部截止日期。
        let groups = Dictionary(grouping: visible) { TaskTodoRules.group(for: $0, now: now) }
        return List {
            Section { dailySummary }.listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0))
            if let notice = store.taskNotice {
                Section { InlineError(message: notice); Button("刷新任务") { Task { await reload() } }.disabled(loading || store.taskWriteBusy) }
            } else if let error {
                Section { InlineError(message: error); Button("重新加载") { Task { await reload() } }.disabled(loading || store.taskWriteBusy) }
            }
            if loading && store.tasks.isEmpty { ProgressView("加载待办…").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            else if visible.isEmpty && !loading && error == nil && store.taskNotice == nil {
                if loaded { emptyState }
                else {
                    // 取消或被其他读取淘汰并不证明服务器无数据；仅提供刷新，不误导创建重复清单。
                    Button("刷新待办", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .frame(maxWidth: .infinity, minHeight: 44).listRowBackground(Color.clear)
                }
            }
            ForEach(TaskTodoGroup.allCases, id: \.rawValue) { group in
                let tasks = groups[group] ?? []
                if !tasks.isEmpty {
                    Section {
                        ForEach(tasks) { task in todoRow(task) }
                    } header: {
                        HStack {
                            Text(group.title).foregroundStyle(group == .overdue ? Color.red : Color.secondary)
                            Spacer()
                            Text(tasks.count.formatted()).monospacedDigit()
                        }.font(.subheadline.weight(.medium)).textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("taskTodoList")
        .refreshable { await reload() }
    }

    /// 构建今日安排摘要；参数：无；返回值：真实今日计划完成比例及逾期入口，不使用缺失的完成日期推导“今日完成”；无业务写入。
    private var dailySummary: some View {
        let completed = todayTasks.filter { TaskTodoRules.isCompleted($0) }.count
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日安排").font(.title2.weight(.semibold))
                    Spacer()
                    summaryReading(completed: completed)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日安排").font(.title2.weight(.semibold))
                    summaryReading(completed: completed)
                }
            }
            if !todayTasks.isEmpty {
                ProgressView(value: Double(completed), total: Double(todayTasks.count)).tint(.accentColor)
                    .accessibilityLabel("今日安排进度").accessibilityValue("\(completed) / \(todayTasks.count)")
            }
            if overdueCount > 0 {
                Button { filter = .overdue } label: {
                    Label("\(overdueCount) 项已逾期", systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline).foregroundStyle(.red).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }.padding(.bottom, 4)
    }

    /// 构建安排读值；参数：completed 为今日安排中已完成数量；返回值：读值视图，初次加载不显示假零；无副作用。
    private func summaryReading(completed: Int) -> some View {
        Text(!loaded && store.tasks.isEmpty ? (loading ? "加载中" : "等待刷新") : todayTasks.isEmpty ? "暂无安排" : "已完成 \(completed) / \(todayTasks.count)")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }

    /// 构建空状态；参数：无；返回值：按搜索、清单与范围提供可执行入口，不把主任务树误称为数据丢失。
    private var emptyState: some View {
        VStack(spacing: 12) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(store.lists.isEmpty ? "创建第一个清单" : filter == .completed ? "暂无已完成待办" : "当前没有待办", systemImage: filter == .completed ? "checkmark.circle" : "checklist")
                if store.lists.isEmpty {
                    Button("新建清单", systemImage: "folder.badge.plus") { creatingList = true }.buttonStyle(.glassProminent).disabled(writeDisabled)
                } else if filter != .completed {
                    Button("添加待办", systemImage: "plus") { creating = true }.buttonStyle(.glassProminent).disabled(writeDisabled)
                }
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 12).listRowBackground(Color.clear)
    }

    /// 构建顶部原生操作；参数：无；返回值：清单目录、新建及当前清单/排序菜单；偏好仅保存本机，不重排服务端任务。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                TaskDirectoryView { id, _, _ in selectedListID = id }
            } label: { Label("我的清单", systemImage: "folder") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("清单", selection: $selectedListID) {
                    Text("全部清单").tag(0)
                    ForEach(store.lists) { Text($0.name).tag($0.id) }
                }
                Picker("排序", selection: $sortRaw) {
                    ForEach(TaskTodoSort.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                Label(selectedListID == 0 ? "筛选与排序" : store.lists.first(where: { $0.id == selectedListID })?.name ?? "筛选与排序", systemImage: selectedListID == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }.accessibilityIdentifier("todoOptions")
            Button("添加待办", systemImage: "plus") { creating = true }
                .disabled(writeDisabled || store.lists.isEmpty || loading)
                .accessibilityIdentifier("todoAdd")
        }
    }

    /// 构建一行及原生滑动/上下文操作；参数：task 为当前快照具体叶节点；返回值：无嵌套按钮的行，操作仅启动受保护的单次写入。
    private func todoRow(_ task: AssistantTask) -> some View {
        TaskTodoRow(task: task, context: store.lists.first(where: { $0.id == task.listId })?.name ?? "", now: now,
                    busy: pendingID == task.id, disabled: writeDisabled,
                    onToggle: { Task { await toggleCompletion(task) } },
                    onOpen: { openedTaskID = task.id })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("编辑", systemImage: "pencil") { editedTask = task }.tint(.blue).disabled(writeDisabled)
                if !TaskTodoRules.isCompleted(task) {
                    Button("明天", systemImage: "calendar.badge.clock") { Task { await moveToTomorrow(task) } }.tint(.orange).disabled(writeDisabled)
                }
            }
            .contextMenu {
                Button("编辑", systemImage: "pencil") { editedTask = task }.disabled(writeDisabled)
                Button(task.priority == "high" ? "取消重要" : "标为重要", systemImage: "flag") {
                    Task { await update(task, fields: ["priority": task.priority == "high" ? "medium" : "high"]) }
                }.disabled(writeDisabled)
            }
    }

    /// 更新当前叶任务；参数：task 为操作快照，fields 为调用点构造的白名单 PATCH；返回值：无；先验证身份内最新实体可执行，成功合并再刷新，未知结果不重发。
    private func update(_ task: AssistantTask, fields: [String: Any]) async {
        guard !writeDisabled, let current = TaskTodoRules.actionable(in: store.tasks).first(where: { $0.id == task.id }), current == task else { return }
        let generation = store.cloudSessionID
        pendingID = task.id
        defer { if generation == store.cloudSessionID { pendingID = nil } }
        do {
            // 写回调无参数，返回服务器确认实体；本地只在确认后修改，保留 AppStore 结果不明锁及会话校验。
            let saved: AssistantTask = try await store.writeTask {
                try await store.api.request("/tasks/\(task.id)", method: "PATCH", body: fields)
            }
            store.upsertTask(saved); error = nil
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    /// 勾选或打开历史进度校正；参数：task 为当前叶快照；返回值：无；不向只接受自然数的接口提交旧小数，校正必须由用户保存确认。
    private func toggleCompletion(_ task: AssistantTask) async {
        guard !writeDisabled else { return }
        guard TaskTodoRules.canToggleCompletion(task) else { editedTask = task; return }
        await update(task, fields: TaskTodoRules.completionPatch(for: task))
    }

    /// 将截止移至明天；参数：task 为选中任务；返回值：无；用操作时刻而非显示时钟计算，日期冲突不清空已有安排。
    private func moveToTomorrow(_ task: AssistantTask) async {
        guard let fields = TaskTodoRules.tomorrowPatch(for: task, now: .now) else {
            error = "明天的截止早于开始时间，请在编辑中调整。"; return
        }
        await update(task, fields: fields)
    }

    /// 只读刷新；参数：无；返回值：无；同身份最新请求才更新本页反馈，失败保留旧快照，不将失败误作空列表。
    private func reload() async {
        let generation = store.cloudSessionID
        readSequence += 1
        let sequence = readSequence
        loading = true; now = .now
        defer { if generation == store.cloudSessionID && sequence == readSequence { loading = false } }
        do {
            try await store.loadTasks()
            guard generation == store.cloudSessionID, sequence == readSequence, !Task.isCancelled else { return }
            loaded = true; error = nil
        } catch {
            guard generation == store.cloudSessionID, sequence == readSequence, !(error is CancellationError), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 待办执行行；勾选与详情是两个独立按钮，标题和数量不依赖颜色表达状态。
struct TaskTodoRow: View {
    let task: AssistantTask
    let context: String
    let now: Date
    let busy: Bool
    let disabled: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 读取完成状态；参数：无；返回值：按叶节点数量判断的完成状态；无副作用。
    private var completed: Bool { TaskTodoRules.isCompleted(task) }
    /// 构建待办行；参数：无；返回值：独立 44 点完成按钮与完整详情入口，辅助字号标题不截断，量化任务才显示进度；写入由调用者负责。
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: onToggle) {
                Group {
                    if busy { ProgressView() }
                    else { Image(systemName: !TaskTodoRules.canToggleCompletion(task) ? "exclamationmark.circle" : completed ? "checkmark.circle.fill" : "circle").font(.title2.weight(.light)) }
                }.frame(width: 44, height: 44)
                    .foregroundStyle(completed ? Color.green : Color.secondary)
                    .contentShape(Rectangle())
            }.buttonStyle(.borderless).disabled(disabled)
                .accessibilityLabel((!TaskTodoRules.canToggleCompletion(task) ? "编辑为整数进度：" : completed ? "重新打开，进度归零：" : "标记完成：") + task.title)
                .accessibilityIdentifier("todoComplete.\(task.id)")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.title).font(.body.weight(.medium))
                            .foregroundStyle(completed ? .secondary : .primary)
                            .strikethrough(completed).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if task.priority == "high" {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("重要")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { dueLabel; contextLabel }
                        VStack(alignment: .leading, spacing: 4) { dueLabel; contextLabel }
                    }.font(.caption).foregroundStyle(.secondary)
                    if task.progressTotal > 1 {
                        HStack(spacing: 10) {
                            ProgressView(value: min(task.progressCompleted, task.progressTotal), total: task.progressTotal).tint(completed ? .green : .accentColor)
                                .accessibilityHidden(true)
                            Text(task.progressCompleted.formatted() + " / " + task.progressTotal.formatted() + (task.progressUnit.isEmpty ? "" : " " + task.progressUnit))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("查看任务详情")
                .accessibilityIdentifier("todoOpen.\(task.id)")
        }.listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 16))
    }

    /// 构建截止或开始标记；参数：无；返回值：相对日期与已有时分，逾期同时有文字和符号，未安排不占位；无副作用。
    @ViewBuilder
    private var dueLabel: some View {
        if !task.endDate.isEmpty {
            let overdue = !completed && Values.taskIsOverdue(task, all: [task], now: now)
            Label(dateLabel(task.endDate) + (task.endTime.isEmpty ? "" : " " + task.endTime) + (overdue ? " · 逾期" : ""), systemImage: overdue ? "clock.badge.exclamationmark" : "calendar")
                .foregroundStyle(overdue ? Color.red : Color.secondary)
        } else if !task.startDate.isEmpty {
            Label(dateLabel(task.startDate) + "开始", systemImage: "calendar")
        }
    }

    /// 构建清单上下文；参数：无；返回值：完整清单名，不重复任务标题；无副作用。
    @ViewBuilder
    private var contextLabel: some View {
        if !context.isEmpty { Label(context, systemImage: "folder").lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
    }

    /// 转换相对日期；参数：day 为合法 API 日期；返回值：今天、明天或原日期；保留跨年日期，不用错误时区解析，无副作用。
    private func dateLabel(_ day: String) -> String {
        if day == Values.day(now) { return "今天" }
        if day == Values.day(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now) { return "明天" }
        return day
    }
}
