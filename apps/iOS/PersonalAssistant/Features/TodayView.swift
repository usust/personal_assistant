import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var taskError: String?
    @State private var financeError: String?
    @State private var taskLoading = true
    @State private var taskLoaded = false
    @State private var taskReadSequence = 0
    @State private var reloadSequence = 0
    @State private var creating = false
    @State private var pendingTaskID: Int?
    @State private var openedTaskID: Int?
    @State private var correctionTask: AssistantTask?
    /// 筛选今日未完成任务；参数：无；返回值：与待办视图相同的今日及逾期可执行叶节点，按截止和优先级排序；归档祖先与历史具体容器不会进入专注，无副作用。
    private var focus: [AssistantTask] {
        TaskTodoRules.tasks(in: store.tasks, filter: .today)
    }
    /// 构建今日工作台；参数：无；返回值：先任务后收支的实底阅读布局与原生玻璃新增操作；任务与财务错误分别展示。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppVisualStyle.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    if store.isPreview { Text("界面预览 · 示例数据").font(.caption).foregroundStyle(.secondary) }
                    Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide)).font(.subheadline).foregroundStyle(.secondary)
                    Text(greeting).font(.title2.weight(.semibold))
                }
                AppSectionHeading(title: "今日专注", detail: taskLoaded ? "\(focus.count) 项待办" : "")
                VStack(alignment: .leading, spacing: 18) {
                    if !focus.isEmpty {
                        // 任务行回调输入缓存任务、输出详情导航；刷新失败仍保留已显示的任务。
                        ForEach(Array(focus.prefix(3).enumerated()), id: \.element.id) { index, task in
                            if index > 0 { Divider() }
                            TaskTodoRow(task: task, context: store.lists.first(where: { $0.id == task.listId })?.name ?? "", now: .now,
                                        busy: pendingTaskID == task.id, disabled: store.taskWriteBusy || store.taskWriteBlocked || pendingTaskID != nil,
                                        onToggle: { Task { await complete(task) } }, onOpen: { openedTaskID = task.id })
                        }
                        NavigationLink("查看全部待办") { TasksView() }
                    } else if taskLoading { ProgressView("加载任务…") }
                    else if taskLoaded && taskError == nil && store.taskNotice == nil { Label("今天暂无待办", systemImage: "checkmark.circle").font(.headline) }
                    if let notice = store.taskNotice { InlineError(message: notice) }
                    else if let taskError { InlineError(message: "任务：" + taskError) }
                    // 同会话读取被更新快照淘汰时取消保持静默；未加载且无缓存内容仍提供只读刷新入口，不误称为空或失败。
                    if taskError != nil || store.taskNotice != nil || (!taskLoading && !taskLoaded && focus.isEmpty) {
                        // 重试回调输入无、输出无；只读取任务，不重复财务加载或写请求。
                        Button("刷新任务") { Task { await reloadTasks() } }.disabled(taskLoading)
                    }
                    Button("添加待办", systemImage: "plus") { creating = true }.buttonStyle(.glassProminent)
                        .disabled(store.lists.isEmpty || taskLoading || store.taskWriteBusy || store.taskWriteBlocked)
                    if taskLoaded && store.lists.isEmpty { NavigationLink("先创建一个清单") { ListsView() }.font(.subheadline) }
                }.padding(AppVisualStyle.cardInset).frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                if let overview = store.overview {
                    AppSectionHeading(title: "本月收支")
                    NavigationLink { FinanceView() } label: {
                        ContentCard {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack {
                                    Text("本月支出").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                AmountText(value: Values.money(overview.monthExpense)).foregroundStyle(FinanceVisualStyle.expense)
                                Divider()
                                MetricRow(title: "本月结余", value: Values.money(overview.monthBalance), symbol: "equal.circle")
                            }.privacySensitive()
                        }
                    }.buttonStyle(.plain).accessibilityHint("打开财务")
                }
                if let financeError { InlineError(message: "财务：" + financeError) }
                ContentCard {
                    VStack(spacing: 14) {
                        NavigationLink { ChatView() } label: {
                            HStack(spacing: 8) {
                                AppDestinationLabel(title: "助手", symbol: "sparkles", subtitle: "整理任务与收支")
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }.buttonStyle(.plain)
                        Divider()
                        NavigationLink { HealthView() } label: {
                            HStack(spacing: 8) {
                                AppDestinationLabel(title: "健康管理", symbol: "heart.text.clipboard", color: .pink)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(AppVisualStyle.pageInset).frame(maxWidth: AppVisualStyle.maxContentWidth).frame(maxWidth: .infinity)
        }.background(AppVisualStyle.canvas).navigationTitle("今日").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $openedTaskID) { TaskDetailView(taskID: $0) }
            // 会话回调输入前后会话标识、输出无；旧读取和 defer 作废，避免旧账号反馈进入新会话。
            .onChange(of: store.cloudSessionID) { _, _ in
                taskReadSequence += 1; reloadSequence += 1
                taskLoading = true; taskLoaded = false; taskError = nil; financeError = nil
                pendingTaskID = nil; openedTaskID = nil; correctionTask = nil; creating = false
            }
            .task(id: store.cloudSessionID) { await reload() }.refreshable { await reload() }.sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil, initialDeadline: .now) }
            .sheet(item: $correctionTask) { TaskEditor(task: $0, parent: nil) }
    }
    /// 完成今日待办；参数：task 为当前叶节点快照；返回值：无；经共享写保护更新完成量，服务确认后合并并独立刷新，失败保留快照且不重发。
    private func complete(_ task: AssistantTask) async {
        guard pendingTaskID == nil, !store.taskWriteBusy, !store.taskWriteBlocked,
              let current = TaskTodoRules.actionable(in: store.tasks).first(where: { $0.id == task.id }), current == task else { return }
        guard TaskTodoRules.canToggleCompletion(task) else { correctionTask = task; return }
        let generation = store.cloudSessionID
        pendingTaskID = task.id
        defer { if generation == store.cloudSessionID { pendingTaskID = nil } }
        do {
            // 写回调无参数，返回服务端实体；只更新完成字段，不覆盖日期、标题或量化总量。
            let saved: AssistantTask = try await store.writeTask {
                try await store.api.request("/tasks/\(task.id)", method: "PATCH", body: TaskTodoRules.completionPatch(for: task))
            }
            store.upsertTask(saved); taskError = nil
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            taskError = error.localizedDescription
        }
    }

    /// 获取问候标题；参数：无；返回值：有昵称时显示昵称，否则省去逗号与空白，无副作用。
    private var greeting: String {
        let nickname = store.profile?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? "你好" : "你好，\(nickname)"
    }

    /// 独立读取任务卡；参数：无；返回值：无；只有同会话最新完整快照成功才确认为已加载，取消静默，失败保留缓存。
    private func reloadTasks() async {
        guard store.canUseCloud else { return }
        let generation = store.cloudSessionID
        taskReadSequence += 1
        let sequence = taskReadSequence
        taskLoading = true
        defer { if generation == store.cloudSessionID && sequence == taskReadSequence { taskLoading = false } }
        do {
            try await store.loadTasks()
            guard generation == store.cloudSessionID, sequence == taskReadSequence, !Task.isCancelled else { return }
            taskLoaded = true; taskError = nil
        } catch {
            guard !(error is CancellationError), generation == store.cloudSessionID, sequence == taskReadSequence, !Task.isCancelled else { return }
            taskError = error.localizedDescription
        }
    }
    /// 按原顺序刷新首页模块；参数：无；返回值：无；任务失败仍读财务，旧会话或过期首页读取不继续财务，财务错误单独显示。
    private func reload() async {
        guard store.canUseCloud else { return }
        let generation = store.cloudSessionID
        reloadSequence += 1
        let sequence = reloadSequence
        await reloadTasks()
        guard generation == store.cloudSessionID, sequence == reloadSequence, !Task.isCancelled else { return }
        do {
            try await store.loadFinance()
            guard generation == store.cloudSessionID, sequence == reloadSequence, !Task.isCancelled else { return }
            financeError = nil
        } catch {
            guard !(error is CancellationError), generation == store.cloudSessionID, sequence == reloadSequence, !Task.isCancelled else { return }
            financeError = error.localizedDescription
        }
    }
}
