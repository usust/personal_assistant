import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var error: String?
    @State private var loading = false
    @State private var creating = false
    private var focus: [AssistantTask] {
        store.tasks.filter { !$0.archived && $0.taskType == "subtask" && Values.progress($0, all: store.tasks).fraction < 1 &&
            ((!$0.endDate.isEmpty && $0.endDate <= Values.day()) || $0.startDate == Values.day()) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    if store.isPreview { Text("界面预览 · 示例数据").font(.caption).foregroundStyle(.secondary) }
                    Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide)).font(.subheadline).foregroundStyle(.secondary)
                    Text("你好，\(store.profile?.nickname ?? "")").font(.largeTitle.bold())
                    Text(focus.isEmpty ? "从容开始，把时间留给重要的事。" : "有 \(focus.count) 件事，值得今天的专注。").foregroundStyle(.secondary)
                }
                NavigationLink { HealthView() } label: {
                    Label("健康管理 · 同步到服务器", systemImage: "heart.text.clipboard")
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 18) {
                    Label("今日专注", systemImage: "sun.max.fill").font(.headline).foregroundStyle(.teal)
                    if loading && store.tasks.isEmpty { ProgressView() }
                    else if focus.isEmpty { Text("今天的安排，由你定义。").font(.title2.bold()); Text("添加一个小目标，迈出第一步。").foregroundStyle(.secondary) }
                    else {
                        ForEach(focus.prefix(3)) { task in NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain) }
                        NavigationLink("查看全部任务") { TasksView() }
                    }
                    Button("添加任务", systemImage: "plus") { creating = true }.buttonStyle(.glassProminent).disabled(store.lists.isEmpty)
                    if store.lists.isEmpty { NavigationLink("先创建一个清单") { ListsView() }.font(.subheadline) }
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
                NavigationLink { ChatView() } label: {
                    HStack(spacing: 14) { SymbolTile(symbol: "sparkles"); VStack(alignment: .leading, spacing: 5) { Text("交给你的 AI 助手").font(.headline); Text("梳理计划，记录收支，整理思路").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
                if let error { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("今日").navigationBarTitleDisplayMode(.inline)
            .task { await reload() }.refreshable { await reload() }.sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil) }
    }
    /// 独立刷新首页模块；参数：无；返回值：无；任一模块失败仍加载另一模块并展示具体错误。
    private func reload() async {
        loading = true; defer { loading = false }; var failures: [String] = []
        do { try await store.loadTasks() } catch { failures.append("任务：" + error.localizedDescription) }
        do { try await store.loadFinance() } catch { failures.append("财务：" + error.localizedDescription) }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
