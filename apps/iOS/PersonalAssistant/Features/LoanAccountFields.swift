import SwiftUI

/// 贷款表单草稿；计划未启用的历史账户不主动覆盖任何贷款字段。
struct LoanAccountDraft: Equatable {
    var enabled = true
    var principal = ""
    var annualRate = ""
    var method = "annuity"
    var periods = 12
    var paidPeriods = 0
    var firstPayment = Date()
    var lender = ""
    var receivingAccountID = 0

    /// 从历史账户初始化草稿；参数：account 为可选已有账户；返回值：草稿；缺少计划的旧账户默认关闭补填。
    init(account: FinancialAccount? = nil) {
        guard let account else { return }
        enabled = (Decimal(string: account.loanPrincipal ?? "0") ?? 0) > 0
        principal = enabled ? account.loanPrincipal ?? "" : ""
        annualRate = account.loanAnnualRate ?? ""
        method = (account.loanMethod ?? "").isEmpty ? "annuity" : account.loanMethod!
        periods = max(1, account.loanPeriods ?? 12)
        paidPeriods = account.loanPaidPeriods ?? 0
        firstPayment = (account.loanFirstPaymentDate ?? "").isEmpty ? Date() : Values.date(account.loanFirstPaymentDate!)
        lender = account.loanLender ?? ""; receivingAccountID = account.loanReceivingAccountId ?? 0
    }
    /// 生成保存和试算字段；参数：无；返回值：显式零值可保留的字典，未启用计划返回空字典。
    var fields: [String: Any] {
        guard enabled else { return [:] }
        return ["loanPrincipal": principal, "loanAnnualRate": annualRate, "loanMethod": method, "loanPeriods": periods, "loanPaidPeriods": paidPeriods, "loanFirstPaymentDate": Values.day(firstPayment), "loanLender": lender, "loanReceivingAccountId": receivingAccountID]
    }
    /// 校验本地必填条件；参数：无；返回值：可提交状态；后端继续验证利率精度、日期及关联权限。
    var valid: Bool {
        !enabled || (Values.validMoney(principal, positive: true) && annualRate.range(of: #"^(0|[1-9][0-9]{0,2})(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil && (Decimal(string: annualRate) ?? 101) <= 100 && (1...480).contains(periods) && (0...periods).contains(paidPeriods) && lender.utf8.count <= 128)
    }
}

/// 贷款专属字段分组；draft 为双向草稿，accountID 为编辑目标（新建为 nil）；仅试算发请求，不自动入账。
struct LoanAccountFields: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: LoanAccountDraft
    let accountID: Int?
    @State private var preview: LoanPlanSummary?
    @State private var error: String?
    @State private var calculating = false
    private var contractLocked: Bool {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else { return false }
        return account.loanPlanLocked == true || (account.loanPaidPeriods ?? 0) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if accountID != nil && !draft.enabled {
                Button("补充还款计划") { draft.enabled = true }.frame(minHeight: 54)
            } else {
                LabeledContent("贷款本金") { TextField("必填", text: $draft.principal).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel("贷款本金").disabled(contractLocked) }.frame(minHeight: 54)
                Divider()
                LabeledContent("贷款机构") { TextField("选填", text: $draft.lender).multilineTextAlignment(.trailing).accessibilityLabel("贷款机构") }.frame(minHeight: 54)
                Divider()
                LabeledContent("初始年利率") { HStack { TextField("必填", text: $draft.annualRate).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel("初始年利率，百分数").disabled(contractLocked); Text("%") } }.frame(minHeight: 54)
                Divider()
                LabeledContent("还款方式") {
                    Picker("还款方式", selection: $draft.method) { Text("等额本息").tag("annuity"); Text("等额本金").tag("equal_principal"); Text("先息后本").tag("interest_only") }.labelsHidden().pickerStyle(.menu).accessibilityLabel("还款方式").disabled(contractLocked)
                }.frame(minHeight: 54)
                Divider()
                LabeledContent("贷款期数") { HStack { TextField("1–480", value: $draft.periods, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityLabel("贷款期数，1 至 480").disabled(contractLocked); Text("期") } }.frame(minHeight: 54)
                Divider()
                LabeledContent("已还期数") { HStack { TextField("0", value: $draft.paidPeriods, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityLabel("已还期数"); Text("期") } }.frame(minHeight: 54)
                if draft.paidPeriods > draft.periods { InlineError(message: "已还期数不能超过贷款期数。") }
                Divider()
                DatePicker("首次还款日", selection: $draft.firstPayment, displayedComponents: .date).disabled(contractLocked).frame(minHeight: 54)
                Divider()
                LabeledContent("关联收款账户") {
                    Picker("关联收款账户", selection: $draft.receivingAccountID) {
                        Text("不关联").tag(0)
                        // 选项回调输入有效账户、输出选择行；仅排除本账户，保留历史关联回显。
                        ForEach(store.accounts.filter { $0.id != accountID }) { Text($0.name).tag($0.id) }
                        if draft.receivingAccountID != 0 && !store.accounts.contains(where: { $0.id == draft.receivingAccountID }) { Text("账户已删除").tag(draft.receivingAccountID) }
                    }.labelsHidden().pickerStyle(.menu).accessibilityLabel("关联收款账户")
                }.frame(minHeight: 54)
                Text("仅关联，不自动入账").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                Divider().padding(.top, 8)
                if contractLocked, let accountID {
                    NavigationLink("查看计划与分期调整") { LoanAccountPlan(accountID: accountID) }.frame(minHeight: 54)
                } else {
                    Button(calculating ? "计算中…" : "还款试算") { Task { await calculate() } }.disabled(!draft.valid || calculating).frame(minHeight: 54)
                }
                if let preview {
                    LabeledContent("计划剩余本金", value: Values.money(preview.remainingPrincipal))
                    LabeledContent("预计总利息", value: Values.money(preview.totalInterest)).padding(.top, 8)
                    if let next = preview.next {
                        LabeledContent("下期还款日", value: next.date).padding(.top, 8)
                        LabeledContent("下期应还", value: Values.money(next.payment)).padding(.top, 8)
                        LabeledContent("本金 / 利息", value: "\(Values.money(next.principal)) / \(Values.money(next.interest))").font(.caption).padding(.top, 8)
                    } else { Text("已还清全部期数").font(.subheadline).padding(.top, 8) }
                    Text("固定利率试算，不含手续费及提前还款").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                if let error { InlineError(message: error) }
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
            // 草稿改变回调无返回值；清除旧试算，防止用户把旧结果当成新合同数据。
            .onChange(of: draft) { _, _ in preview = nil; error = nil }
    }
    /// 请求统一还款试算；参数：无；返回值：无；失败留在表单，修改中的旧响应丢弃，不写账本。
    private func calculate() async {
        guard draft.valid, !calculating else { return }
        let snapshot = draft
        calculating = true; error = nil; defer { calculating = false }
        do {
            let result: LoanPlanSummary = try await store.api.request("/finance/loan-preview", method: "POST", body: snapshot.fields)
            if snapshot == draft { preview = result }
        } catch { if snapshot == draft { self.error = error.localizedDescription } }
    }
}
