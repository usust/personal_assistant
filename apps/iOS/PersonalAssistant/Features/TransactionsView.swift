import SwiftUI

struct TransactionsView: View {
    /// 账户入口传入有效账户 ID 以固定流水范围；nil 表示全部账户的全局流水。
    var scopedAccountID: Int? = nil
    var financeHome = false
    @State private var month = FinanceMonth.current()
    @State private var monthSummary: FinanceMonthSummary?
    @State private var addingAccount = false
    @State private var showingLoanPreview = false
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rows: [FinanceTransaction] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hasMore = false
    @State private var choosingTemplate = false
    @State private var creating = false
    @State private var showingTextBookkeeping = false
    @State private var pendingAction: FinanceTransaction?
    @State private var selected: FinanceTransaction?
    @State private var editing: FinanceTransaction?
    @State private var refunding: FinanceTransaction?
    @State private var deleting: FinanceTransaction?
    @State private var deletingBusy = false
    @State private var requestID = UUID()
    @State private var displayedScope: String?
    @State private var loaded = false
    /// 标识读取范围；参数：无；返回值：会话账本、账户及首页月份组成的范围，版本变化仅刷新同一范围。
    private var loadScope: String { "\(store.sessionID)|\(effectiveAccountID)|\(financeHome ? month.id : "all")" }
    @State private var expandedPeriods: Set<String> = []
    @State private var initializedPeriods = false
    @State private var statementAmounts: [String: String] = [:]
    /// 获取请求账户范围；参数：无；返回值：固定账户 ID，0 表示全部账户。
    private var effectiveAccountID: Int { scopedAccountID ?? 0 }
    /// 获取当前账户资料；参数：无；返回值：账户入口对应的最新资料，全局入口为 nil。
    private var scopedAccount: FinancialAccount? { store.accounts.first { $0.id == scopedAccountID } }
    /// 读取尚未入账的图片任务；参数：无；返回值：当前空间处理中、待确认或失败记录；损坏状态交由图片记账页显示错误，不影响流水读取。
    private var pendingScreenshots: [ScreenshotJob] {
        guard let book = try? store.finance?.screenshotBook() else { return [] }
        return book.jobs.filter { $0.transactionID == nil && ["queued", "processing", "review", "failed"].contains($0.state) }
    }
    /// 构建流水列表；参数：无；返回值：首页按所选月份展示日流水和汇总卡片，卡片后提供独立的当前月财务分析入口，导航栏提供账户与原生记账菜单；独立全局或账户页保留月份折叠与分页，读取、写入与会话保护沿用原有流程。
    var body: some View {
        List {
            if financeHome {
                Section {
                    FinanceDashboardHeader(month: $month, summary: monthSummary, overview: store.overview)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    // 导航构造回调无参数、返回完整总览分析页；与首页月份筛选独立，固定分析当前月及近六个月，不使用分页流水。
                    NavigationLink { BillAnalysisView() } label: {
                        Label("财务分析", systemImage: "chart.bar.xaxis")
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("finance-analysis-entry")
                }
                if store.accounts.isEmpty && !loading {
                    Section { Button("添加账户", systemImage: "creditcard") { addingAccount = true } }
                }
            }
            if let account = scopedAccount {
                Section { AccountTransactionSummary(account: account) { await load(reset: true) } }
                if AccountProvider.resolve(type: account.accountType, institution: account.institution).isCredit && account.institution != "贷款" {
                    Section { CreditStatementCard(account: account) { await load(reset: true) } }
                }
            }
            if financeHome && !pendingScreenshots.isEmpty {
                Section {
                    NavigationLink {
                        ScreenshotBookkeepingView()
                    } label: {
                        LabeledContent("图片记账待处理", value: String(pendingScreenshots.count))
                    }
                }
            }
            if let error { InlineError(message: error); Button("重新加载") { Task { await load(reset: true) } } }
            if loaded && !loading && error == nil && rows.isEmpty { ContentUnavailableView("暂无流水", systemImage: "tray") }
            if financeHome { homeDaySections } else { accountPeriodSections }
            if loading { ProgressView("加载流水…") }
            if hasMore && !loading { Button("加载更多") { Task { await load(reset: false) } } }
        }.listStyle(.insetGrouped).listSectionSpacing(AppVisualStyle.sectionSpacing)
            .contentMargins(.horizontal, AppVisualStyle.pageInset, for: .scrollContent)
            .frame(maxWidth: AppVisualStyle.maxContentWidth).frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(financeHome ? "财务" : scopedAccountID == nil ? "交易流水" : "账户详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if financeHome {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { AccountsView() } label: {
                            Label("账户", systemImage: "wallet.bifold").labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("账户")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section {
                                NavigationLink { CategoriesView() } label: { Label("分类管理", systemImage: "square.grid.2x2") }
                                NavigationLink { FinancePresetsView(kind: .template) } label: { Label("记账模板", systemImage: "doc.on.doc") }
                                NavigationLink { FinancePresetsView(kind: .recurring) } label: { Label("周期记账", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
                            }
                            Section {
                                // 快捷记账回调无参数、无返回值；复用现有文本和图片确认流程，不直接写入流水。
                                Button("文本记账", systemImage: "text.bubble") { showingTextBookkeeping = true }
                                Button("图片记账", systemImage: "photo") { store.showScreenshotBookkeeping = true }
                            }
                        } label: {
                            Label("财务管理", systemImage: "ellipsis").labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }.menuOrder(.fixed).accessibilityLabel("财务管理")
                    }
                } else if scopedAccountID == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("记账管理") {
                            NavigationLink("记账模板") { FinancePresetsView(kind: .template) }
                            NavigationLink("周期记账") { FinancePresetsView(kind: .recurring) }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { transactionEntryMenu }
            }
            // 范围切换回调接收新旧范围、返回值无；立即作废上一范围，即使随后切回也不复用旧请求。
            .onChange(of: loadScope) { _, _ in synchronizeScope() }
            .task(id: "\(loadScope)|\(store.finance?.revision ?? 0)") { await load(reset: true) }
            .task {
                #if DEBUG
                if financeHome && store.isPreview && ProcessInfo.processInfo.arguments.contains("--loan-ui") { showingLoanPreview = true }
                if financeHome && store.isPreview && ProcessInfo.processInfo.arguments.contains("--transaction-ui") { creating = true }
                #endif
            }
            .refreshable { await load(reset: true) }
            .navigationDestination(isPresented: $showingLoanPreview) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--loan-plan") { LoanAccountPlan(accountID: 3) }
                else { LoanAccountDetail(accountID: 3) }
                #endif
            }
            .sheet(isPresented: $addingAccount, onDismiss: { Task { await load(reset: true) } }) { AccountEditor(account: nil) }
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    if selected.screenshotJobID != nil { TransactionEditor(editingTransaction: rows.first { $0.id == selected.id } ?? selected) }
                    else { TransactionDetailView(transaction: rows.first { $0.id == selected.id } ?? selected) {
                        await refreshSelected()
                        await load(reset: true)
                        await store.refreshAfterMutation(.finance)
                    } }
                }
            }
            .sheet(item: $editing, onDismiss: { Task { await load(reset: true) } }) { TransactionEditor(editingTransaction: $0) }
            .sheet(item: $refunding, onDismiss: { Task { await load(reset: true) } }) { TransactionRefundEditor(transaction: $0) }
            .alert("删除流水？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { transaction in
                // 确认回调捕获目标流水；参数、返回值无；异步删除失败保留列表并显示错误。
                Button("删除", role: .destructive) { Task { await deleteTransaction(transaction) } }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { transaction in Text(transaction.installmentParentId != nil ? "仅删除本期，已计入欠款退回，关联退款一并撤销，其他期次不变。" : "已入账金额将回退，关联退款或优惠一并撤销。") }
            .navigationDestination(isPresented: $choosingTemplate) {
                FinancePresetsView(kind: .template, useForTransaction: true)
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await load(reset: true) } }) { TransactionEditor(initialAccountID: scopedAccountID) }
            // 文本页退出回调无参数、返回值无；无论取消或保存均重读当前范围，不把刷新错误当成文本保存失败。
            .sheet(isPresented: $showingTextBookkeeping, onDismiss: { Task { await load(reset: true) } }) {
                TextBookkeepingView(initialAccountID: scopedAccountID)
            }
            .confirmationDialog("确认操作？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
                if let transaction = pendingAction { Button("确认入账") { Task { await apply(transaction) } } }
            } message: { Text(pendingAction?.rebateParentId != nil ? "优惠按今天到账入账。" : (Decimal(string: pendingAction?.rebate ?? "0") ?? 0) > 0 ? "关联优惠将随转账入账。" : "此操作会改变账户余额，并保留流水记录。") }
    }
    /// 构建原生记账菜单；参数：无；返回值：有账户时短按记一笔、展开菜单选择其他方式，空账户时短按仍可展开图片入口；只切换已有页面状态，无业务写入。
    @ViewBuilder private var transactionEntryMenu: some View {
        // 空账户不注册主操作，避免一个被禁用的外层 Menu 同时阻断图片记录查看；各记账选项独立校验账户。
        if store.accounts.isEmpty {
            Menu { transactionEntryActions } label: { transactionEntryLabel }
                .accessibilityLabel("记账方式")
        } else {
            Menu { transactionEntryActions } label: { transactionEntryLabel } primaryAction: {
                // 主操作回调无参数、返回值无；仅打开原记账表单，账户变化时仍阻止无账户记账。
                guard !store.accounts.isEmpty else { return }
                creating = true
            }
            .accessibilityLabel("记一笔")
        }
    }
    /// 绘制记账入口标签；参数：无；返回值：至少 44 点触控区域的系统加号，文字名称由原生菜单向 VoiceOver 提供；无副作用。
    private var transactionEntryLabel: some View {
        Label("记一笔", systemImage: "plus").labelStyle(.iconOnly)
            .font(.title2).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    /// 构建记账菜单选项；参数：无；返回值：普通记账、模板、文本与图片入口，只有前两项在空账户时禁用；无直接数据写入。
    @ViewBuilder private var transactionEntryActions: some View {
        // 普通记账回调无参数、返回值无；打开原记账表单，保留其账户预选与保存流程。
        Button("记一笔", systemImage: "plus") { creating = true }.disabled(store.accounts.isEmpty)
        // 模板回调无参数、返回值无；打开既有模板选择页面，不复制模板或预先创建流水。
        Button("使用模板记账", systemImage: "doc.on.doc") { choosingTemplate = true }.disabled(store.accounts.isEmpty)
        // 文本回调无参数、返回值无；只打开主动粘贴及候选确认页，不读取短信或自动创建流水。
        Button("文本记账", systemImage: "text.bubble") { showingTextBookkeeping = true }
        // 图片回调无参数、返回值无；复用全局图片记录页面，无账户时也可查看已有记录。
        Button("图片记账", systemImage: "photo") { store.showScreenshotBookkeeping = true }
    }
    /// 将所选月份流水按日排列；参数：无；返回值：可水平或纵向适配的日收支标题及共用流水操作，月份选择和统计仍由上方卡片负责；无业务副作用。
    private var homeDaySections: some View {
        let days = Dictionary(grouping: rows) { $0.transactionDate }
        return ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Section {
                ForEach(days[day] ?? []) { transaction in transactionListRow(transaction) }
            } header: {
                homeDayHeader(day, transactions: days[day] ?? [])
            }
        }
    }
    /// 绘制首页日标题；参数：day 为原始自然日，transactions 为该日已加载流水；返回值：宽度充足时同行、窄屏或大字号时纵向的日期和原有日收支，不修改汇总算法。
    private func homeDayHeader(_ day: String, transactions: [FinanceTransaction]) -> some View {
        let flow = AccountTransactionPeriods.flow(transactions, accountID: nil)
        let expense = "支出 " + AccountPresentation.money(flow.outflow)
        let income = flow.inflow != 0 ? "收入 " + AccountPresentation.money(flow.inflow) : nil
        let title = dayTitle(day) + (hasMore && day == rows.map(\.transactionDate).min() ? " · 已加载" : "")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).fixedSize()
                Spacer(minLength: 8)
                Text(expense).fontDesign(.rounded).monospacedDigit().fixedSize()
                if let income { Text(income).fontDesign(.rounded).monospacedDigit().fixedSize() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(expense).fontDesign(.rounded).monospacedDigit()
                if let income { Text(income).fontDesign(.rounded).monospacedDigit() }
            }.fixedSize(horizontal: false, vertical: true)
        }.font(.caption2).textCase(nil).accessibilityElement(children: .combine)
    }
    /// 绘制可操作流水行；参数：transaction 为真实流水；返回值：至少 44 点高的详情入口与原有编辑、删除、退款等侧滑操作，保留独立行交互和业务权限判断。
    private func transactionListRow(_ transaction: FinanceTransaction) -> some View {
        // 详情回调无参数、返回值无；只选中原流水，沿用已有详情或图片编辑分流。
        Button { selected = transaction } label: { transactionRow(transaction).frame(minHeight: 44) }
            .buttonStyle(.plain)
            // 流水上下各保留 8 点留白，左右使用共享内容边距，避免系统行内边距与内容 padding 叠加。
            .listRowInsets(EdgeInsets(top: 8, leading: AppVisualStyle.pageInset, bottom: 8, trailing: AppVisualStyle.pageInset))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 左滑按钮回调无参数、无返回值；仅打开确认或表单，不直接改余额。
                Button { deleting = transaction } label: { Label("删除", systemImage: "trash") }
                    .tint(.red).disabled(!canDelete(transaction) || deletingBusy)
                // 编辑回调无参数和返回值；截图流水与完整流水共用编辑器。
                Button { editing = transaction } label: { Label("编辑", systemImage: "pencil") }
                    .tint(.blue).disabled(transaction.status == "voided" || deletingBusy)
                if transaction.status == "pending" && transaction.installmentParentId == nil {
                    // 待确认流水使用同一侧滑区域入账；回调无参数、无返回值，仅打开确认提示。
                    Button { pendingAction = transaction } label: { Label("确认入账", systemImage: "checkmark") }
                        .tint(.green).disabled(deletingBusy)
                } else {
                    // 退款回调无参数、返回值无；只打开既有退款表单，资格判断与退款写入流程保持不变。
                    Button { refunding = transaction } label: { Label("退款", systemImage: "arrow.uturn.backward") }
                        .tint(.orange).disabled(transaction.type != "expense" || transaction.status != "posted" || transaction.refundParentId != nil || deletingBusy)
                }
            }
    }
    /// 刷新详情目标；参数：无；返回值：无；按原日期与账户分页查找，避免状态变更后被列表筛选排除而显示旧详情。
    private func refreshSelected() async {
        guard let current = selected else { return }
        let generation = store.sessionID
        do {
            var offset = 0
            while !Task.isCancelled {
                let page: [FinanceTransaction] = try await store.api.request("/finance/transactions", query: [
                    URLQueryItem(name: "accountId", value: String(current.accountId)),
                    URLQueryItem(name: "startDate", value: current.transactionDate),
                    URLQueryItem(name: "endDate", value: current.transactionDate),
                    URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "offset", value: String(offset))
                ])
                guard generation == store.sessionID else { return }
                if let updated = page.first(where: { $0.id == current.id }) { selected = updated; return }
                if page.count < 500 { return }
                offset += page.count
            }
        } catch { self.error = error.localizedDescription }
    }
    /// 获取月份卡片；参数：无；返回值：全局流水按自然月，固定信用账户按账单日归类的已加载流水。
    private var accountPeriods: [AccountTransactionPeriod] {
        let credit = scopedAccount.map { AccountProvider.resolve(type: $0.accountType, institution: $0.institution).isCredit } ?? false
        return AccountTransactionPeriods.groups(rows, billingDay: credit ? scopedAccount?.billingDay : nil, inclusive: scopedAccount?.billDayInclusive ?? true)
    }
    /// 构建全局或账户月份卡片；参数：无；返回值：卡片内月份摘要、按天排列的流水与独立行操作，折叠状态保留。
    @ViewBuilder private var accountPeriodSections: some View {
        ForEach(accountPeriods) { period in
            Section {
                Button {
                    if !expandedPeriods.insert(period.id).inserted { expandedPeriods.remove(period.id) }
                } label: { periodHeader(period) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .accessibilityLabel(period.title + (expandedPeriods.contains(period.id) ? "，折叠" : "，展开"))
                if expandedPeriods.contains(period.id) {
                    // 分组闭包接收流水，返回真实自然日；日标题与明细位于同一月份卡片。
                    let days = Dictionary(grouping: period.rows) { $0.transactionDate }
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        HStack {
                            Text(dayTitle(day) + (hasMore && day == rows.map(\.transactionDate).min() ? " · 已加载" : ""))
                            Spacer(minLength: 4)
                            let flow = AccountTransactionPeriods.flow(days[day] ?? [], accountID: scopedAccountID)
                            Text((scopedAccountID == nil ? "支出: " : "流出: ") + AccountPresentation.money(flow.outflow))
                        }.font(.caption2).foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                        ForEach(days[day] ?? []) { transaction in transactionListRow(transaction) }
                    }
                }
            }
        }
    }
    /// 绘制月份摘要；参数：period 为账期及已加载流水；返回值：年月、日期范围与已入账流出流入；分页未完整时标明“已加载”，账单金额由后端完整账本提供，未结束账期显示未出账。
    private func periodHeader(_ period: AccountTransactionPeriod) -> some View {
        let flow = AccountTransactionPeriods.flow(period.rows, accountID: scopedAccountID)
        let partial = hasMore && period.id == accountPeriods.last?.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(period.title).font(.headline)
                Text(String(period.start.suffix(5)).replacingOccurrences(of: "-", with: "/") + " – " + String(period.end.suffix(5)).replacingOccurrences(of: "-", with: "/"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                if let account = scopedAccount, (account.billingDay ?? 0) > 0,
                   AccountProvider.resolve(type: account.accountType, institution: account.institution).isCredit {
                    Text("账单金额：" + (period.end >= Values.day() ? "未出账" : statementAmounts[period.end].map { Values.money($0) } ?? "—"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                if partial { Text("已加载").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text((scopedAccountID == nil ? "支出: " : "流出: ") + AccountPresentation.money(flow.outflow)).foregroundStyle(.red)
                Text((scopedAccountID == nil ? "收入: " : "流入: ") + AccountPresentation.money(flow.inflow)).foregroundStyle(.green)
            }.font(.caption.weight(.semibold)).monospacedDigit()
            Image(systemName: expandedPeriods.contains(period.id) ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
    }
    /// 格式化日期标题；参数：raw 为 yyyy-MM-dd 自然日；返回值：月日与星期，跨年时显示年份，非法日期原样返回。
    private func dayTitle(_ raw: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "MM/dd EEEE" : "yyyy/MM/dd EEEE"
        return formatter.string(from: date)
    }
    /// 查询账户展示名；参数：id 为流水中的账户 ID；返回值：账户名或删除后的兜底文案，无副作用。
    private func accountName(_ id: Int) -> String { store.accounts.first { $0.id == id }?.name ?? "已删除账户" }
    /// 绘制只读流水；参数：transaction 为流水原始记录；返回值：常规字号保持紧凑同行，辅助功能字号纵向展示分类、金额、时间、备注和账户；金额与业务标记沿用原值，点击和侧滑操作由外层按钮提供，无业务副作用。
    private func transactionRow(_ transaction: FinanceTransaction) -> some View {
        // 分类查找接收目录项并返回 ID 匹配结果；图标映射接收分类并返回对应系统符号。
        let category = store.categories.first { $0.id == transaction.categoryId }
        let symbol = transaction.type == "transfer" ? "arrow.left.arrow.right" : category.map { CategoryCatalog.icon(for: $0) } ?? (transaction.type == "income" ? "plus" : "minus")
        let color = FinanceVisualStyle.color(for: transaction.type)
        let signedAmount = transaction.amount.isEmpty ? "金额待补全" : transaction.refundParentId != nil ? "+" + AccountPresentation.money(abs(Decimal(string: transaction.amount) ?? 0)) : (transaction.type == "expense" ? "−" : transaction.type == "income" ? "+" : "") + Values.money(transaction.amount)
        // 过滤回调接收对象名或备注，返回是否非空；仅组合已保存的文本，不补造交易时间。
        let installmentName = transaction.installmentName ?? "消费分期"
        // 日期已由日标题展示；缺失时间保持为空，避免重复日期或补造时分。
        let time = transaction.transactionTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = transaction.targetAccountId.map { accountName(transaction.accountId) + " → " + accountName($0) } ?? accountName(transaction.accountId)
        let installmentSummary = "消费分期 · \(installmentName)"
        let generatedNote = "\(installmentName) · \(transaction.installmentPeriod ?? 0)/\(transaction.installmentPeriods ?? 0)"
        let note = [transaction.counterparty, transaction.description].filter {
            !$0.isEmpty && (transaction.installmentParentId == nil || ($0 != installmentName && $0 != generatedNote))
        }.joined(separator: " · ")
        // 过滤回调接收说明片段并返回是否非空；分期类型、计划名和用户备注合并到同一行，避免额外占用流水高度。
        let summary = [transaction.installmentParentId != nil ? installmentSummary : "", note]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        // 仅切换文本排布；辅助功能字号不压缩金额或把备注与账户挤到同一行，常规字号保留原有信息密度。
        let accessible = dynamicTypeSize.isAccessibilitySize
        let textLayout = accessible ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // 统一紧凑淡底图标，颜色只承担交易类型提示，不再以纯色圆形与白色图标争夺金额层级。
                SymbolTile(symbol: symbol, color: color, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    textLayout {
                        Text(categoryName(transaction)).font(.subheadline.weight(.semibold))
                        if !accessible { Spacer(minLength: 4) }
                        Text(signedAmount).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                            .fixedSize(horizontal: !accessible, vertical: true)
                    }
                    if accessible {
                        VStack(alignment: .leading, spacing: 4) {
                            if !time.isEmpty { Text(time) }
                            if !summary.isEmpty { Text(summary) }
                            Text(account)
                        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // 常规字号中时间保持完整，备注使用剩余空间单行省略；账户右对齐且不换行。
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                if !time.isEmpty { Text(time).fixedSize(horizontal: true, vertical: false) }
                                if !time.isEmpty && !summary.isEmpty { Text("·").fixedSize() }
                                if !summary.isEmpty { Text(summary).lineLimit(1).truncationMode(.tail) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(account).lineLimit(1).truncationMode(.tail)
                                .multilineTextAlignment(.trailing)
                        }.font(.caption).foregroundStyle(.secondary)
                    }

                    if transaction.installmentParentId != nil {
                        textLayout {
                            Text("分期 \(transaction.installmentPeriod ?? 0)" + (transaction.installmentPeriods.map { "/\($0)" } ?? ""))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            if transaction.status != "posted" { Text(transaction.status == "pending" ? "待入账" : statusName(transaction.status)) }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    if let discount = transaction.discount, (Decimal(string: discount) ?? 0) > 0 {
                        Text("优惠 " + Values.money(discount)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let rebate = transaction.rebate, (Decimal(string: rebate) ?? 0) > 0 {
                        Text("优惠 " + Values.money(rebate)).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if transaction.status != "posted" && transaction.installmentParentId == nil { Text(statusName(transaction.status)).font(.caption2).foregroundStyle(.secondary) }
                }
            }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            if let fee = transaction.fee, (Decimal(string: fee) ?? 0) != 0 { Text("手续费 " + Values.money(fee)).font(.caption).foregroundStyle(.secondary) }
            if let rebate = transaction.rebate, (Decimal(string: rebate) ?? 0) > 0 { Text("优惠入账账户：" + accountName(transaction.rebateAccountId ?? transaction.accountId)).font(.caption).foregroundStyle(.secondary) }
            if let parent = transaction.rebateParentId { Text("关联转账 #\(parent)").font(.caption).foregroundStyle(.secondary) }
            if transaction.source == "recurring" { Text("周期记账").font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }

    /// 判断是否允许单独删除；参数：transaction 为当前流水；返回值：普通流水、退款和分期子账单可删除，主账单及关联优惠须由对应业务处理。
    private func canDelete(_ transaction: FinanceTransaction) -> Bool {
        transaction.status != "installment" && transaction.rebateParentId == nil
    }
    /// 删除流水并刷新余额；参数：transaction 为用户确认的流水；返回值：无；阻止重复提交，失败展示错误并保留原列表。
    private func deleteTransaction(_ transaction: FinanceTransaction) async {
        guard !deletingBusy else { return }
        deletingBusy = true
        defer { deletingBusy = false }
        do {
            if let jobID = transaction.screenshotJobID { try store.finance?.deleteScreenshot(jobID) }
            else { try await store.api.mutate("/finance/transactions/\(transaction.id)", method: "DELETE") }
            await load(reset: true)
            await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
    }
    /// 返回分类展示名；参数：transaction 为流水；返回值：退款或优惠优先，转账按目标账户用途命名，其余返回分类名或收支类型；无副作用。
    private func categoryName(_ transaction: FinanceTransaction) -> String {
        if transaction.refundParentId != nil { return "退款" }
        if transaction.rebateParentId != nil { return "还款优惠" }
        if transaction.type == "transfer" {
            return AccountPresentation.transferTitle(target: store.accounts.first { $0.id == transaction.targetAccountId })
        }
        return store.categories.first { $0.id == transaction.categoryId }?.name ?? (transaction.type == "income" ? "收入" : "支出")
    }
    /// 返回本地化状态；参数：value 为服务端状态；返回值：中文标签，无副作用。
    private func statusName(_ value: String) -> String { ["posted": "已入账", "pending": "待确认", "voided": "已作废", "installment": "分期主账单"][value] ?? value }
    /// 同步展示范围；参数：无；返回值：无；仅在会话、账户或月份变化时清空旧快照并作废请求，同范围刷新保持原数据。
    @MainActor private func synchronizeScope() {
        guard displayedScope != loadScope else { return }
        requestID = UUID(); displayedScope = loadScope; loading = false
        rows = []; hasMore = false; statementAmounts = [:]; monthSummary = nil
        loaded = false; error = nil; expandedPeriods = []; initializedPeriods = false
    }
    /// 分页加载流水；参数：reset 为是否刷新完整快照；返回值：无；同范围失败保留快照，范围变化清旧数据，请求代次、会话和取消共同阻止过期响应。
    @MainActor private func load(reset: Bool) async {
        guard !Task.isCancelled else { return }
        let scope = loadScope
        let changed = displayedScope != scope
        // 分页不抢占刷新，也不重复请求同一页；刷新可作废尚未返回的分页。
        guard reset || (!loading && hasMore && !changed) else { return }
        if changed { synchronizeScope() }
        let current = UUID(); requestID = current; loading = true
        defer { if requestID == current { loading = false } }
        let generation = store.sessionID
        let requestedMonth = month
        let accountID = effectiveAccountID
        let home = financeHome
        let replacing = reset || changed
        var items = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(replacing ? 0 : rows.count))]
        if accountID > 0 { items.append(URLQueryItem(name: "accountId", value: String(accountID))) }
        if home {
            items += [URLQueryItem(name: "startDate", value: requestedMonth.start), URLQueryItem(name: "endDate", value: requestedMonth.end)]
        }
        do {
            // 财务公共资料也先暂存，避免流水失败后出现新资产摘要与旧流水混合的页面。
            var nextOverview: FinanceOverview?
            var nextAccounts: [FinancialAccount]?
            var nextCategories: [TransactionCategory]?
            if replacing && (scopedAccountID != nil || home) {
                async let overviewResult: FinanceOverview = store.api.request("/finance/overview")
                async let accountResult: [FinancialAccount] = store.api.request("/finance/accounts")
                async let categoryResult: [TransactionCategory] = store.api.request("/finance/categories")
                let snapshot = try await (overviewResult, accountResult, categoryResult)
                nextOverview = snapshot.0; nextAccounts = snapshot.1; nextCategories = snapshot.2
            }
            guard current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled else { return }
            // 汇总、流水、账单全部暂存；任何一步失败均不发布半份快照。
            var summary = monthSummary
            if home && replacing {
                summary = try await store.api.request("/finance/transactions-summary", query: [URLQueryItem(name: "startDate", value: requestedMonth.start), URLQueryItem(name: "endDate", value: requestedMonth.end)])
            }
            guard current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled else { return }
            var page: [FinanceTransaction] = try await store.api.request("/finance/transactions", query: items)
            var plans: [Int: ConsumptionInstallmentPlan] = [:]
            for index in page.indices {
                guard current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled else { return }
                guard let parentID = page[index].installmentParentId,
                      page[index].installmentName == nil || page[index].installmentPeriods == nil else { continue }
                if plans[parentID] == nil {
                    plans[parentID] = try await store.api.request("/finance/transactions/\(parentID)/installment")
                }
                page[index].installmentName = plans[parentID]?.name
                page[index].installmentPeriods = plans[parentID]?.periods
            }
            guard current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled else { return }
            let nextRows = replacing ? page : rows + page
            let account = nextAccounts?.first { $0.id == scopedAccountID } ?? scopedAccount
            let credit = account.map { AccountProvider.resolve(type: $0.accountType, institution: $0.institution).isCredit } ?? false
            let periods = AccountTransactionPeriods.groups(nextRows, billingDay: credit ? account?.billingDay : nil, inclusive: account?.billDayInclusive ?? true)
            var amounts = replacing ? [:] : statementAmounts
            if let account, (account.billingDay ?? 0) > 0, credit,
               let oldest = periods.last, let newest = periods.first {
                amounts = try await store.api.request("/finance/accounts/\(account.id)/statements", query: [URLQueryItem(name: "startDate", value: oldest.start), URLQueryItem(name: "endDate", value: newest.end)])
            }
            guard current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled else { return }
            // 校验完成后在同一个主线程提交段发布公共资料与页面快照，中间不再等待网络。
            if let nextOverview, let nextAccounts, let nextCategories {
                store.overview = nextOverview; store.accounts = nextAccounts; store.categories = nextCategories
            }
            rows = nextRows; monthSummary = summary; statementAmounts = amounts
            hasMore = page.count == 50; error = nil; loaded = true
            if !initializedPeriods && !rows.isEmpty {
                let today = Values.day()
                if let current = periods.first(where: { $0.start <= today && today <= $0.end }) ?? periods.first {
                    expandedPeriods.insert(current.id)
                }
                initializedPeriods = true
            }
            // 账户提交成功后续排本机提醒；提醒失败仅记录警告，不把已读取快照回退为加载失败。
            if let nextAccounts, !store.isPreview {
                do { try await CreditReminders.sync(nextAccounts) }
                catch {
                    if current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled {
                        store.syncWarning = "账户已加载，但本机还款提醒设置失败。"
                    }
                }
            }
        } catch {
            if current == requestID && generation == store.sessionID && scope == loadScope && !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }
    /// 确认待入账流水；参数：transaction 为用户确认的待入账目标；返回值：无；其他状态不执行请求，失败显示错误。
    private func apply(_ transaction: FinanceTransaction) async {
        pendingAction = nil
        guard transaction.status == "pending" else { return }
        do { try await store.api.mutate("/finance/transactions/\(transaction.id)/confirm"); await load(reset: true); try await store.loadFinance() }
        catch { self.error = error.localizedDescription }
    }
}

struct TransactionEditor: View {
    @ScaledMetric(relativeTo: .title2) private var keypadRowHeight: CGFloat = 48
    /// 非空时编辑已有流水；新增和编辑共用所有布局，仅保存方式与可修改字段不同。
    var editingTransaction: FinanceTransaction? = nil
    var initialLoanID: Int? = nil
    var initialRepaymentID: Int? = nil
    var initialRepaymentAmount: String? = nil
    var initialAccountID: Int? = nil
    var initialPreset: FinancePreset? = nil
    var initialMode: String = "transaction"
    @State private var populated = false
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var type = "expense"
    @State private var accountID = 0
    @State private var targetID = 0
    @State private var categoryID = 0
    @State private var amount = ""
    @State private var fee = "0.00"
    @State private var rebate = "0.00"
    @State private var rebateAccountID = 0
    @State private var rebatePending = false
    @State private var discount = "0.00"
    @State private var reimbursementStatus = ""
    @State private var showingDiscount = false
    @State private var entryDateChanged = false
    @State private var calculation = AmountCalculation()
    /// 读取入口指定的保存类型；参数：无；返回值：transaction、template 或 recurring，创建过程中不可切换。
    private var saveMode: String { initialMode }
    @State private var presetName = ""
    @State private var showingTemplateName = false
    @FocusState private var editingTemplateName: Bool
    @State private var frequency = "monthly"
    @State private var hasEndDate = false
    @State private var endDate = Date.now
    @State private var counterparty = ""
    @State private var description = ""
    @State private var date = Date.now
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString
    @State private var submittedBody: [String: Any]?
    /// 校验主页面；参数：无；返回值：按副本最终金额检查的结果，不改变金额或算式；模板名称在命名面板校验。
    private var valid: Bool { validationError == nil }
    /// 返回草稿校验反馈；参数：无；返回值：首个错误或 nil；退款资料更正保留原有金额例外，不改变金额规则。
    private var validationError: String? {
        guard counterparty.utf8.count <= 128 && description.utf8.count <= 2000 else { return "交易对象或备注过长" }
        if editingTransaction?.refundParentId != nil { return nil }
        guard let finalAmount = calculation.preview(draft: amount) else { return "请完成金额计算" }
        guard Values.validMoney(finalAmount, positive: true) else { return "金额须大于 0 且不超过一万亿元" }
        guard accountID > 0 else { return "请选择账户" }
        if type == "transfer" {
            guard targetID > 0 && targetID != accountID else { return "请选择不同的转入账户" }
            guard Values.validMoney(rebate), (Decimal(string: rebate) ?? -1) >= 0,
                  Values.validMoney(fee), (Decimal(string: fee) ?? -1) >= 0 else { return "手续费或优惠金额无效" }
        }
        if type == "expense" {
            guard Values.validMoney(discount), (Decimal(string: discount) ?? -1) >= 0,
                  (Decimal(string: discount) ?? 0) < (Decimal(string: finalAmount) ?? 0) else { return "优惠须小于金额" }
        }
        if saveMode == "recurring" && presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入周期记账名称" }
        return nil
    }
    @FocusState private var editingNote: Bool
    @State private var showingDetails = false
    @State private var showingFullNote = false
    @FocusState private var editingFullNote: Bool
    @State private var categoryTemplate: (group: CategoryGroup, item: CategoryTemplate)?
    @State private var saved = false
    /// 返回记账类型的强调色；参数：无；返回值：复用流水与首页的系统动态语义色；无业务副作用。
    private var entryColor: Color { FinanceVisualStyle.color(for: type) }
    /// 返回可记账的账户；参数：无；返回值：未禁用的真实账户，不生成示例账户。
    private var availableAccounts: [FinancialAccount] { store.accounts.filter { $0.selectable != false } }
    /// 构建分类优先的记账页；参数：无；返回值：分类网格、紧凑字段栏和底部金额键盘，真实保存沿用账本接口。
    var body: some View {
        NavigationStack {
            ScrollView {
                if type == "transfer" {
                    VStack(spacing: 18) {
                        accountPicker("转出账户", selection: $accountID)
                        Image(systemName: "arrow.down").foregroundStyle(entryColor)
                        accountPicker("转入账户", selection: $targetID, excluding: accountID)
                    }.padding(24).frame(maxWidth: .infinity)
                } else {
                    TransactionCategoryPicker(type: type, categoryID: $categoryID, categoryTemplate: $categoryTemplate) {
                        editingNote = false; saved = false
                    }
                }
            }
                .background(Color(uiColor: .systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) { entryControls }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // 关闭回调无参数、无返回值；未保存草稿随页面关闭丢弃，提交期间禁止关闭。
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(editingTransaction == nil ? "取消记账" : "取消编辑").disabled(busy)
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("类型", selection: $type) { Text("支出").tag("expense"); Text("收入").tag("income"); Text("转账").tag("transfer") }
                            .pickerStyle(.segmented).frame(maxWidth: 230).disabled(busy)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .interactiveDismissDisabled(busy)
                .disabled(busy)
                .sheet(isPresented: $showingDetails) { detailsForm }
                .fullScreenCover(isPresented: $showingFullNote) { fullNoteEditor }
                .sheet(isPresented: $showingTemplateName) { templateNameForm }
                .sheet(isPresented: $showingDiscount) {
                    DiscountEntryPanel(value: type == "expense" ? $discount : $rebate, originalAmount: type == "expense" ? amount : nil)
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(28)
                        .presentationCompactAdaptation(.sheet)
                }
                .onChange(of: type) { _, value in
                    // 类型切换回调接收新旧类型、返回无；仅清除不匹配分类，保留有效金额与账户。
                    if store.categories.first(where: { $0.id == categoryID })?.type != value { categoryID = 0 }
                    if categoryTemplate?.group.type != value { categoryTemplate = nil }
                    if value != "expense" { reimbursementStatus = "" }
                    saved = false
                }
                .task { populate() }
        }
    }
    /// 返回当前分类名称；参数：无；返回值：待保存模板或已有分类名，未选择时显示选择提示。
    private var selectedCategoryName: String {
        categoryTemplate?.item.name ?? store.categories.first(where: { $0.id == categoryID })?.name ?? "请选择分类"
    }
    /// 解析待保存分类；参数：无；返回值：无；模板先复用同类型同名分类，否则保存目录字段并取得真实 ID，失败抛错且保留草稿供重试。
    private func resolveCategory() async throws {
        guard let choice = categoryTemplate, type != "transfer" else { return }
        // 每次保存先读最新列表，覆盖从分类管理返回或网络超时重试时的新增分类，避免重复创建。
        let latest: [TransactionCategory] = try await store.api.request("/finance/categories")
        store.categories = latest
        let category: TransactionCategory
        if let existing = latest.first(where: { $0.type == choice.group.type && $0.name == choice.item.name }) {
            category = existing
        } else {
            category = try await store.api.request("/finance/categories", method: "POST", body: ["name": choice.item.name, "type": choice.group.type, "color": choice.group.color, "groupKey": choice.group.id, "icon": choice.item.icon])
            store.categories.append(category)
        }
        categoryID = category.id; categoryTemplate = nil
    }
    /// 构建紧凑账户选择入口；参数：title 为入口标题，selection 为账户 ID 草稿绑定，excluding 为转账中需排除的账户；返回值：打开底部搜索面板的按钮，无直接网络写入。
    private func accountPicker(_ title: String, selection: Binding<Int>, excluding: Int = 0) -> some View {
        // 打开回调无参数、无返回值；结束备注输入，让账户面板完整展示。
        TransactionAccountSelector(title: title, selection: selection, excluding: excluding) { editingNote = false }

    }
    /// 构建底部输入区；参数：无；返回值：账户入口、原位日期选择、金额和备注卡片及始终显示的专用键盘；备注使用系统默认输入行为。
    private var entryControls: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    accountPicker(type == "transfer" ? "转出账户" : "选择账户", selection: $accountID)
                    if type == "transfer" { accountPicker("转入账户", selection: $targetID, excluding: accountID) }
                    if saveMode == "recurring" {
                        // 重开回调无参数、返回值无；复用同一周期草稿，不重新预填。
                        Button("周期设置", systemImage: "repeat") { editingNote = false; showingDetails = true }
                            .font(.caption).frame(minHeight: 44)
                    }
                    if type != "income" {
                        // 优惠回调无参数、返回值无；结束备注焦点并编辑现有优惠草稿。
                        Button { editingNote = false; showingDiscount = true } label: {
                            Label("优惠", systemImage: "gift.fill").font(.caption).lineLimit(1)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("设置优惠")
                    }
                    if type == "expense", editingTransaction?.refundParentId == nil, editingTransaction?.rebateParentId == nil {
                        Menu {
                            Picker("报销状态", selection: $reimbursementStatus) {
                                ForEach(ReimbursementStatus.options, id: \.self) { value in Text(ReimbursementStatus.title(value)).tag(value) }
                            }
                        } label: {
                            Label(reimbursementStatus.isEmpty ? "报销" : ReimbursementStatus.title(reimbursementStatus), systemImage: "receipt")
                                .font(.caption).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 44)
                                .foregroundStyle(reimbursementStatus.isEmpty ? Color.secondary : Color.accentColor)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                        }.accessibilityLabel("报销状态，" + ReimbursementStatus.title(reimbursementStatus))
                    }

                }
            }
            VStack(alignment: .leading, spacing: 6) {
                // 金额回调无参数、无返回值；结束文本输入并回到金额键盘，不调用保存。
                Button { editingNote = false } label: {
                    AmountText(value: "¥" + (amount.isEmpty ? "0.00" : amount)).foregroundStyle(entryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("金额，" + (amount.isEmpty ? "0" : amount) + "元")
                if type == "expense", (Decimal(string: discount) ?? 0) > 0 {
                    Text("优惠 " + Values.money(discount) + " · 实付 " + AccountPresentation.money((Decimal(string: amount) ?? 0) - (Decimal(string: discount) ?? 0))).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                SystemDateTimeInput(title: "日期和时间", selection: entryDateSelection)
                    .font(.caption)
                HStack(spacing: 10) {
                    // 备注始终在当前行编辑；焦点直接唤起系统键盘，提交回调无参数、无返回值，仅结束输入并保留草稿。
                    TextField("点击填写备注", text: $description)
                        .font(.subheadline).textFieldStyle(.plain).focused($editingNote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .submitLabel(.done)
                        .onSubmit { editingNote = false }
                        .accessibilityLabel("备注")
                    // 展开回调无参数、无返回值；将同一份备注草稿交给全屏编辑器，不打开交易选项。
                    Button { editingNote = false; showingFullNote = true } label: {
                        Image(systemName: "ellipsis").font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("全屏编辑备注")
                }.foregroundStyle(.secondary)
            }
            // 压缩备注行下方的卡片留白，让较大的备注文字与数字键盘衔接更紧凑。
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            .cardSurface()
            if let error { InlineError(message: error) }
            if saved { Text("已保存").font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            // 数字键盘始终保留，不根据备注焦点、系统键盘通知或应用前后台状态隐藏。
            // 使用当前内容宽度分配四列，避免按窗口宽度计算导致键盘整体收缩或溢出。
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 6) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        // 数字键构造回调接收键名，返回金额编辑按钮；删除占据数字区右下角。
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "删除"], id: \.self) { key in
                            entryKey(key)
                        }
                    }.frame(width: (geometry.size.width - 18) / 4 * 3 + 12)
                    VStack(spacing: 6) {
                        HStack(spacing: 0) { entryKey("+"); entryKey("×") }
                        HStack(spacing: 0) { entryKey("−"); entryKey("÷") }
                        Button { handleKey("完成") } label: {
                            Group {
                                if busy { ProgressView().tint(.white) }
                                else { Text(saveMode == "template" ? "保存\n模板" : saveMode == "recurring" ? "保存\n周期" : "完成").font(.headline) }
                            }.frame(maxWidth: .infinity).frame(height: keypadRowHeight * 2 + AppVisualStyle.keypadSpacing)
                        }.buttonStyle(AmountKeyStyle(accent: entryColor, emphasized: true, foreground: .white)).disabled(busy)
                            .accessibilityLabel(saveMode == "template" ? "保存模板" : saveMode == "recurring" ? "保存周期记账" : "完成")
                    }.frame(width: (geometry.size.width - 18) / 4)
                }.frame(width: geometry.size.width)
            }.frame(height: keypadRowHeight * 4 + AppVisualStyle.keypadSpacing * 3)
        }.padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
    }
    /// 系统日期选择与记账草稿之间的绑定；参数：无；返回值：原位日期时分绑定，仅用户实际修改时标记时间已变更，保留历史流水未提供的时间字段。
    private var entryDateSelection: Binding<Date> {
        // 读取回调无参数、返回当前草稿；写入回调接收所选日期时间、返回无，关闭备注焦点且不提交网络请求。
        Binding(get: { date }, set: { selected in
            guard selected != date else { return }
            editingNote = false
            date = selected
            entryDateChanged = true
        })
    }
    /// 构建金额键；参数：key 为数字、删除或四则运算符；返回值：共享样式且随字号增长的按键，仅修改金额草稿，无网络副作用。
    private func entryKey(_ key: String) -> some View {
        Button { handleKey(key) } label: {
            Group {
                if key == "删除" { Image(systemName: "delete.left.fill").font(.title3) }
                else { Text(key).font(AppVisualStyle.keypadFont) }
            }.frame(maxWidth: .infinity).frame(height: keypadRowHeight)
        }.buttonStyle(AmountKeyStyle()).disabled(busy)
            .accessibilityLabel(key == "删除" ? "删除一位金额" : key)
    }
    /// 处理专用键盘；参数：key 为数字、编辑或保存键；返回值：无；保存先实际求值，失败显示计算错误；模板打开命名面板，其余提交，普通键只编辑草稿。
    private func handleKey(_ key: String) {
        if key == "完成" || key == "保存再记" {
            guard calculation.evaluate(draft: &amount) else { error = calculation.error; return }
        }
        if key == "完成" && saveMode == "template" {
            guard !busy else { return }
            if let validationError { error = validationError; return }
            editingNote = false; error = nil; showingTemplateName = true
        } else if key == "完成" || key == "保存再记" { Task { await save(continueEntry: key == "保存再记") } }
        else { calculation.input(key, draft: &amount); saved = false; error = calculation.error }
    }
    /// 构建共用全屏备注编辑页；参数：无；返回值：交易对象与多行备注输入，共用主页面草稿，完成仅返回，不提交流水。
    private var fullNoteEditor: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("交易对象", text: $counterparty)
                    .padding(16).accessibilityLabel("交易对象")
                if type == "transfer" {
                    TextField("手续费", text: $fee).keyboardType(.decimalPad).padding(.horizontal, 16)
                    if (Decimal(string: rebate) ?? 0) > 0 {
                        Picker("优惠到账账户", selection: $rebateAccountID) {
                            Text("转出账户").tag(0)
                            ForEach(availableAccounts) { account in Text(account.name).tag(account.id) }
                        }.padding(.horizontal, 16)
                        Toggle("优惠待到账", isOn: $rebatePending).padding(16)
                    }
                }
                Divider().padding(.horizontal, 16)
                TextEditor(text: $description)
                    .focused($editingFullNote)
                    .padding(16)
                    .accessibilityLabel("备注")
            }
                .navigationTitle("备注")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        // 完成回调无参数、无返回值；保留已输入备注并关闭全屏编辑，不触发保存请求。
                        Button("完成") {
                            editingFullNote = false
                            showingFullNote = false
                        }
                    }
                }
                // 出现回调无参数、无返回值；聚焦系统多行输入框，直接开始编辑现有备注。
                .onAppear { editingFullNote = true }
        }
    }
    /// 构建模板命名面板；参数：无；返回值：仅输入名称并确认保存的底部面板，失败保留输入，提交期间禁止关闭和重复提交。
    private var templateNameForm: some View {
        NavigationStack {
            Form {
                TextField("请输入模板名", text: $presetName).focused($editingTemplateName)
                if let error { InlineError(message: error) }
            }
            .navigationTitle("添加模板名").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 取消回调无参数、无返回值；仅关闭命名面板，保留主页面和名称草稿。
                    Button("取消") { showingTemplateName = false }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 确认回调无参数、无返回值；名称去除首尾空白后提交模板，错误在当前面板展示。
                    Button("完成") {
                        presetName = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await save() }
                    }.disabled(busy || !valid || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(busy)
            .onAppear { editingTemplateName = true }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
    }
    /// 构建扩展选项；参数：无；返回值：交易对象、转账费用优惠及周期表单，关闭后保留主页面草稿。
    private var detailsForm: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("交易对象", text: $counterparty)
                }
                if type == "transfer" {
                    Section("转账") {
                        TextField("手续费", text: $fee).keyboardType(.decimalPad)
                        TextField("优惠金额", text: $rebate).keyboardType(.decimalPad)
                        if (Decimal(string: rebate) ?? 0) > 0 {
                            Picker("优惠到账账户", selection: $rebateAccountID) {
                                Text("转出账户").tag(0)
                                ForEach(availableAccounts) { account in Text(account.name).tag(account.id) }
                            }
                            Picker("到账状态", selection: $rebatePending) { Text("已到账").tag(false); Text("待到账").tag(true) }
                        }
                    }
                }
                if saveMode == "recurring" {
                    Section("创建周期记账") {
                        TextField("周期记账名称", text: $presetName)
                        Picker("重复周期", selection: $frequency) { Text("每天").tag("daily"); Text("每周").tag("weekly"); Text("每月").tag("monthly"); Text("每年").tag("yearly") }
                        Toggle("截止日期", isOn: $hasEndDate)
                        if hasEndDate { SystemDateTimeInput(title: "截止", selection: $endDate, displayedComponents: .date, range: date...SystemDateTimeInput.allowedRange.upperBound) }
                    }
                }
            }.navigationTitle(saveMode == "recurring" ? "创建周期记账" : "记账选项").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingDetails = false } } }
        }
    }
    /// 首次预填入口数据；参数：无；返回值：无；恢复已有流水、模板、贷款或还款数据，多次出现不覆盖输入。
    private func populate() {
        guard !populated else { return }; populated = true
        // 编辑预填所有可见字段，沿用原流水身份，保存时原子调整余额。
        if let transaction = editingTransaction {
            type = transaction.type; accountID = transaction.accountId; targetID = transaction.targetAccountId ?? 0
            amount = transaction.amount; discount = transaction.discount ?? "0.00"; fee = transaction.fee ?? "0.00"
            // 支出持久化金额为实付，共用新增布局展示优惠前金额，保证下方实付计算正确。
            if transaction.type == "expense", let paid = Decimal(string: transaction.amount), let reduction = Decimal(string: discount), reduction > 0 {
                amount = NSDecimalNumber(decimal: paid + reduction).stringValue
            }
            rebate = transaction.rebate ?? "0.00"; rebateAccountID = transaction.rebateAccountId ?? 0; rebatePending = transaction.rebatePending ?? false
            categoryID = transaction.categoryId ?? 0; counterparty = transaction.counterparty; description = transaction.description
            reimbursementStatus = transaction.reimbursementStatus ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            date = formatter.date(from: transaction.transactionDate + " " + String((transaction.transactionTime ?? "00:00").prefix(5))) ?? date
            return
        }
        showingDetails = initialMode == "recurring"
        accountID = initialAccountID ?? availableAccounts.first(where: { $0.id != initialLoanID && $0.id != initialRepaymentID })?.id ?? 0
        if let initialPreset {
            presetName = initialPreset.name
            let value = initialPreset.transaction
            // 模板表示报销意向，使用模板创建的新支出仍需重新确认是否已经报销。
            reimbursementStatus = initialMode == "transaction" && !(value.reimbursementStatus ?? "").isEmpty ? "pending" : value.reimbursementStatus ?? ""
            type = value.type; accountID = value.accountId; targetID = value.targetAccountId ?? 0; amount = value.amount; discount = value.discount ?? "0.00"; fee = value.fee ?? "0.00"; rebate = value.rebate ?? "0.00"; rebateAccountID = value.rebateAccountId ?? 0; rebatePending = value.rebatePending ?? false; counterparty = value.counterparty; description = value.description; categoryID = value.categoryId ?? 0
        }
        if let initialLoanID { type = "transfer"; targetID = initialLoanID; description = "贷款本金还款" }
        if let initialRepaymentID { type = "transfer"; targetID = initialRepaymentID; description = "信用卡还款"; amount = initialRepaymentAmount ?? "" }
    }
    /// 保存流水或模板；参数：continueEntry 为新增保存后是否继续记账，编辑时忽略；返回值：无；先求值再校验，截图流水通过本机原子事务保存，其他编辑仅 PATCH 变化字段，失败保留输入。
    private func save(continueEntry: Bool = false) async {
        guard !busy else { return }
        // 所有保存入口先实际求值，再校验最终金额；错误保留草稿并在当前页反馈。
        guard calculation.evaluate(draft: &amount) else { error = calculation.error; return }
        if let validationError { error = validationError; return }
        guard saveMode != "template" || !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请输入模板名"; return }
        busy = true; error = nil; saved = false; defer { busy = false }
        do { try await resolveCategory() } catch { self.error = error.localizedDescription; return }
        if let transaction = editingTransaction {
            // 构造与新增一致的财务草稿，仅提交实际变化的白名单字段，保留空值和零值。
            let originalAmount = (Decimal(string: transaction.amount) ?? 0) + (Decimal(string: transaction.discount ?? "0") ?? 0)
            let current: [String: Any] = ["reimbursementStatus": type == "expense" ? reimbursementStatus : "", "type": type, "accountId": accountID, "targetAccountId": type == "transfer" ? targetID as Any : NSNull(), "amount": amount, "discount": type == "expense" ? discount : "0.00", "fee": type == "transfer" ? fee : "0.00", "rebate": type == "transfer" ? rebate : "0.00", "rebateAccountId": type == "transfer" && (Decimal(string: rebate) ?? 0) > 0 ? (rebateAccountID == 0 ? accountID : rebateAccountID) as Any : NSNull(), "rebatePending": type == "transfer" && (Decimal(string: rebate) ?? 0) > 0 && rebatePending, "categoryId": type != "transfer" && categoryID > 0 ? categoryID as Any : NSNull(), "counterparty": counterparty, "description": description, "transactionDate": entryDateChanged ? Values.day(date) : transaction.transactionDate, "transactionTime": entryDateChanged ? Values.time(date) : transaction.transactionTime ?? ""]
            if let jobID = transaction.screenshotJobID {
                do {
                    guard let finance = store.finance else { throw APIError(status: 0, message: "本机账本不可用") }
                    try finance.saveScreenshotTransaction(jobID, body: current)
                    dismiss()
                    await store.refreshAfterMutation(.finance)
                } catch { self.error = error.localizedDescription }
                return
            }
            let original: [String: Any] = ["reimbursementStatus": transaction.reimbursementStatus ?? "", "type": transaction.type, "accountId": transaction.accountId, "targetAccountId": transaction.targetAccountId as Any? ?? NSNull(), "amount": NSDecimalNumber(decimal: originalAmount).stringValue, "discount": transaction.discount ?? "0.00", "fee": transaction.fee ?? "0.00", "rebate": transaction.rebate ?? "0.00", "rebateAccountId": transaction.rebateAccountId as Any? ?? NSNull(), "rebatePending": transaction.rebatePending ?? false, "categoryId": transaction.categoryId as Any? ?? NSNull(), "counterparty": transaction.counterparty, "description": transaction.description, "transactionDate": transaction.transactionDate, "transactionTime": transaction.transactionTime ?? ""]
            var fields: [String: Any] = [:]
            for (key, value) in current {
                if ["amount", "discount", "fee", "rebate"].contains(key) {
                    if Decimal(string: value as? String ?? "") != Decimal(string: original[key] as? String ?? "") { fields[key] = value }
                } else if !NSDictionary(dictionary: [key: value]).isEqual(to: [key: original[key]!]) { fields[key] = value }
            }
            do {
                if !fields.isEmpty { try await store.api.mutate("/finance/transactions/\(transaction.id)", method: "PATCH", body: fields) }
                dismiss()
                await store.refreshAfterMutation(.finance)
            } catch { self.error = error.localizedDescription }
            return
        }
        var body: [String: Any] = ["type": type, "accountId": accountID, "amount": amount, "transactionDate": Values.day(date), "transactionTime": Values.time(date), "counterparty": counterparty, "description": description, "fee": type == "transfer" ? fee : "0.00"]
        if type == "expense" {
            body["discount"] = discount
            body["reimbursementStatus"] = reimbursementStatus
        }
        if type == "transfer" {
            body["targetAccountId"] = targetID
            body["rebate"] = rebate
            if (Decimal(string: rebate) ?? 0) > 0 {
                body["rebateAccountId"] = rebateAccountID == 0 ? accountID : rebateAccountID
                body["rebatePending"] = rebatePending
            }
        } else if categoryID > 0 { body["categoryId"] = categoryID }
        if saveMode != "transaction" {
            body = ["transaction": body, "name": presetName, "frequency": saveMode == "recurring" ? frequency : "", "startDate": Values.day(date), "endDate": saveMode == "recurring" && hasEndDate ? Values.day(endDate) : ""]
        }
        if let submittedBody, !NSDictionary(dictionary: submittedBody).isEqual(to: body) { requestID = UUID().uuidString }
        submittedBody = body; body[saveMode == "transaction" ? "requestId" : "key"] = requestID
        do {
            // 编辑模板仅 PATCH 当前记录的名称和交易字段，不创建流水或复制模板。
            if saveMode == "template", let initialPreset {
                try await store.api.mutate("/finance/presets/\(initialPreset.id)", method: "PATCH", body: ["name": presetName, "transaction": body["transaction"]!])
            } else {
                try await store.api.mutate(saveMode == "transaction" ? "/finance/transactions" : "/finance/presets", body: body)
            }
            // 主写入成功即完成本笔，避免后续刷新失败被当作保存失败而重复记账。
            if continueEntry {
                amount = ""; description = ""; counterparty = ""; discount = "0.00"; fee = "0.00"; rebate = "0.00"; rebateAccountID = 0; rebatePending = false; reimbursementStatus = ""
                submittedBody = nil; requestID = UUID().uuidString; saved = true
            } else { dismiss() }
            await store.refreshAfterMutation(.finance)
        }
        catch { self.error = error.localizedDescription }
    }
}



/// 独立管理入口的类型，共享接口但按是否设置周期分开显示和创建。
enum FinancePresetKind: String {
    case template
    case recurring

    /// 返回管理页标题；参数：无；返回值：对应类型的中文标题。
    var title: String { self == .template ? "记账模板" : "周期记账" }
    /// 返回创建操作标题；参数：无；返回值：对应类型的中文创建文案。
    var createTitle: String { self == .template ? "创建模板" : "创建周期记账" }
}

struct FinancePresetsView: View {
    let kind: FinancePresetKind
    /// true 表示从记账菜单进入，选中模板创建流水；false 表示管理入口，选中后修改模板。
    var useForTransaction = false
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var tagFontSize = 10.0
    /// 返回主文字颜色；参数：无；返回值：深色模式纯白、浅色模式纯黑，避免分组标题继承次要文字灰色。
    private var primaryTextColor: Color { colorScheme == .dark ? .white : .black }
    @Environment(AppStore.self) private var store
    @State private var rows: [FinancePreset] = []
    @State private var collapsedTypes: Set<String> = []
    @State private var selected: FinancePreset?
    @State private var creating = false
    @State private var deleting: FinancePreset?
    @State private var busy = false
    @State private var error: String?
    /// 展示指定类型的独立管理页；参数：无；返回值：模板或周期记账列表及对应创建入口，删除须确认。
    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if kind == .template {
                templateSections
            } else {
            ForEach(rows) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.headline)
                    Text(Values.money(item.transaction.amount) + " · " + frequencyName(item.frequency))
                    if !item.frequency.isEmpty { Text(item.enabled ? "下期：" + item.nextDate : "已暂停 / 结束").font(.caption) }
                    if !item.lastError.isEmpty { InlineError(message: item.lastError) }
                    HStack {
                        if item.frequency.isEmpty { Button("使用模板") { selected = item } }
                        else { Button(item.enabled ? "暂停" : "恢复") { Task { await toggle(item) } } }
                        Spacer()
                        Button("删除", role: .destructive) { deleting = item }
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 4)
            }
            }
            if rows.isEmpty { Text(kind == .template ? "暂无记账模板" : "暂无周期记账").foregroundStyle(.secondary) }
        }.listStyle(.insetGrouped).disabled(busy).navigationTitle(kind == .template ? "选择模板" : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(kind.createTitle, systemImage: "plus") { creating = true } }
            .task { await load() }.refreshable { await load() }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { TransactionEditor(initialMode: kind.rawValue) }
            .sheet(item: $selected, onDismiss: { Task { await load() } }) { item in TransactionEditor(initialPreset: item, initialMode: useForTransaction ? "transaction" : "template") }
            .confirmationDialog("删除后保留已生成流水", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                if let item = deleting { Button("删除", role: .destructive) { Task { await remove(item) } } }
            }
    }
    /// 构建按收支类型分组的模板卡片；参数：无；返回值：可折叠分组，点击行按入口用途记账或编辑模板，左滑删除。
    private var templateSections: some View {
        // 分组回调接收类型代码，返回该类型的模板列表；空分组不展示。
        ForEach(["expense", "income", "transfer"], id: \.self) { type in
            let items = rows.filter { $0.transaction.type == type }
            if !items.isEmpty {
                Section {
                    if !collapsedTypes.contains(type) {
                        ForEach(items) { item in
                            // 点击回调无参数、无返回值；预填当前模板进入记账或模板编辑，只有用户确认保存后才写入。
                            Button { selected = item } label: { templateRow(item) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 16))
                                .swipeActions { Button("删除", role: .destructive) { deleting = item } }
                        }
                    }
                } header: {
                    // 折叠回调无参数、无返回值；仅切换当前类型的可见性。
                    Button {
                        if collapsedTypes.contains(type) { collapsedTypes.remove(type) } else { collapsedTypes.insert(type) }
                    } label: {
                        HStack {
                            Text(type == "expense" ? "支出模板" : type == "income" ? "收入模板" : "转账模板")
                            Spacer()
                            Image(systemName: collapsedTypes.contains(type) ? "chevron.right" : "chevron.down").font(.caption)
                        }.font(.subheadline).foregroundStyle(primaryTextColor)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).textCase(nil)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
    }
    /// 绘制模板摘要；参数：item 为已有模板；返回值：分类圆形图标、名称、真实信息标签与右侧金额，不补造账本字段。
    private func templateRow(_ item: FinancePreset) -> some View {
        let transaction = item.transaction
        let category = store.categories.first { $0.id == transaction.categoryId }
        let account = store.accounts.first { $0.id == transaction.accountId }?.name ?? "已删除账户"
        let color: Color = transaction.type == "expense" ? Color(red: 0.96, green: 0.37, blue: 0.31) : transaction.type == "income" ? .teal : .orange
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: transaction.type == "transfer" ? "arrow.left.arrow.right" : category.map { CategoryCatalog.icon(for: $0) } ?? "creditcard")
                .font(.system(size: 20)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(primaryTextColor)
                if let category { templateTag("分类: " + category.name) }
                templateTag("账户: " + account)
                if let target = transaction.targetAccountId {
                    templateTag("转入: " + (store.accounts.first { $0.id == target }?.name ?? "已删除账户"))
                }
                if !transaction.description.isEmpty { templateTag("备注: " + transaction.description) }
                if let discount = transaction.discount, (Decimal(string: discount) ?? 0) > 0 { templateTag("优惠: " + discount) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text(Values.money(transaction.amount)).font(.subheadline).foregroundStyle(primaryTextColor).fixedSize()
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(maxHeight: .infinity)
        }.fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
    }
    /// 绘制紧凑信息标签；参数：text 为非空展示文字；返回值：灰色圆角标签，长文字单行省略。
    private func templateTag(_ text: String) -> some View {
        Text(text).font(.system(size: tagFontSize)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
    /// 获取周期名称；参数 value 为服务器周期代码；返回值中文名称，无副作用。
    private func frequencyName(_ value: String) -> String { ["daily": "每天", "weekly": "每周", "monthly": "每月", "yearly": "每年"][value] ?? "模板" }
    /// 刷新当前类型的个人记录；参数：无；返回值：无；按 frequency 是否为空区分模板和周期记账，错误显示在当前页。
    private func load() async {
        do {
            let presets: [FinancePreset] = try await store.api.request("/finance/presets")
            // 筛选回调接收个人记录、返回是否属于当前入口；旧数据沿用服务端周期字段，无须迁移。
            rows = presets.filter { kind == .template ? $0.frequency.isEmpty : !$0.frequency.isEmpty }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// 暂停或恢复计划；参数 item 为当前用户计划；返回值无，恢复时补齐到期草稿。
    private func toggle(_ item: FinancePreset) async {
        busy = true; defer { busy = false }
        do { try await store.api.mutate("/finance/presets/\(item.id)", method: "PATCH", body: ["enabled": !item.enabled]); try await store.api.mutate("/finance/recurring/materialize", body: [:]); await load() } catch { self.error = error.localizedDescription }
    }
    /// 删除已确认的模板或计划；参数 item 为记录；返回值无，历史流水不变。
    private func remove(_ item: FinancePreset) async {
        busy = true; defer { busy = false }
        do { try await store.api.mutate("/finance/presets/\(item.id)", method: "DELETE"); await load() } catch { self.error = error.localizedDescription }
    }
}
