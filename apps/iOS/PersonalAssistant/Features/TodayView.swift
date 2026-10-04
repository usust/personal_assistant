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
    /// 筛选今日未完成任务；参数：无；返回值：当前缓存的今日或逾期任务；仅用于展示，不改变存储。
    private var focus: [AssistantTask] {
        store.tasks.filter { !$0.archived && $0.taskType == "subtask" && Values.progress($0, all: store.tasks).fraction < 1 &&
            ((!$0.endDate.isEmpty && $0.endDate <= Values.day()) || $0.startDate == Values.day()) }
    }
    /// 构建今日首页；参数：无；返回值：保持原布局的原生页面；任务与财务错误分别在所属区域展示。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    if store.isPreview { Text("界面预览 · 示例数据").font(.caption).foregroundStyle(.secondary) }
                    Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide)).font(.subheadline).foregroundStyle(.secondary)
                    Text("你好，\(store.profile?.nickname ?? "")").font(.largeTitle.bold())
                    if taskLoaded { Text(focus.isEmpty ? "从容开始，把时间留给重要的事。" : "有 \(focus.count) 件事，值得今天的专注。").foregroundStyle(.secondary) }
                }
                NavigationLink { HealthView() } label: {
                    Label("健康管理 · 同步到服务器", systemImage: "heart.text.clipboard")
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 18) {
                    Label("今日专注", systemImage: "sun.max.fill").font(.headline).foregroundStyle(.teal)
                    if !focus.isEmpty {
                        // 任务行回调输入缓存任务、输出详情导航；刷新失败仍保留已显示的任务。
                        ForEach(focus.prefix(3)) { task in NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain) }
                        NavigationLink("查看全部任务") { TasksView() }
                    } else if taskLoading { ProgressView("加载任务…") }
                    else if taskLoaded && taskError == nil && store.taskNotice == nil { Text("今天的安排，由你定义。").font(.title2.bold()); Text("添加一个小目标，迈出第一步。").foregroundStyle(.secondary) }
                    if let notice = store.taskNotice { InlineError(message: notice) }
                    else if let taskError { InlineError(message: "任务：" + taskError) }
                    // 同会话读取被更新快照淘汰时取消保持静默；未加载且无缓存内容仍提供只读刷新入口，不误称为空或失败。
                    if taskError != nil || store.taskNotice != nil || (!taskLoading && !taskLoaded && focus.isEmpty) {
                        // 重试回调输入无、输出无；只读取任务，不重复财务加载或写请求。
                        Button("刷新任务") { Task { await reloadTasks() } }.disabled(taskLoading)
                    }
                    Button("添加任务", systemImage: "plus") { creating = true }.buttonStyle(.glassProminent)
                        .disabled(store.lists.isEmpty || taskLoading || store.taskWriteBusy || store.taskWriteBlocked)
                    if taskLoaded && store.lists.isEmpty { NavigationLink("先创建一个清单") { ListsView() }.font(.subheadline) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
                if let overview = store.overview {
                    Text("财务一瞥").font(.title2.bold())
                    ViewThatFits(in: .horizontal) {
                        HStack { MetricCard(title: "本月支出", value: Values.money(overview.monthExpense), symbol: "arrow.up.right", color: .orange); MetricCard(title: "本月结余", value: Values.money(overview.monthBalance), symbol: "leaf") }
                        VStack { MetricCard(title: "本月支出", value: Values.money(overview.monthExpense), symbol: "arrow.up.right", color: .orange); MetricCard(title: "本月结余", value: Values.money(overview.monthBalance), symbol: "leaf") }
                    }
                    NavigationLink { FinanceView() } label: { Label("打开财务", systemImage: "chart.pie") }
                }
                if let financeError { InlineError(message: "财务：" + financeError) }
                NavigationLink { ChatView() } label: {
                    HStack(spacing: 14) { SymbolTile(symbol: "sparkles"); VStack(alignment: .leading, spacing: 5) { Text("交给你的 AI 助手").font(.headline); Text("梳理计划，记录收支，整理思路").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
            }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("今日").navigationBarTitleDisplayMode(.inline)
            // 会话回调输入前后会话标识、输出无；旧读取和 defer 作废，避免旧账号反馈进入新会话。
            .onChange(of: store.cloudSessionID) { _, _ in
                taskReadSequence += 1; reloadSequence += 1
                taskLoading = true; taskLoaded = false; taskError = nil; financeError = nil
            }
            .task(id: store.cloudSessionID) { await reload() }.refreshable { await reload() }.sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil) }
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
