import Foundation

#if FINANCE_LOCAL_PLANS_TEST_MAIN
/// 独立计划测试账本；仅以内存副本模拟提交，不读取真实数据库或网络。
@MainActor
final class FinanceLocalStore {
    var document: [String: Any] = [:]
    var space: [String: Any] = [:]
    var spaces: [String: [String: Any]] = [:]
    var activeKey = "test"
    var onMutation: (() -> Void)?
    /// 提供错误；参数：message 为错误文本；返回值：独立测试错误，无副作用。
    static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }
    /// 读取整数身份；参数：row 为记录、key 为字段；返回值：编号或零，无副作用。
    static func id(_ row: [String: Any], _ key: String = "id") -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
    /// 精确读取分值；参数：value 为金额字符串；返回值：整数分或校验错误，无副作用。
    static func cents(_ value: Any?) throws -> Int64 {
        guard let raw = value as? String, Values.validMoney(raw), let value = Decimal(string: raw) else { throw failure("金额无效") }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }
    /// 格式化分值；参数：value 为整数分；返回值：两位小数字符串，无副作用。
    static func money(_ value: Int64) -> String { "\(value < 0 ? "-" : "")\(abs(value) / 100)." + String(format: "%02lld", abs(value) % 100) }
    /// 读取表；参数：name 为表名；返回值：内存记录，无副作用。
    func rows(_ name: String) -> [[String: Any]] { space[name] as? [[String: Any]] ?? [] }
    /// 独立测试不读取截图；参数：无；返回值：空投影，无副作用。
    func incompleteScreenshotTransactions() throws -> [[String: Any]] { [] }
    /// 模拟原子提交；参数：next 为完整文档；返回值：无；替换内存空间。
    func commit(_ next: [String: Any]) throws {
        document = next; spaces = next["spaces"] as? [String: [String: Any]] ?? [:]; space = spaces[activeKey] ?? [:]
    }
}

@main @MainActor
struct FinanceLocalPlansTests {
    /// 构造隔离账本；参数：无；返回值：余额1000元的测试数据，无真实数据副作用。
    static func fixture() -> [String: Any] {
        ["accounts": [["id": 1, "name": "测试账户", "balance": "1000.00", "availableBalance": "1000.00", "archived": false, "selectable": true]], "transactions": [[String: Any]](), "categories": [[String: Any]](), "presets": [[String: Any]](), "plans": [String: [String: Any]]()]
    }
    /// 读取测试余额；参数：space 为账本；返回值：第一个账户金额字符串，无副作用。
    static func balance(_ space: [String: Any]) -> String { (space["accounts"] as! [[String: Any]])[0]["balance"] as! String }
    /// 断言抛错；参数：work 为会失败的无参操作；返回值：无；意外成功终止测试。
    static func rejects(_ work: () throws -> Void) { do { try work(); fatalError("应拒绝但成功") } catch {} }
    /// 执行独立回归；参数：无；返回值：无；失败抛错或终止，成功输出摘要。
    static func main() throws {
        typealias S = FinanceLocalStore
        let february = try S.planMonth("2024-01-31", months: 1), march = try S.planMonth("2024-01-31", months: 2)
        precondition(february == "2024-02-29" && march == "2024-03-31")
        let common = try S.nextLocalOccurrence("2025-02-28", start: "2024-02-29", frequency: "yearly"), leap = try S.nextLocalOccurrence("2027-02-28", start: "2024-02-29", frequency: "yearly")
        precondition(common == "2026-02-28" && leap == "2028-02-29")
        rejects { _ = try S.planDate("2026-02-30") }
        let split = try S.splitLocalInstallment(100, periods: 3, rounding: "round", remainder: "last")
        precondition(split == [33, 33, 34])
        rejects { _ = try S.splitLocalInstallment(3, periods: 5, rounding: "round", remainder: "last") }
        var space = fixture()
        let expense: [String: Any] = ["requestId": "expense-test-001", "type": "expense", "accountId": 1, "amount": "100.00", "transactionDate": "2026-01-01"]
        _ = try S.apply("/finance/transactions", method: "POST", body: expense, newID: 2, space: &space)
        precondition(balance(space) == "900.00")
        let terms: [String: Any] = ["name": "测试分期", "periods": 3, "firstDate": "2026-01-31", "interest": "2.00", "interestMode": "spread", "rounding": "round", "remainder": "last", "debtMode": "upfront"]
        _ = try S.applyLocalPlan("/finance/transactions/2/installment", method: "POST", body: terms, newID: 10, space: &space, today: "2026-01-01")
        precondition(balance(space) == "900.00")
        _ = try S.apply("/finance/transactions/10/confirm", method: "POST", body: [:], newID: 100, space: &space)
        precondition(balance(space) == "899.33")
        _ = try S.apply("/finance/transactions/10/confirm", method: "POST", body: [:], newID: 100, space: &space)
        precondition(balance(space) == "899.33")
        _ = try S.apply("/finance/transactions/10/refund", method: "POST", body: ["requestId": "refund-test-001", "amount": "1.00", "transactionDate": "2026-02-01"], newID: 20, space: &space)
        precondition(balance(space) == "900.33")
        let refund = (space["transactions"] as! [[String: Any]]).first { S.id($0) == 20 }!
        precondition(S.id(refund, "installmentParentId") == 0)
        _ = try S.apply("/finance/transactions/10", method: "DELETE", body: [:], newID: 100, space: &space)
        precondition(balance(space) == "933.33")
        _ = try S.applyLocalPlan("/finance/installments/2/finish", method: "POST", body: [:], newID: 100, space: &space, today: "2026-02-01")
        precondition(balance(space) == "932.00")
        _ = try S.applyLocalPlan("/finance/installments/2/finish", method: "POST", body: [:], newID: 100, space: &space, today: "2026-02-01")
        precondition(balance(space) == "932.00")
        _ = try S.applyLocalPlan("/finance/installments/2", method: "PATCH", body: ["description": "新备注"], newID: 100, space: &space, today: "2026-02-01")
        precondition(balance(space) == "932.00")
        _ = try S.applyLocalPlan("/finance/installments/2", method: "DELETE", body: [:], newID: 100, space: &space, today: "2026-02-01")
        precondition(balance(space) == "1000.00")
        var recurring = fixture()
        _ = try S.apply("/finance/presets", method: "POST", body: ["key": "monthly-test", "name": "月末", "transaction": expense, "frequency": "monthly", "startDate": "2026-01-31", "endDate": "2026-03-31"], newID: 5, space: &recurring)
        try S.materializeLocalPresets(space: &recurring, newID: 10, today: "2026-04-01")
        precondition(balance(recurring) == "1000.00")
        let drafts = recurring["transactions"] as! [[String: Any]]
        precondition(drafts.count == 3 && drafts.map { $0["transactionDate"] as! String } == ["2026-01-31", "2026-02-28", "2026-03-31"])
        try S.materializeLocalPresets(space: &recurring, newID: 20, today: "2026-04-01")
        precondition((recurring["transactions"] as! [[String: Any]]).count == 3)
        _ = try S.apply("/finance/transactions/10/confirm", method: "POST", body: [:], newID: 30, space: &recurring)
        precondition(balance(recurring) == "900.00")
        rejects { try S.validatePlanSync(["path": "/finance/recurring/materialize", "method": "POST"]) }
        var repricing = fixture()
        _ = try S.apply("/finance/transactions", method: "POST", body: expense, newID: 2, space: &repricing)
        _ = try S.applyLocalPlan("/finance/transactions/2/installment", method: "POST", body: terms, newID: 10, space: &repricing, today: "2026-01-01")
        _ = try S.applyLocalPlan("/finance/installments/2", method: "PATCH", body: ["interest": "5.00"], newID: 30, space: &repricing, today: "2026-02-01")
        precondition(balance(repricing) == "898.33")
        let projections = try S.localPlanAccounts(space: repricing)
        precondition(projections[0]["installmentPendingAmount"] as? String == "70.00")
        _ = try S.applyLocalPlan("/finance/installments/2", method: "PATCH", body: ["debtMode": "spread"], newID: 40, space: &repricing, today: "2026-02-01")
        precondition(balance(repricing) == "965.00")
        let store = S(); store.space = repricing
        let list = try store.readLocal("/finance/installments", query: []) as! [[String: Any]]
        precondition(list.count == 1 && list[0]["pendingAmount"] as? String == "70.00")
        try loanTests()
        print("FinanceLocalPlansTests passed: dates, cents, upfront, confirmation, refunds, deletion, finish, metadata, recurring, sync guard, exact loans and adjustments")
    }

    /// 验证贷款原始合同、历史保护和调整；参数：无；返回值：无；使用后端固定例与零利率边界，失败抛错或终止，不操作真实账本。
    static func loanTests() throws {
        typealias S = FinanceLocalStore
        var terms: [String: Any] = ["loanPrincipal": "1000.00", "loanAnnualRate": "12", "loanMethod": "annuity", "loanPeriods": 12, "loanPaidPeriods": 0, "loanFirstPaymentDate": "2028-01-31"]
        var plan = try S.buildLocalLoan(terms)
        var rows = plan["schedule"] as! [[String: Any]]
        precondition(rows[0]["payment"] as? String == "88.85" && rows[1]["date"] as? String == "2028-02-29" && rows[2]["date"] as? String == "2028-03-31")
        var principal: Int64 = 0
        for row in rows { principal += try S.cents(row["principal"]) }
        precondition(principal == 100000 && rows.last?["remaining"] as? String == "0.00")
        terms["loanMethod"] = "equal_principal"; plan = try S.buildLocalLoan(terms); rows = plan["schedule"] as! [[String: Any]]
        precondition(rows[0]["principal"] as? String == "83.33" && rows[0]["interest"] as? String == "10.00" && rows[0]["payment"] as? String == "93.33")
        terms["loanMethod"] = "interest_only"; plan = try S.buildLocalLoan(terms); rows = plan["schedule"] as! [[String: Any]]
        precondition(rows[0]["payment"] as? String == "10.00" && rows.last?["payment"] as? String == "1010.00" && plan["totalInterest"] as? String == "120.00")
        terms["loanPrincipal"] = "0.01"; terms["loanAnnualRate"] = "0"; terms["loanPeriods"] = 480
        plan = try S.buildLocalLoan(terms); rows = plan["schedule"] as! [[String: Any]]
        precondition(rows.count == 480 && rows.last?["principal"] as? String == "0.01")
        var space = fixture()
        let account: [String: Any] = ["name": "测试贷款", "accountType": "other", "institution": "贷款", "loanPrincipal": "12000.00", "loanAnnualRate": "0", "loanMethod": "equal_principal", "loanPeriods": 12, "loanPaidPeriods": 3, "loanFirstPaymentDate": "2026-01-31"]
        _ = try S.apply("/finance/accounts", method: "POST", body: account, newID: 2, space: &space)
        let created = (space["accounts"] as! [[String: Any]])[1]
        precondition(created["balance"] as? String == "-9000.00" && created["loanPlanLocked"] as? Bool == true)
        rejects { var copy = space; _ = try S.apply("/finance/accounts/2", method: "PATCH", body: ["loanAnnualRate": "1"], newID: 3, space: &copy) }
        _ = try S.apply("/finance/accounts/2", method: "PATCH", body: ["loanPaidPeriods": 0], newID: 3, space: &space)
        let before = (space["accounts"] as! [[String: Any]])[1]
        precondition(before["balance"] as? String == "-9000.00")
        let revision = S.id(before, "loanRevision")
        let adjusted = try S.applyLocalLoan("/finance/accounts/2/loan-adjustments", method: "POST", body: ["kind": "payment", "scope": "period", "revision": revision, "fromPeriod": 2, "payment": "900.00"], space: &space) as! [String: Any]
        let adjustedRows = adjusted["schedule"] as! [[String: Any]]
        precondition(adjustedRows[1]["payment"] as? String == "900.00" && adjustedRows[1]["principal"] as? String == "1000.00" && adjustedRows[2]["payment"] as? String == "1000.00")
        precondition((space["accounts"] as! [[String: Any]])[1]["balance"] as? String == "-9000.00")
        rejects { _ = try S.applyLocalLoan("/finance/accounts/2/loan-adjustments", method: "POST", body: ["kind": "rate", "revision": revision, "fromPeriod": 1, "annualRate": "12"], space: &space) }
        let repriced = try S.applyLocalLoan("/finance/accounts/2/loan-adjustments", method: "POST", body: ["kind": "reprice", "scope": "period", "revision": revision + 1, "fromPeriod": 3, "annualRate": "12", "payment": "1090.00"], space: &space) as! [String: Any]
        let repricedRows = repriced["schedule"] as! [[String: Any]]
        precondition(repricedRows[2]["principal"] as? String == "1000.00" && repricedRows[2]["interest"] as? String == "90.00" && repricedRows[2]["interestCalibrated"] as? Bool == true)
        precondition(repricedRows[1]["payment"] as? String == "900.00")
        let rateOnly = try S.adjustLocalLoan(before, before: try S.localLoanPlan(before), input: ["kind": "rate", "revision": revision, "fromPeriod": 4, "annualRate": "12"])
        let rateRows = rateOnly["schedule"] as! [[String: Any]]
        precondition(rateRows[2]["interest"] as? String == "0.00" && rateRows[3]["principal"] as? String == "1000.00" && rateRows[3]["interest"] as? String == "90.00" && rateRows[4]["interest"] as? String == "80.00")
        let fixed = try S.adjustLocalLoan(before, before: try S.localLoanPlan(before), input: ["revision": revision, "fromPeriod": 1, "annualRate": "0", "paymentMode": "fixed", "payment": "5000.00"])
        let fixedRows = fixed["schedule"] as! [[String: Any]]
        precondition(fixedRows[0]["payment"] as? String == "5000.00" && fixedRows[2]["payment"] as? String == "2000.00" && fixedRows[3]["payment"] as? String == "0.00")
        var roundingTerms = terms
        roundingTerms["loanPrincipal"] = "1000.00"; roundingTerms["loanPeriods"] = 3; roundingTerms["loanMethod"] = "equal_principal"
        let rounding = try S.buildLocalLoan(roundingTerms)["schedule"] as! [[String: Any]]
        precondition(rounding.map { $0["principal"] as! String } == ["333.33", "333.33", "333.34"])
        var maximal = roundingTerms; maximal["loanPeriods"] = 480; maximal["loanMethod"] = "annuity"; maximal["loanAnnualRate"] = "3.4567"
        let maximalRows = try S.buildLocalLoan(maximal)["schedule"] as! [[String: Any]]
        var maximalSum: Int64 = 0
        for row in maximalRows { maximalSum += try S.cents(row["principal"]) }
        precondition(maximalSum == 100000 && maximalRows.last?["remaining"] as? String == "0.00")
        rejects { _ = try S.localLoanPlan(["loanPlanLocked": true]) }
        rejects { _ = try S.localLoanRate("100.0001") }
        rejects { var bad = terms; bad["loanPeriods"] = 2.5; _ = try S.buildLocalLoan(bad) }
        rejects { var copy = space; _ = try S.apply("/finance/accounts/2", method: "PATCH", body: ["currentDebt": "-1.00"], newID: 3, space: &copy) }
    }
}
#endif
