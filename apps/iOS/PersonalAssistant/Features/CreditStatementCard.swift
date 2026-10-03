import SwiftUI

/// 服务端按账本计算的最近已出账期，不使用分页流水推算应还金额。
nonisolated struct CreditStatementSummary: Decodable {
    let configured: Bool
    let month: String
    let startDate: String
    let endDate: String
    let remainingAmount: String
}

/// 放在账户摘要和月份流水之间的本期应还卡片。
struct CreditStatementCard: View {
    let account: FinancialAccount
    /// 操作回调无参数、无返回值；刷新父页的余额与流水。
    let onChange: () async -> Void
    @Environment(AppStore.self) private var store
    @State private var statement: CreditStatementSummary?
    @State private var error: String?
    @State private var repaying = false
    @State private var editing = false
    /// 生成摘要刷新标识；参数：无；返回值：账户、余额或账期设置变化时不同的标识。
    private var refreshKey: String {
        "\(account.id)|\(account.balance)|\(account.billingDay ?? 0)|\(account.billDayInclusive ?? true)|\(account.installmentPendingAmount ?? "")"
    }
    /// 构建本期账单卡片；参数：无；返回值：月份、剩余应还和预填还款入口；未设置账单日时提供设置入口，不伪造金额。
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                if let error {
                    Text("本期账单").font(.caption).foregroundStyle(.secondary)
                    InlineError(message: error)
                    Button("重试") { Task { await load() } }.font(.caption)
                } else if let statement, statement.configured {
                    Label(monthTitle(statement.month) + "账单（剩余应还）", systemImage: "building.columns")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Values.money(statement.remainingAmount)).font(.title3.weight(.semibold)).monospacedDigit()
                } else if statement != nil {
                    Text("本期账单").font(.caption).foregroundStyle(.secondary)
                    Text("未设置账单日").font(.subheadline)
                } else {
                    Text("本期账单").font(.caption).foregroundStyle(.secondary)
                    ProgressView()
                }
            }
            Spacer(minLength: 0)
            if let statement, statement.configured && error == nil {
                Button("本期还款") { repaying = true }
                    .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                    .disabled((Decimal(string: statement.remainingAmount) ?? 0) <= 0)
            } else if statement?.configured == false && error == nil {
                Button("设置") { editing = true }.font(.caption).buttonStyle(.bordered)
            }
        }.padding(.vertical, 4)
            .task(id: refreshKey) { await load() }
            .sheet(isPresented: $repaying, onDismiss: refresh) {
                TransactionEditor(initialRepaymentID: account.id, initialRepaymentAmount: statement?.remainingAmount)
            }
            .sheet(isPresented: $editing, onDismiss: refresh) { AccountEditor(account: account) }
    }
    /// 格式化账单月份；参数：month 为服务端 yyyy-MM；返回值：年月标题，非法格式原样返回。
    private func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let number = Int(parts[1]) else { return month }
        return "\(parts[0])年\(number)月"
    }
    /// 刷新还款或设置结果；参数：无；返回值：无，先刷新父页再读取新的剩余应还。
    private func refresh() { Task { await onChange(); await load() } }
    /// 加载权威账本摘要；参数：无；返回值：无；请求失败保留错误，账号切换或取消后丢弃旧响应。
    private func load() async {
        let session = store.sessionID
        do {
            let result: CreditStatementSummary = try await store.api.request("/finance/accounts/\(account.id)/statement")
            guard session == store.sessionID && !Task.isCancelled else { return }
            statement = result; error = nil
        } catch {
            guard session == store.sessionID && !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
