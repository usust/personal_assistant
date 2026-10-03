import SwiftUI

/// 账户流水顶部摘要，金额使用服务端全量汇总，不依赖当前流水分页。
struct AccountTransactionSummary: View {
    let account: FinancialAccount
    /// 变更回调无参数、无返回值；刷新账户流水和摘要。
    let onChange: () async -> Void
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var repaying = false
    @State private var showingInstallments = false
    /// 构建账户摘要；参数：无；返回值：账户、欠款或余额、可用额度与可点击的分期待入账金额。
    var body: some View {
        let provider = AccountProvider.resolve(type: account.accountType, institution: account.institution)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AccountProviderIcon(provider: provider, size: 32)
                Text(account.name).font(.headline).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if provider.isCredit { Button("还款") { repaying = true }.buttonStyle(.borderless) }
                Menu("更多") {
                    Button("编辑账户") { editing = true }
                    NavigationLink("记账模板") { FinancePresetsView(kind: .template) }
                    NavigationLink("周期记账") { FinancePresetsView(kind: .recurring) }
                }.buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.isCredit ? "当前欠款（\(account.currency)）" : "余额（\(account.currency)）").font(.caption).foregroundStyle(.secondary)
                Text(AccountPresentation.money(provider.isCredit ? -AccountPresentation.balance(account) : AccountPresentation.balance(account)))
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
            }
            HStack {
                if provider.isCredit, let available = AccountPresentation.availableCredit(account) {
                    Text("可用额度 " + AccountPresentation.money(available))
                }
                Spacer(minLength: 4)
                Text(AccountPresentation.cycleHint(account))
            }.font(.caption).foregroundStyle(.secondary)
            // 点击回调无参数、无返回值；使用程序化导航，避免 List 自动添加右箭头。
            Button { showingInstallments = true } label: {
                Text("分期待入账金额：" + (account.installmentPendingAmount.map { Values.money($0) } ?? "—")
                     + "（含利息：" + (account.installmentPendingInterest.map { Values.money($0) } ?? "—") + "）")
                    .font(.caption).foregroundStyle(Color.accentColor)
                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if account.institution == "贷款" { NavigationLink("贷款详情") { LoanAccountDetail(accountID: account.id) } }
        }.padding(.vertical, 6)
            .navigationDestination(isPresented: $showingInstallments) {
                ConsumptionInstallmentsView(accountID: account.id).onDisappear { Task { await onChange() } }
            }
            .sheet(isPresented: $editing, onDismiss: refresh) { AccountEditor(account: account) }
            .sheet(isPresented: $repaying, onDismiss: refresh) { TransactionEditor(initialRepaymentID: account.id) }
    }
    /// 处理账户操作返回；参数：无；返回值：无，异步刷新父页面。
    private func refresh() { Task { await onChange() } }
}

/// 消费分期列表响应，计划包含每期最新状态，待入账金额由服务端精确计算。
nonisolated struct ConsumptionInstallmentSummary: Decodable, Identifiable {
    /// 返回计划标识；参数：无；返回值：主账单 ID，稳定用于列表导航。
    var id: Int { bill.id }
    let bill: FinanceTransaction
    let plan: ConsumptionInstallmentPlan
    let pendingAmount: String
    let pendingInterest: String
    let nextDate: String
}

struct ConsumptionInstallmentsView: View {
    let accountID: Int
    @Environment(AppStore.self) private var store
    @State private var items: [ConsumptionInstallmentSummary] = []
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var adding = false
    @State private var editing: ConsumptionInstallmentSummary?
    @State private var selected: ConsumptionInstallmentSummary?
    @State private var action = ""
    /// 构建账户内消费分期列表；参数：无；返回值：可查看、左滑管理及新增的分期卡片。
    var body: some View {
        List {
            if let error { InlineError(message: error); Button("重试") { Task { await load() } } }
            if loading && items.isEmpty { ProgressView() }
            if !loading && items.isEmpty && error == nil { ContentUnavailableView("暂无消费分期", systemImage: "square.stack") }
            ForEach(items) { item in
                Section {
                    NavigationLink {
                        ConsumptionInstallmentView(bill: item.bill).onDisappear { Task { await load() } }
                    } label: { summary(item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 操作回调无参数、无返回值；完结和删除先确认，编辑使用独立草稿。
                        Button("删除", systemImage: "trash", role: .destructive) { action = "delete"; selected = item }
                        Button("编辑", systemImage: "square.and.pencil") { editing = item }.tint(.gray)
                        if !item.nextDate.isEmpty {
                            Button("完结", systemImage: "archivebox") { action = "finish"; selected = item }.tint(.blue)
                        }
                    }.disabled(busy)
                }
            }
        }.navigationTitle("消费分期").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("新增分期", systemImage: "plus") { adding = true }.disabled(busy) }
            .task { await load() }.refreshable { await load() }
            .sheet(isPresented: $adding, onDismiss: refresh) { NavigationStack { InstallmentSourcePicker(accountID: accountID) } }
            .sheet(item: $editing, onDismiss: refresh) { item in
                NavigationStack { ConsumptionInstallmentView(bill: item.bill, editingExisting: true) }
            }
            .alert(action == "finish" ? "完结分期？" : "删除分期？", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), presenting: selected) { item in
                Button(action == "finish" ? "立即入账并完结" : "删除", role: action == "delete" ? .destructive : nil) { Task { await perform(item, action: action) } }
                Button("取消", role: .cancel) { selected = nil }
            } message: { _ in
                Text(action == "finish" ? "剩余期次将全部在今天入账。" : "全部期次及关联退款将删除，已计入的欠款退回。")
            }
    }
    /// 绘制分期摘要；参数：item 为服务端摘要；返回值：名称、进度、分类、账户、金额和下次入账日，长名称单行省略。
    private func summary(_ item: ConsumptionInstallmentSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.plan.name).font(.headline).lineLimit(1).truncationMode(.tail)
                Text("\(item.plan.posted + max(0, (item.plan.startPeriod ?? 1) - 1))/\(item.plan.periods)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("分类：" + (store.categories.first { $0.id == item.bill.categoryId }?.name ?? "未分类"))
                    Text("账户：" + (store.accounts.first { $0.id == item.bill.accountId }?.name ?? "已删除账户")).lineLimit(1)
                    Text("待入账金额：" + Values.money(item.pendingAmount)).foregroundStyle(Color.accentColor)
                    Text("分期后恢复额度：" + Values.money(item.plan.restoredCredit ?? "0.00"))
                    Text("欠款计入：" + (item.plan.debtMode == "upfront" ? "一次性计入" : "分期计入"))
                    Text(item.nextDate.isEmpty ? "已结束" : "下次入账：" + item.nextDate)
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Values.money(item.plan.principal)).monospacedDigit()
                    Text((Decimal(string: item.plan.interest) ?? 0) == 0 ? "无利息" : "利息 " + Values.money(item.plan.interest)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8)
    }
    /// 刷新弹出表单后的列表；参数：无；返回值：无，异步重新加载服务端摘要。
    private func refresh() { Task { await load() } }
    /// 加载账户全部计划；参数：无；返回值：无；失败保留旧结果，账号切换后丢弃响应。
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let session = store.sessionID
        do {
            let rows: [ConsumptionInstallmentSummary] = try await store.api.request("/finance/installments", query: [URLQueryItem(name: "accountId", value: String(accountID))])
            guard session == store.sessionID && !Task.isCancelled else { return }
            items = rows; error = nil
            try await store.loadFinance()
        } catch { if session == store.sessionID { self.error = error.localizedDescription } }
    }
    /// 执行已确认的管理动作；参数：item 为目标计划，action 仅为 finish 或 delete；返回值：无；失败显示错误，重试由服务端保证幂等。
    private func perform(_ item: ConsumptionInstallmentSummary, action: String) async {
        guard !busy && ["finish", "delete"].contains(action) else { return }
        busy = true; defer { busy = false }; selected = nil
        do {
            try await store.api.mutate("/finance/installments/\(item.id)" + (action == "finish" ? "/finish" : ""), method: action == "finish" ? "POST" : "DELETE")
            await store.refreshAfterMutation(.finance); await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// 新建消费分期时选择真实原支出，沿用既有试算与转换流程。
private struct InstallmentSourcePicker: View {
    let accountID: Int
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [FinanceTransaction] = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    /// 构建原支出选择页；参数：无；返回值：可分页的普通支出列表，退款与分期子账单不展示。
    var body: some View {
        List {
            ForEach(rows) { row in
                NavigationLink { ConsumptionInstallmentView(bill: row) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(store.categories.first { $0.id == row.categoryId }?.name ?? "未分类"); Spacer(); Text(Values.money(row.amount)) }
                        Text(row.transactionDate + (row.description.isEmpty ? "" : " · " + row.description)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let error { InlineError(message: error) }
            if loading { ProgressView() }
            if hasMore && !loading { Button("加载更多") { Task { await load() } } }
            if !loading && !hasMore && rows.isEmpty { Text("暂无可转分期的支出").foregroundStyle(.secondary) }
        }.navigationTitle("选择消费账单").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { if rows.isEmpty { await load() } }
    }
    /// 分页读取候选支出；参数：无；返回值：无；偏移按原始页计算，不因过滤漏掉后续普通账单。
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let session = store.sessionID
        do {
            let page: [FinanceTransaction] = try await store.api.request("/finance/transactions", query: [URLQueryItem(name: "accountId", value: String(accountID)), URLQueryItem(name: "status", value: "posted"), URLQueryItem(name: "type", value: "expense"), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset))])
            guard session == store.sessionID && !Task.isCancelled else { return }
            // 过滤闭包输入流水，输出是否可作为新分期主账单；已退款金额最终由服务端校验。
            rows += page.filter { $0.installmentParentId == nil && $0.refundParentId == nil }
            offset += page.count; hasMore = page.count == 50; error = nil
        } catch { if session == store.sessionID { self.error = error.localizedDescription } }
    }
}
