import SwiftUI

/// 贷款详情；accountID 为当前登录用户的贷款 ID，账户资料始终从共享存储取最新值。
struct LoanAccountDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let accountID: Int
    @State private var editing = false
    @State private var recording = false
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false
    @State private var months: [LoanMonth] = []
    @State private var collapsed: Set<String> = []
    @State private var confirming = false
    @State private var impact: LoanDeleteImpact?
    private var account: FinancialAccount? { store.accounts.first { $0.id == accountID } }

    /// 返回全部非空月份；参数：无；返回值：按月份倒序的流水分组。
    private var visibleMonths: [LoanMonth] { months.filter { !$0.rows.isEmpty } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let account {
                    summaryCard(account)
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("账户流水").font(.subheadline.weight(.semibold))
                            Spacer()
                        }.padding(.horizontal, 4)
                        if visibleMonths.isEmpty && !loading && error == nil && loaded {
                            LoanCard {
                                VStack(spacing: 10) {
                                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                                    Text("暂无账户流水").font(.subheadline).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                        }
                        ForEach(visibleMonths) { month in monthCard(month) }
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).accessibilityLabel("加载流水")
                        }
                    }
                } else {
                    ContentUnavailableView("账户已不可用", systemImage: "wallet.bifold")
                }
                if let error {
                    LoanCard {
                        VStack(alignment: .leading, spacing: 12) {
                            InlineError(message: error)
                            Button("重试") { Task { await loadTransactions() } }
                        }
                    }
                }
            }.frame(maxWidth: 680).padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("账户详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("记本金还款", systemImage: "plus") { recording = true }.disabled(account == nil || account?.selectable == false || busy) }
            .task {
                // 首次自动读取全部历史分页；无参数、返回值，无需逐月点击，取消后允许重新进入继续加载。
                if !loaded { await loadTransactions() }
            }
            .refreshable { await refresh() }
            .sheet(isPresented: $editing, onDismiss: { Task { await refresh() } }) { if let account { AccountEditor(account: account) } }
            .sheet(isPresented: $recording, onDismiss: { Task { await refresh() } }) { TransactionEditor(initialLoanID: accountID) }
            .alert("删除贷款账户？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { Task { await delete() } }
            } message: { Text("删除后退出资产统计，保留 \(impact?.transactions ?? 0) 笔流水和 \(impact?.snapshots ?? 0) 条余额快照。") }
    }
    /// 绘制紧凑贷款总览；参数：account 为最新账户；返回值：应还主金额、还款日、双列本金及计划入口，避免系统列表拆分每段内容。
    private func summaryCard(_ account: FinancialAccount) -> some View {
        LoanCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    AccountProviderIcon(provider: .resolve(type: account.accountType, institution: account.institution), size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).font(.headline).foregroundStyle(.primary)
                        if let lender = account.loanLender, !lender.isEmpty {
                            Text(lender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("修改账户", systemImage: "square.and.pencil") { editing = true }
                        NavigationLink("贷款计划") { LoanAccountPlan(accountID: accountID) }
                        Button(account.selectable == false ? "启用记账选择" : "停用记账选择") { Task { await toggleSelection(account) } }
                        Button("删除账户", role: .destructive) { Task { await prepareDelete() } }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                    }.tint(.primary).accessibilityLabel("更多账户操作").disabled(busy)
                }
                if let next = account.loanPlan?.next {
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack { Text("第 \(next.period) 期 · 计划应还"); Spacer(minLength: 8); Label(next.date, systemImage: "calendar") }
                            VStack(alignment: .leading, spacing: 5) { Text("第 \(next.period) 期 · 计划应还"); Label(next.date, systemImage: "calendar") }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(Values.money(next.payment)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
                    }
                } else {
                    Label(account.loanPlan == nil ? "待设置还款计划" : "计划已结清", systemImage: account.loanPlan == nil ? "calendar.badge.plus" : "checkmark.circle")
                        .font(.title3.weight(.semibold)).padding(.vertical, 4)
                }
                // 本金与本息统计均取同一已还期数对应的计划摘要，避免与未补录流水的账本余额混用。
                HStack(alignment: .top, spacing: 16) {
                    principalMetric("剩余本金", value: account.loanPlan.map { Values.money($0.remainingPrincipal) } ?? AccountPresentation.money(-(Decimal(string: account.balance) ?? 0)))
                    if let principal = account.loanPrincipal, (Decimal(string: principal) ?? 0) > 0 {
                        principalMetric("贷款本金", value: Values.money(principal))
                    }
                }
                if let plan = account.loanPlan, let remaining = plan.remainingTotal, let paid = plan.paidTotal {
                    HStack(alignment: .top, spacing: 16) {
                        principalMetric("剩余欠款（含利息）", value: Values.money(remaining))
                        principalMetric("已还本息", value: Values.money(paid))
                    }
                }
                Divider().overlay(Color.primary.opacity(0.03))
                NavigationLink { LoanAccountPlan(accountID: accountID) } label: {
                    VStack(spacing: 10) {
                        HStack {
                            Text("贷款计划").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Spacer()
                            Text(account.loanPlan == nil ? "待补充" : "已还 \(account.loanPaidPeriods ?? 0) / \(account.loanPeriods ?? 0) 期")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        if let periods = account.loanPeriods, periods > 0 {
                            ProgressView(value: min(1, max(0, Double(account.loanPaidPeriods ?? 0) / Double(periods))))
                                .tint(.accentColor).accessibilityLabel("计划期数进度")
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !account.notes.isEmpty { Text(account.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
    }

    /// 绘制本金指标；参数：title 为中文标签，value 为已格式化金额；返回值：等宽、自适应字体的左对齐指标。
    private func principalMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 格式化自然月标题；参数：raw 为 YYYY-MM-DD 月首；返回值：中文年月，不重复显示整月起止日。
    private func monthTitle(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return raw }
        return "\(parts[0])年\(month)月"
    }

    /// 绘制可折叠月份卡片；参数：month 为完整加载的非空月份；返回值：标题与流水统一容器，只有记录之间显示分隔线。
    private func monthCard(_ month: LoanMonth) -> some View {
        LoanCard {
            LazyVStack(spacing: 16) {
                // 折叠回调无输入和返回值；只修改显示状态，已加载数据保留。
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if collapsed.contains(month.id) { collapsed.remove(month.id) } else { collapsed.insert(month.id) }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(monthTitle(month.id)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(month.rows.count) 笔流水").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            if month.inflow > 0 { Text("流入 \(AccountPresentation.money(month.inflow))").foregroundStyle(.teal) }
                            if month.outflow > 0 { Text("流出 \(AccountPresentation.money(month.outflow))").foregroundStyle(.secondary) }
                        }.font(.caption).monospacedDigit()
                        Image(systemName: collapsed.contains(month.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(monthTitle(month.id))，\(collapsed.contains(month.id) ? "展开" : "收起")流水")
                if !collapsed.contains(month.id) {
                    ForEach(month.rows) { row in
                        Divider()
                        transactionRow(row)
                    }
                }
            }
        }
    }

    /// 展示本账户视角的真实流水；参数：row 为已入账流水；返回值：对齐的金额、日期、账户方向及备注，不推造历史余额或时间。
    private func transactionRow(_ row: FinanceTransaction) -> some View {
        let change = LoanDetailPresentation.change(row, accountID: accountID)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.type == "transfer" ? "arrow.left.arrow.right" : change > 0 ? "arrow.down.left" : "arrow.up.right")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.type == "transfer" ? (change > 0 ? "本金转入" : "转出") : row.type == "income" ? "流入" : "流出").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text((change > 0 ? "+" : "−") + Values.money(row.amount)).font(.subheadline.weight(.medium)).monospacedDigit().fixedSize()
                }
                Text(row.transactionDate).font(.caption).foregroundStyle(.secondary)
                if row.type == "transfer" { Text("\(accountName(row.accountId)) → \(accountName(row.targetAccountId))").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !row.description.isEmpty { Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }
    /// 解析关联账户名；参数：id 为可选主键；返回值：现名或保留 ID 的历史兜底，不冒充已删除账户资料。
    private func accountName(_ id: Int?) -> String { store.accounts.first { $0.id == id }?.name ?? "账户 #\(id ?? 0)" }
    /// 自动加载账户全部历史；参数：无；返回值：无，完整读取后统一发布月份汇总，失败保留旧数据，取消或跨会话丢弃结果。
    private func loadTransactions() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let generation = store.sessionID
        do {
            // 分页回调输入偏移量，返回至多 500 条已入账流水；日期不设限，包含转入和转出。
            let rows = try await LoanDetailPresentation.allTransactions { offset in
                let query = [URLQueryItem(name: "accountId", value: String(accountID)), URLQueryItem(name: "status", value: "posted"), URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "offset", value: String(offset))]
                let page: [FinanceTransaction] = try await store.api.request("/finance/transactions", query: query)
                guard generation == store.sessionID else { throw CancellationError() }
                return page
            }
            guard generation == store.sessionID, !Task.isCancelled else { return }
            months = LoanDetailPresentation.transactionMonths(rows, accountID: accountID)
            loaded = true; error = nil
        } catch { if generation == store.sessionID && !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    /// 刷新资料及全部流水；参数：无；返回值：无，失败保留旧数据，跨会话或取消不显示错误。
    private func refresh() async {
        let generation = store.sessionID
        do {
            try await store.loadFinance()
            guard generation == store.sessionID, !Task.isCancelled else { return }
            await loadTransactions()
        } catch { if generation == store.sessionID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    /// 切换记账可选状态；参数：account 为最新账户；返回值：无；只 PATCH selectable，不改变资产统计。
    private func toggleSelection(_ account: FinancialAccount) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await store.api.mutate("/finance/accounts/\(accountID)", method: "PATCH", body: ["selectable": account.selectable == false]); try await store.loadFinance() }
        catch { self.error = error.localizedDescription }
    }
    /// 查询删除影响；参数：无；返回值：无；待确认流水阻止删除，成功才展示确认。
    private func prepareDelete() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let value: LoanDeleteImpact = try await store.api.request("/finance/accounts/\(accountID)/impact")
            guard value.pending == 0 else { error = "请先处理该账户的待确认流水。"; return }
            impact = value; confirming = true
        } catch { self.error = error.localizedDescription }
    }
    /// 执行用户确认的软删除；参数：无；返回值：无；成功退出详情并刷新资产。
    private func delete() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await store.api.mutate("/finance/accounts/\(accountID)", method: "DELETE"); store.accounts.removeAll { $0.id == accountID }; dismiss(); await store.refreshAfterMutation(.finance) }
        catch { self.error = error.localizedDescription }
    }
}
private struct LoanDeleteImpact: Decodable { let transactions: Int; let snapshots: Int; let pending: Int }
