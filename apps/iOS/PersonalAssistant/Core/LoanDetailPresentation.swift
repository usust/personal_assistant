import Foundation

/// 贷款计划汇总基于计划已还期数，独立于实际流水；所有汇总使用精确十进制。
nonisolated struct LoanPlanTotals {
    let paidPrincipal: Decimal
    let paidInterest: Decimal
    let remainingPrincipal: Decimal
    let remainingInterest: Decimal
    let paidTotal: Decimal
    let remainingTotal: Decimal
    var progress: Double {
        let total = paidPrincipal + remainingPrincipal
        return total > 0 ? NSDecimalNumber(decimal: paidPrincipal / total).doubleValue : 0
    }
    /// 汇总完整计划；参数：schedule 为完整期次，paidPeriods 为已还期数；返回值：精确分项与含单期修正的应还合计，无副作用。
    init(schedule: [LoanPaymentSummary], paidPeriods: Int) {
        var pp = Decimal.zero, pi = Decimal.zero, rp = Decimal.zero, ri = Decimal.zero
        var paid = Decimal.zero, remaining = Decimal.zero
        for row in schedule {
            let principal = Decimal(string: row.principal) ?? 0
            let interest = Decimal(string: row.interest) ?? 0
            let payment = Decimal(string: row.payment) ?? 0
            if row.period <= paidPeriods { pp += principal; pi += interest; paid += payment }
            else { rp += principal; ri += interest; remaining += payment }
        }
        paidPrincipal = pp; paidInterest = pi; remainingPrincipal = rp; remainingInterest = ri
        paidTotal = paid; remainingTotal = remaining
    }
}

/// 贷款账户视角下的流水计算，不把内部转账当作收入或费用。
nonisolated enum LoanDetailPresentation {
    /// 自动读取全部历史分页；参数：loadPage 输入偏移量并返回至多 500 条流水，失败抛错；返回值：去重后的全部记录，取消或分页不前进时抛错，不发布不完整汇总。
    static func allTransactions(loadPage: (Int) async throws -> [FinanceTransaction]) async throws -> [FinanceTransaction] {
        var rows: [FinanceTransaction] = [], seen: Set<Int> = [], offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await loadPage(offset)
            try Task.checkCancellation()
            let previous = rows.count
            for row in page where seen.insert(row.id).inserted { rows.append(row) }
            if page.count < 500 { return rows }
            guard rows.count > previous else { throw URLError(.badServerResponse) }
            offset += page.count
        }
    }

    /// 将流水分组并排序；参数：rows 为全部已入账记录，accountID 为当前账户；返回值：月份及月内记录均倒序的非空分组，无写入。
    static func transactionMonths(_ rows: [FinanceTransaction], accountID: Int) -> [LoanMonth] {
        // 分组回调输入流水、返回年月键；排序回调输入两条流水、返回日期及 ID 倒序关系。
        let groups = Dictionary(grouping: rows) { String($0.transactionDate.prefix(7)) + "-01" }
        return groups.keys.sorted(by: >).map { key in
            LoanMonth(id: key, rows: groups[key]!.sorted { $0.transactionDate == $1.transactionDate ? $0.id > $1.id : $0.transactionDate > $1.transactionDate }, accountID: accountID)
        }
    }

    /// 展示单期应还额与计划本息的差额；参数：row 为分期；返回值：带正负号的金额，无修正时为 nil，不改变本金或利息。
    static func paymentCorrection(_ row: LoanPaymentSummary) -> String? {
        guard row.paymentOverridden == true else { return nil }
        let difference = (Decimal(string: row.payment) ?? 0) - (Decimal(string: row.principal) ?? 0) - (Decimal(string: row.interest) ?? 0)
        guard difference != 0 else { return nil }
        return (difference > 0 ? "+" : "") + Values.money(NSDecimalNumber(decimal: difference).stringValue)
    }
    /// 判断是否能修正分期计划；参数：row 为权威分期；返回值：期初有本金时为 true，计划已还不影响可调状态，无副作用。
    static func canAdjust(_ row: LoanPaymentSummary) -> Bool {
        (Decimal(string: row.remaining) ?? 0) + (Decimal(string: row.principal) ?? 0) > 0
    }
    /// 选择默认调整期次；参数：plan 为权威计划，today 为当前 YYYY-MM-DD；返回值：优先本月起未还期次，其次逾期未还、最后首个历史期次，无可调期次时为 nil，不修改计划。
    static func adjustmentPeriod(_ plan: LoanPlanSummary, today: String) -> Int? {
        let eligible = (plan.schedule ?? []).filter(canAdjust)
        let unpaid = eligible.filter { $0.period > (plan.paidPeriods ?? 0) }
        return unpaid.first { $0.date.prefix(7) >= today.prefix(7) }?.period ?? unpaid.first?.period ?? eligible.first?.period
    }
    /// 计算已入账流水对本账户的变动；参数：row 为流水，accountID 为目标账户；返回值：有符号余额变动，无关或非已入账流水返回零。
    static func change(_ row: FinanceTransaction, accountID: Int) -> Decimal {
        guard row.status == "posted", let amount = Decimal(string: row.amount) else { return 0 }
        if row.type == "transfer" && row.targetAccountId == accountID { return amount }
        guard row.accountId == accountID else { return 0 }
        return row.type == "income" ? amount : -amount
    }
    /// 生成自然月区间；参数：date 为任意月内日期；返回值：公历起止日字符串，独立于夏令时。
    static func monthRange(_ date: Date) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let last = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
        return (Values.day(first), Values.day(last))
    }
}

/// 独立的分期操作；rate 从选中期起调息，payment 同时调息并校准本期银行账单。
nonisolated enum LoanAdjustmentKind: String {
    case rate, payment
    var title: String { self == .rate ? "调整利率" : "调整金额" }
}

/// 侧滑选中的期次与操作一起传递给 sheet，避免筛选后出现旧期次。
nonisolated struct LoanAdjustmentSelection: Identifiable {
    let period: Int
    let kind: LoanAdjustmentKind
    var id: String { "\(period)-\(kind.rawValue)" }
}

/// 分期调整草稿；只提交所选操作对应的字段，不包含合同本金或账本余额。
nonisolated struct LoanAdjustmentDraft: Equatable {
    let kind: LoanAdjustmentKind
    var fromPeriod: Int
    var annualRate: String
    var payment = ""
    /// 初始化调整草稿；参数：row 为指定期次，fallbackRate 为旧接口缺少逐期利率时的合同利率，kind 为独立操作；返回值：新草稿，无副作用。
    init(row: LoanPaymentSummary, fallbackRate: String, kind: LoanAdjustmentKind) {
        self.kind = kind
        fromPeriod = row.period; annualRate = row.annualRate ?? fallbackRate
        payment = row.payment
    }
    /// 检查可提交字段；参数：无；返回值：合法状态，后端继续检查本金、期次与版本。
    var valid: Bool {
        let rateValid = annualRate.range(of: #"^(0|[1-9][0-9]{0,2})(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil && (Decimal(string: annualRate) ?? 101) <= 100
        return rateValid && (kind == .rate || Values.validMoney(payment, positive: true))
    }
    /// 构造调整请求；参数：revision 为服务端版本；返回值：白名单字典，reprice 同时提交新利率与本期账单，旧服务端拒绝未知操作。
    func fields(revision: Int) -> [String: Any] {
        var fields: [String: Any] = ["revision": revision, "fromPeriod": fromPeriod, "kind": kind == .rate ? "rate" : "reprice", "annualRate": annualRate]
        if kind == .payment {
            fields["scope"] = "period"
            fields["payment"] = payment
        }
        return fields
    }
}

/// 完整历史按月展示，金额按当前账户方向汇总。
nonisolated struct LoanMonth: Identifiable {
    let id: String
    let rows: [FinanceTransaction]
    let accountID: Int
    /// 汇总流入；参数：无；返回值：本账户正向金额，回调以累计值和流水为输入，无副作用。
    var inflow: Decimal { rows.reduce(0) { $0 + max(0, LoanDetailPresentation.change($1, accountID: accountID)) } }
    /// 汇总流出；参数：无；返回值：本账户负向金额的绝对值，回调以累计值和流水为输入，无副作用。
    var outflow: Decimal { rows.reduce(0) { $0 + max(0, -LoanDetailPresentation.change($1, accountID: accountID)) } }
}
