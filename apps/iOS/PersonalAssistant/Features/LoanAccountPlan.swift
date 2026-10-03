import SwiftUI

/// 完整贷款计划；accountID 为账户主键，左滑可修正单期金额或调整后续利率，不修改余额或还款期数。
struct LoanAccountPlan: View {
    @Environment(AppStore.self) private var store
    let accountID: Int
    @State private var plan: LoanPlanSummary?
    @State private var loading = false
    @State private var error: String?
    @State private var editing = false
    @State private var adjustment: LoanAdjustmentSelection?
    @State private var filter = "all"
    private var account: FinancialAccount? { store.accounts.first { $0.id == accountID } }
    /// 筛选可见期次；参数：无；返回值：已还按期次倒序，全部与待还保持原顺序，不修改原始计划。
    private var rows: [LoanPaymentSummary] {
        let paid = plan?.paidPeriods ?? account?.loanPaidPeriods ?? 0
        let filtered = (plan?.schedule ?? []).filter { filter == "all" || (filter == "paid" ? $0.period <= paid : $0.period > paid) }
        return filter == "paid" ? filtered.sorted { $0.period > $1.period } : filtered
    }
    var body: some View {
        // 原生侧滑操作必须附着在独立 List 行；概览仍整张作为一行，保留卡片排版。
        List {
            Group {
                if let account, let schedule = plan?.schedule {
                    planSummary(account, schedule: schedule).padding(.top, 18)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("还款明细").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(rows.count) 期").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4)
                        Picker("期次筛选", selection: $filter) {
                            Text("全部").tag("all"); Text("已还").tag("paid"); Text("待还").tag("remaining")
                        }.pickerStyle(.segmented)
                    }.padding(.top, 10)
                    if rows.isEmpty {
                        LoanCard { Text("暂无匹配期次").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    }
                    ForEach(rows, id: \.period) { row in
                        paymentCard(row, account: account)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if LoanDetailPresentation.canAdjust(row) {
                                    // 侧滑按钮回调无参数和返回值；点击后只打开对应期次草稿，不自动保存。
                                    Button("利率", systemImage: "percent") { openAdjustment(row, kind: .rate) }.tint(.blue)
                                    Button("金额", systemImage: "yensign") { openAdjustment(row, kind: .payment) }.tint(.accentColor)
                                }
                            }
                    }
                } else if !loading && error == nil {
                    LoanCard {
                        VStack(spacing: 14) {
                            Image(systemName: "calendar.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                            Text("尚未设置贷款计划").font(.headline)
                            if account != nil { Button("补充贷款资料") { editing = true }.buttonStyle(.borderedProminent) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                if loading { ProgressView("加载计划…").frame(maxWidth: .infinity).padding(.vertical, 24) }
                if let error {
                    LoanCard { VStack(alignment: .leading, spacing: 12) { InlineError(message: error); Button("重试") { Task { await load() } } } }
                }
            }.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }.listStyle(.plain).listRowSpacing(14).scrollContentBackground(.hidden)
            .contentMargins(.bottom, 32, for: .scrollContent)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("贷款计划").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("修改计划", systemImage: "square.and.pencil") { editing = true }.disabled(account == nil || loading) }
            .task {
                await load()
                #if DEBUG
                if store.isPreview && ProcessInfo.processInfo.arguments.contains("--loan-adjustment"), let plan,
                   let period = LoanDetailPresentation.adjustmentPeriod(plan, today: Values.day()) {
                    adjustment = LoanAdjustmentSelection(period: period, kind: .rate)
                }
                #endif
            }
            .refreshable { await refresh() }
            .sheet(isPresented: $editing, onDismiss: { Task { await refresh() } }) { if let account { AccountEditor(account: account) } }
            .sheet(item: $adjustment, onDismiss: { Task { await refresh() } }) { selection in
                if let account, let plan { LoanAdjustmentEditor(account: account, plan: plan, fromPeriod: selection.period, kind: selection.kind) }
            }
    }

    /// 构建计划概览；参数：account 为当前合同，schedule 为完整计划；返回值：本金主金额、六项分组统计及进度，无业务副作用。
    private func planSummary(_ account: FinancialAccount, schedule: [LoanPaymentSummary]) -> some View {
        let totals = LoanPlanTotals(schedule: schedule, paidPeriods: plan?.paidPeriods ?? account.loanPaidPeriods ?? 0)
        return LoanCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("贷款本金").font(.caption).foregroundStyle(.secondary)
                        Text(Values.money(account.loanPrincipal ?? "0")).font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 8)
                    Text("\(plan?.next == nil ? "末期" : "下期")年利率 \(plan?.next?.annualRate ?? schedule.last?.annualRate ?? account.loanAnnualRate ?? "0")%")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                }
                HStack(alignment: .top, spacing: 12) {
                    summaryColumn("已还", total: totals.paidTotal, principal: totals.paidPrincipal, interest: totals.paidInterest, highlighted: true)
                    summaryColumn("计划剩余", total: totals.remainingTotal, principal: totals.remainingPrincipal, interest: totals.remainingInterest, highlighted: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("本金进度").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(totals.progress.formatted(.percent.precision(.fractionLength(2)))).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    ProgressView(value: totals.progress).tint(.accentColor)
                    Text("按已还期数计算").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 打开所滑期次的独立表单；参数：row 为期初有本金的分期，kind 为金额或利率；返回值：无，原子设置期次与操作，不触发写入。
    private func openAdjustment(_ row: LoanPaymentSummary, kind: LoanAdjustmentKind) {
        guard LoanDetailPresentation.canAdjust(row) else { return }
        adjustment = LoanAdjustmentSelection(period: row.period, kind: kind)
    }

    /// 构建还款状态统计列；参数：title 为状态，total 为含单期修正的应还合计，principal/interest 为原计划本息，highlighted 控制主色；返回值：分项及必要的修正差额，无副作用。
    private func summaryColumn(_ title: String, total: Decimal, principal: Decimal, interest: Decimal, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            metric(total == principal + interest ? "本息" : "合计", total)
            metric("本金", principal)
            metric("利息", interest)
            if total != principal + interest { metric("金额修正", total - principal - interest) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(highlighted ? Color.accentColor.opacity(0.06) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 绘制统计金额；参数：title 为指标名，value 为精确金额；返回值：不重复嵌套卡片的标签与金额。
    private func metric(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(AccountPresentation.money(value)).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    /// 绘制单期还款卡片；参数：row 为计划期次，account 为合同；返回值：日期、状态、逐期利率和本息拆分，侧滑入口由外层列表行提供。
    private func paymentCard(_ row: LoanPaymentSummary, account: FinancialAccount) -> some View {
        let paid = row.period <= (plan?.paidPeriods ?? account.loanPaidPeriods ?? 0)
        return LoanCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("第 \(row.period) 期").font(.subheadline.weight(.semibold))
                            Text(paid ? "已还" : (Decimal(string: row.payment) ?? 0) == 0 ? "无需还款" : "待还").font(.caption2.weight(.medium))
                                .foregroundStyle(paid ? Color.secondary : Color.accentColor)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(paid ? Color(uiColor: .tertiarySystemGroupedBackground) : Color.accentColor.opacity(0.08), in: Capsule())
                        }
                        Text(row.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(Values.money(row.payment)).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                // 与调整预览统一为单行，空间不足时整体缩放，保持三项数值完整。
                Text("本金 \(Values.money(row.principal))  利息 \(Values.money(row.interest))  年利率 \(row.annualRate ?? account.loanAnnualRate ?? "0")%")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65)
                if row.customPayment == true { Text("自定义月供").font(.caption2).foregroundStyle(.secondary) }
                if let correction = LoanDetailPresentation.paymentCorrection(row) {
                    Text("本期金额修正 \(correction)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    /// 加载完整计划；参数：无；返回值：无；会话切换或取消时丢弃响应，失败显示错误，不伪造数据。
    private func load() async {
        guard !loading else { return }
        guard let account else { plan = nil; return }
        let draft = LoanAccountDraft(account: account)
        guard draft.enabled else { plan = nil; return }
        loading = true; error = nil; plan = nil; defer { loading = false }
        let generation = store.sessionID
        do {
            let result: LoanPlanSummary = try await store.api.request("/finance/accounts/\(accountID)/loan-plan")
            guard generation == store.sessionID, !Task.isCancelled else { return }
            plan = result
        } catch { if generation == store.sessionID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    /// 刷新合同与计划；参数：无；返回值：无；合同刷新失败保留错误，不使用过期资料试算。
    private func refresh() async {
        do { try await store.loadFinance(); await load() }
        catch { self.error = error.localizedDescription }
    }
}
