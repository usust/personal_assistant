import SwiftUI

/// 单笔流水详情，所有写入复用财务接口，刷新后由父列表传入最新记录。
struct TransactionDetailView: View {
    let transaction: FinanceTransaction
    /// 无参数、无返回值；写入完成后重新加载父列表和账户余额。
    let onChange: () async -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var refunding = false
    @State private var templating = false
    @State private var deleting = false
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    /// 判断普通已入账支出是否支持退款或转分期；参数：无；返回值：资格标记，累计退款约束由服务端最终校验。
    private var ordinaryExpense: Bool {
        transaction.type == "expense" && transaction.status == "posted" && transaction.refundParentId == nil && transaction.installmentParentId == nil
    }
    /// 判断是否可退款；参数：无；返回值：普通支出和分期子账单已入账时为 true，退款记录不能再次退款。
    private var refundableExpense: Bool {
        transaction.type == "expense" && transaction.status == "posted" && transaction.refundParentId == nil
    }
    /// 构建详情页；参数：无；返回值：快捷操作、真实流水字段及原支出的报销状态入口，修改状态仅更新资料。
    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button { editing = true } label: { actionLabel("编辑", icon: "pencil", color: .blue) }
                            .disabled(transaction.status == "voided")
                        Button { deleting = true } label: { actionLabel("删除", icon: "trash", color: .red) }
                            .disabled(transaction.status == "installment" || transaction.rebateParentId != nil)
                        Button { refunding = true } label: { actionLabel("退款", icon: "arrow.uturn.backward", color: .blue) }
                            .disabled(!refundableExpense)
                        Button { templating = true } label: { actionLabel("存为模板", icon: "bolt.fill", color: .orange) }
                            .disabled(transaction.refundParentId != nil || transaction.rebateParentId != nil || transaction.status == "voided")
                        NavigationLink { ConsumptionInstallmentView(bill: transaction).onDisappear { Task { await onChange() } } } label: {
                            actionLabel("分期", icon: "square.stack.fill", color: .green)
                        }.disabled(!ordinaryExpense && transaction.status != "installment" && transaction.installmentParentId == nil)
                        NavigationLink { BillAnalysisView() } label: { actionLabel("账单分析", icon: "chart.pie.fill", color: .purple) }
                    }.buttonStyle(.plain).padding(.vertical, 4)
                }
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            if let error { Section { InlineError(message: error) } }
            Section {
                LabeledContent("类型", value: typeName)
                LabeledContent("分类", value: store.categories.first { $0.id == transaction.categoryId }?.name ?? "未分类")
                LabeledContent("状态", value: transaction.installmentParentId != nil && transaction.status == "pending" ? "待入账" : ["posted": "已入账", "pending": "待确认", "voided": "已作废", "installment": "分期主账单"][transaction.status] ?? transaction.status)
                if transaction.status == "pending" && transaction.installmentParentId == nil { Button("确认入账") { confirming = true } }
                if transaction.type == "expense", transaction.refundParentId == nil, transaction.rebateParentId == nil,
                   ["posted", "pending"].contains(transaction.status) {
                    // 绑定读取当前流水状态；写入回调输入状态键、返回无，异步保存成功后由父页提供新流水，失败保留原值。
                    Picker("报销状态", selection: Binding(get: { transaction.reimbursementStatus ?? "" }, set: { value in Task { await saveReimbursement(value) } })) {
                        ForEach(ReimbursementStatus.options, id: \.self) { value in Text(ReimbursementStatus.title(value)).tag(value) }
                    }.pickerStyle(.menu)
                }
            }
            Section {
                LabeledContent("日期和时间", value: transaction.transactionDateTime)
                LabeledContent(transaction.type == "expense" ? "实付金额" : "金额", value: Values.money(transaction.amount))
                LabeledContent("货币", value: store.accounts.first { $0.id == transaction.accountId }?.currency ?? "CNY")
                LabeledContent(transaction.type == "transfer" ? "转出账户" : "账户", value: accountName(transaction.accountId))
                if let target = transaction.targetAccountId { LabeledContent("转入账户", value: accountName(target)) }
            }
            Section {
                LabeledContent("交易对象", value: transaction.counterparty.isEmpty ? "无" : transaction.counterparty)
                LabeledContent("备注", value: transaction.description.isEmpty ? "无" : transaction.description)
                if transaction.type == "expense" { LabeledContent("优惠", value: Values.money(transaction.discount ?? "0.00")) }
                if transaction.type == "transfer" {
                    LabeledContent("手续费", value: Values.money(transaction.fee ?? "0.00"))
                    LabeledContent("优惠", value: Values.money(transaction.rebate ?? "0.00"))
                    if (Decimal(string: transaction.rebate ?? "0") ?? 0) > 0 {
                        LabeledContent("优惠账户", value: accountName(transaction.rebateAccountId ?? transaction.accountId))
                    }
                }
                if let parent = transaction.refundParentId { LabeledContent("原支出", value: "#\(parent)") }
                if let parent = transaction.installmentParentId { LabeledContent("分期主账单", value: "#\(parent)") }
                if let parent = transaction.rebateParentId { LabeledContent("关联转账", value: "#\(parent)") }
            }
        }.navigationTitle("账单详情").navigationBarTitleDisplayMode(.inline)
            .disabled(busy).navigationBarBackButtonHidden(busy)
            .sheet(isPresented: $editing, onDismiss: refresh) { TransactionMetadataEditor(transaction: transaction) }
            .sheet(isPresented: $refunding, onDismiss: refresh) { TransactionRefundEditor(transaction: transaction) }
            .sheet(isPresented: $templating) { TransactionTemplateSheet(transaction: transaction) }
            .alert("删除流水？", isPresented: $deleting) {
                Button("删除", role: .destructive) { Task { await mutate(delete: true) } }
                Button("取消", role: .cancel) { }
            } message: { Text(transaction.installmentParentId != nil ? "仅删除本期，已计入欠款退回，关联退款一并撤销，其他期次不变。" : "已入账金额将回退，关联退款或优惠一并撤销。") }
            .alert("确认入账？", isPresented: $confirming) {
                Button("确认") { Task { await mutate(delete: false) } }
                Button("取消", role: .cancel) { }
            }
    }
    /// 更新原支出的报销状态；参数：value 为无需报销空键、pending 或 reimbursed；返回值：无；仅提交变化字段，失败显示错误，不生成收入或重算余额。
    private func saveReimbursement(_ value: String) async {
        guard !busy, value != (transaction.reimbursementStatus ?? "") else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await store.api.mutate("/finance/transactions/\(transaction.id)", method: "PATCH", body: ["reimbursementStatus": value])
            await onChange()
        } catch { self.error = error.localizedDescription }
    }
    /// 返回类型名称；参数：无；返回值：退款优先，转账按目标账户用途展示，其余按收支类型展示。
    private var typeName: String {
        if transaction.refundParentId != nil { return "退款" }
        if transaction.type == "transfer" {
            return AccountPresentation.transferTitle(target: store.accounts.first { $0.id == transaction.targetAccountId })
        }
        return ["expense": "支出", "income": "收入"][transaction.type] ?? transaction.type
    }
    /// 绘制快捷操作；参数：title 为文案，icon 为系统图标，color 为操作颜色；返回值：等宽紧凑卡片。
    private func actionLabel(_ title: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption)
        }.foregroundStyle(color).frame(width: 78, height: 74)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    /// 查询账户名；参数：id 为真实账户 ID；返回值：账户名称或删除后的兜底文字。
    private func accountName(_ id: Int) -> String { store.accounts.first { $0.id == id }?.name ?? "已删除账户" }
    /// 刷新编辑结果；参数：无；返回值：无，触发父页面异步加载。
    private func refresh() { Task { await onChange() } }
    /// 执行已确认操作；参数：delete 为 true 删除，否则确认入账；返回值：无，失败留在详情显示错误，成功刷新余额。
    private func mutate(delete: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await store.api.mutate("/finance/transactions/\(transaction.id)" + (delete ? "" : "/confirm"), method: delete ? "DELETE" : "POST")
            if delete { dismiss() }
            await onChange()
        } catch { self.error = error.localizedDescription }
    }
}

/// 将现有流水保存为可复用模板，不重复创建交易或改变余额。
private struct TransactionTemplateSheet: View {
    let transaction: FinanceTransaction
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var key = UUID().uuidString
    @State private var submitted: NSDictionary?
    /// 构建模板确认表单；参数：无；返回值：名称及金额预览，明确提交后才写入模板。
    var body: some View {
        NavigationStack {
            Form {
                TextField("模板名称", text: $name)
                LabeledContent("金额", value: Values.money(transaction.amount))
                if let error { InlineError(message: error) }
            }.navigationTitle("存为模板").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128) { Task { await save() } } }
                .disabled(busy).interactiveDismissDisabled(busy)
        }.presentationDetents([.medium])
    }
    /// 保存模板；参数：无；返回值：无；将净额恢复为含优惠的原价，服务端生成模板时不会再次扣减优惠。
    private func save() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let gross = (Decimal(string: transaction.amount) ?? 0) + (Decimal(string: transaction.discount ?? "0") ?? 0)
        var value: [String: Any] = ["type": transaction.type, "accountId": transaction.accountId, "amount": NSDecimalNumber(decimal: gross).stringValue, "discount": transaction.discount ?? "0.00", "counterparty": transaction.counterparty, "description": transaction.description, "fee": transaction.fee ?? "0.00"]
        if let category = transaction.categoryId, store.categories.contains(where: { !$0.deleted && $0.id == category }) {
            // 新模板是新的分类引用；历史流水的墓碑分类不能随模板复制。
            value["categoryId"] = category
        }
        // 模板只继承需报销的意向，新生成支出不能直接继承上一笔的已报销结果。
        if !(transaction.reimbursementStatus ?? "").isEmpty { value["reimbursementStatus"] = "pending" }
        if let target = transaction.targetAccountId { value["targetAccountId"] = target }
        if let rebate = transaction.rebate { value["rebate"] = rebate; value["rebateAccountId"] = transaction.rebateAccountId ?? transaction.accountId; value["rebatePending"] = transaction.rebatePending ?? false }
        var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "frequency": "", "startDate": Values.day(.now), "transaction": value]
        // 相同内容重试沿用幂等键，修改草稿后换键，避免网络失败时重复保存或键冲突。
        if let submitted, !submitted.isEqual(to: body) { key = UUID().uuidString }
        submitted = NSDictionary(dictionary: body); body["key"] = key
        do {
            try await store.api.mutate("/finance/presets", body: body)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// 分期计划中的单期详情入口，按真实流水 ID 加载，避免以计划快照覆盖最新分类、备注和状态。
struct InstallmentTransactionDetail: View {
    let transactionID: Int
    /// 变更回调无参数、无返回值；刷新上层分期计划。
    let onChange: () async -> Void
    @Environment(AppStore.self) private var store
    @State private var transaction: FinanceTransaction?
    @State private var error: String?

    /// 构建单期详情；参数：无；返回值：加载、错误重试或可编辑的账单详情。
    var body: some View {
        Group {
            if let transaction {
                // 写入回调无参数、无返回值；刷新账户、当前流水和上层计划。
                TransactionDetailView(transaction: transaction) {
                    await store.refreshAfterMutation(.finance)
                    await load()
                    await onChange()
                }
            } else if let error {
                VStack { InlineError(message: error); Button("重试") { Task { await load() } } }
            } else { ProgressView() }
        }.task { await load() }
    }
    /// 查询当前单期流水；参数：无；返回值：无；失败显示错误，账号切换后丢弃旧响应。
    private func load() async {
        let session = store.sessionID
        do {
            let result: FinanceTransaction = try await store.api.request("/finance/transactions/\(transactionID)")
            guard session == store.sessionID && !Task.isCancelled else { return }
            transaction = result; error = nil
        } catch {
            guard session == store.sessionID && !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
