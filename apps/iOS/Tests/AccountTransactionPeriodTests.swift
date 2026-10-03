import Foundation

/// 验证账期边界与账户资金流，避免月份卡片误分日期或重复统计转账。
enum AccountTransactionPeriodTests {
    /// 构造测试流水；参数：id 为标识，date 为自然日，amount 为金额，type 为收支类型，account 为转出账户，target 为可选转入账户，status 为状态，fee 为手续费；返回值：内存测试记录，无副作用。
    static func row(_ id: Int, _ date: String, amount: String = "10.00", type: String = "expense", account: Int = 1, target: Int? = nil, status: String = "posted", fee: String = "0.00") -> FinanceTransaction {
        FinanceTransaction(fee: fee, id: id, accountId: account, targetAccountId: target, type: type, amount: amount, categoryId: nil, counterparty: "", transactionDate: date, description: "", status: status, source: "http")
    }
    /// 执行账期及资金流测试；参数：无；返回值：无，断言失败终止测试。
    @MainActor static func run() {
        CoreTests.check(FinanceMonth(year: 2028, month: 2).end == "2028-02-29", "首页月份正确包含闰年最后一天")
        CoreTests.check(FinanceMonth(year: 2026, month: 1).shifted(-1).id == "2025-12", "首页月份向前跨年")
        CoreTests.check(FinanceMonth(year: 2026, month: 12).shifted(1).id == "2027-01", "首页月份向后跨年")
        CoreTests.check(FinanceMonth(year: 1900, month: 1).shifted(-1).id == "1900-01", "首页月份不越过有效范围")
        let boundary = ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z")!
        CoreTests.check(FinanceMonth.current(boundary).id == "2026-10", "首页当前月份使用 UTC+8")
        var future = row(99, "2027-01-21", status: "pending")
        future.installmentParentId = 20
        let visible = AccountTransactionPeriods.groups([future, row(1, "2026-09-21")], billingDay: 20, inclusive: true)
        CoreTests.check(visible.count == 1 && visible[0].rows.count == 1 && visible[0].rows[0].id == 1, "待入账分期不生成未来月份卡片")
        let records = [row(1, "2026-09-20"), row(2, "2026-09-21"), row(3, "2026-10-20"), row(4, "2026-10-21")]
        let inclusive = AccountTransactionPeriods.groups(records, billingDay: 20, inclusive: true)
        CoreTests.check(inclusive.map { $0.id } == ["2026-11", "2026-10", "2026-09"], "信用卡按账期月份倒序")
        CoreTests.check(inclusive[1].start == "2026-09-21" && inclusive[1].end == "2026-10-20" && inclusive[1].rows.map { $0.id } == [3, 2], "账单日包含本期且明细倒序")
        let exclusive = AccountTransactionPeriods.groups(records, billingDay: 20, inclusive: false)
        CoreTests.check(exclusive[1].start == "2026-09-20" && exclusive[1].end == "2026-10-19" && exclusive[1].rows.map { $0.id } == [2, 1], "账单日不含本期时边界前移")
        let leap = AccountTransactionPeriods.groups([row(1, "2028-02-29"), row(2, "2028-03-01")], billingDay: 31, inclusive: true)
        CoreTests.check(leap[0].start == "2028-03-01" && leap[0].end == "2028-03-31" && leap[1].end == "2028-02-29", "31日账期兼容闰年短月且不漂移")
        let year = AccountTransactionPeriods.groups([row(1, "2026-12-21")], billingDay: 20, inclusive: true)
        CoreTests.check(year[0].id == "2027-01" && year[0].start == "2026-12-21" && year[0].end == "2027-01-20", "信用卡账期跨年")
        let natural = AccountTransactionPeriods.groups(records, billingDay: nil, inclusive: true)
        CoreTests.check(natural[0].id == "2026-10" && natural[0].start == "2026-10-01" && natural[0].end == "2026-10-31", "普通账户按自然月")
        let global = AccountTransactionPeriods.flow([
            row(1, "2026-09-21", amount: "100.00"),
            row(2, "2026-09-21", amount: "-20.00"),
            row(3, "2026-09-21", amount: "500.00", type: "transfer", target: 2, fee: "2.00"),
            row(4, "2026-09-21", amount: "300.00", type: "income"),
            row(5, "2026-09-21", amount: "999.00", status: "pending")
        ], accountID: nil)
        CoreTests.check(global.outflow == 82 && global.inflow == 300, "全局月份收支扣除退款、排除内部转账本金并保留手续费")
        let flow = AccountTransactionPeriods.flow([
            row(1, "2026-09-21", amount: "100.00"),
            row(2, "2026-09-21", amount: "-20.00"),
            row(3, "2026-09-21", amount: "50.00", type: "transfer", target: 2, fee: "2.00"),
            row(4, "2026-09-21", amount: "30.00", type: "transfer", account: 2, target: 1),
            row(5, "2026-09-21", amount: "999.00", status: "pending"),
            row(6, "2026-09-21", amount: "999.00", status: "voided")
        ], accountID: 1)
        CoreTests.check(flow.outflow == 152 && flow.inflow == 50, "流入流出包含退款转账手续费，排除未入账与作废")
    }
}
