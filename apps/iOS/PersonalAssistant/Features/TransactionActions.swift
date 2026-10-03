import SwiftUI

/// 编辑入口直接复用新增流水页面；仅传入原流水，由同一组件负责布局、预填和 PATCH 保存。
struct TransactionMetadataEditor: View {
    let transaction: FinanceTransaction

    /// 构建共用流水编辑页；参数：无；返回值：与新增流水完全共用布局的预填页面。
    var body: some View {
        TransactionEditor(editingTransaction: transaction)
    }
}

/// 原支出退款表单；退款返回原账户，服务端在事务内校验累计退款上限。
struct TransactionRefundEditor: View {
    let transaction: FinanceTransaction
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date.now
    @State private var notes = ""
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString
    @State private var submitted: [String: Any]?

    /// 构建退款表单；参数：无；返回值：金额、日期和备注输入，原账户只读，不执行真实银行转账。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("原支出", value: Values.money(transaction.amount))
                    LabeledContent("退款账户", value: store.accounts.first { $0.id == transaction.accountId }?.name ?? "已删除账户")
                    TextField("退款金额", text: $amount).keyboardType(.decimalPad)
                    DatePicker("退款时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("备注", text: $notes, axis: .vertical)
                }
                if let error { InlineError(message: error) }
            }.navigationTitle("退款").navigationBarTitleDisplayMode(.inline).disabled(busy)
                .toolbar { SaveToolbar(busy: busy, valid: Values.validMoney(amount, positive: true) && (Decimal(string: amount) ?? 0) <= (Decimal(string: transaction.amount) ?? 0) && Values.day(date) >= transaction.transactionDate && notes.utf8.count <= 2000) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
        }
    }
    /// 提交退款并刷新账户余额；参数：无；返回值：无；相同表单失败重试复用幂等键，改动后更换键，失败保留输入。
    private func save() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var body: [String: Any] = ["amount": amount, "transactionDate": Values.day(date), "transactionTime": Values.time(date), "description": notes]
        if let submitted, !NSDictionary(dictionary: submitted).isEqual(to: body) { requestID = UUID().uuidString }
        submitted = body; body["requestId"] = requestID
        do {
            try await store.api.mutate("/finance/transactions/\(transaction.id)/refund", body: body)
            dismiss(); await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
    }
}
