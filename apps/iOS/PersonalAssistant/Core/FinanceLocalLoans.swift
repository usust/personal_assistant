import Foundation

/// 贷款有理数计算的非负大整数；十亿进制避免480期复利幂溢出，不接触真实账本。
@MainActor
private struct LoanNatural {
    private var words: [UInt64]
    private static let base: UInt64 = 1_000_000_000
    /// 构造非负数；参数：value 为 UInt64；返回值：规范化大整数，无副作用。
    init(_ value: UInt64) { words = value >= Self.base ? [value % Self.base, value / Self.base] : [value] }
    /// 构造内部运算结果；参数：words 为低位在前的十亿进制位；返回值：去除前导零的整数，无外部副作用。
    private init(words: [UInt64]) { self.words = words; while self.words.count > 1 && self.words.last == 0 { self.words.removeLast() } }
    /// 精确比较；参数：other 为非负整数；返回值：自身是否小于另一数，无副作用。
    func less(_ other: Self) -> Bool {
        if words.count != other.words.count { return words.count < other.words.count }
        for i in words.indices.reversed() where words[i] != other.words[i] { return words[i] < other.words[i] }
        return false
    }
    /// 精确相乘；参数：other 为非负整数；返回值：乘积，无副作用。
    func times(_ other: Self) -> Self {
        var result = Array(repeating: UInt64(0), count: words.count + other.words.count + 1)
        for i in words.indices {
            var carry: UInt64 = 0
            for j in other.words.indices {
                let value = result[i + j] + words[i] * other.words[j] + carry
                result[i + j] = value % Self.base; carry = value / Self.base
            }
            var k = i + other.words.count
            while carry > 0 { let value = result[k] + carry; result[k] = value % Self.base; carry = value / Self.base; k += 1 }
        }
        return Self(words: result)
    }
    /// 精确相加；参数：other 为非负整数；返回值：和，无副作用。
    func plus(_ other: Self) -> Self {
        var result: [UInt64] = [], carry: UInt64 = 0
        for i in 0..<max(words.count, other.words.count) {
            let value = (i < words.count ? words[i] : 0) + (i < other.words.count ? other.words[i] : 0) + carry
            result.append(value % Self.base); carry = value / Self.base
        }
        if carry > 0 { result.append(carry) }
        return Self(words: result)
    }
    /// 精确相减；参数：other 必须不大于自身；返回值：差，无副作用；违反内部前置条件触发断言。
    func minus(_ other: Self) -> Self {
        precondition(!less(other))
        var result = words, borrow: Int64 = 0
        for i in words.indices {
            var value = Int64(words[i]) - (i < other.words.count ? Int64(other.words[i]) : 0) - borrow
            borrow = value < 0 ? 1 : 0
            if value < 0 { value += Int64(Self.base) }
            result[i] = UInt64(value)
        }
        return Self(words: result)
    }
    /// 计算整数次幂；参数：exponent 为非负期数；返回值：精确幂，无副作用。
    func power(_ exponent: Int) -> Self {
        var result = Self(1), factor = self, count = exponent
        while count > 0 { if count % 2 == 1 { result = result.times(factor) }; count /= 2; if count > 0 { factor = factor.times(factor) } }
        return result
    }
    /// 对有理数四舍五入到分；参数：denominator 为正分母；返回值：不超过金额上限的整数分，越界抛错；无副作用。
    func rounded(over denominator: Self) throws -> Int64 {
        let numerator = times(Self(2)).plus(denominator), divisor = denominator.times(Self(2))
        var low: UInt64 = 0, high: UInt64 = 100_000_000_000_001
        guard numerator.less(divisor.times(Self(high))) else { throw FinanceLocalStore.failure("贷款金额超出上限") }
        while low + 1 < high {
            let mid = (low + high) / 2
            if numerator.less(divisor.times(Self(mid))) { high = mid } else { low = mid }
        }
        return Int64(low)
    }
}

extension FinanceLocalStore {
    /// 识别贷款计划读写端点；参数：path/method 为 HTTP 请求；返回值：是否由贷款执行器负责，无副作用。
    static func supportsLocalLoan(_ path: String, method: String) -> Bool {
        if path == "/finance/loan-preview" { return method == "POST" }
        let p = path.split(separator: "/").map(String.init)
        return p.count == 4 && p[1] == "accounts" && Int(p[2]) != nil && ["loan-adjustments", "loan-adjustment-preview"].contains(p[3]) && method == "POST"
    }
    /// 校验利率并返回精确月利率分子分母；参数：raw 为0至100的百分数，最多四位小数；返回值：分子及固定分母，无副作用，非法输入抛错。
    static func localLoanRate(_ raw: String) throws -> (UInt64, UInt64) {
        guard raw.range(of: #"^(0|[1-9][0-9]{0,2})(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil else { throw failure("年利率格式无效") }
        let components = raw.split(separator: ".")
        let scaled = UInt64(components[0])! * 10_000 + UInt64(((components.count > 1 ? String(components[1]) : "") + "0000").prefix(4))!
        guard scaled <= 1_000_000 else { throw failure("年利率超出范围") }
        return (scaled, 12_000_000)
    }
    /// 精确计算月利息；参数：principal 为非负整数分，rate 为已验证分数；返回值：四舍五入整数分，无副作用或精度损失。
    static func localLoanInterest(_ principal: Int64, rate: (UInt64, UInt64)) throws -> Int64 {
        guard principal >= 0 else { throw failure("贷款本金不可为负") }
        return try LoanNatural(UInt64(principal)).times(LoanNatural(rate.0)).rounded(over: LoanNatural(rate.1))
    }
    /// 生成原始贷款计划；参数：terms 为贷款条款（允许完整账户对象）；返回值：完整计划和汇总；采用大整数有理数，无浮点误差，无写入。
    static func buildLocalLoan(_ terms: [String: Any]) throws -> [String: Any] {
        try validatePlanIntegers(terms, keys: ["loanPeriods", "loanPaidPeriods", "loanReceivingAccountId"])
        let principal = try cents(terms["loanPrincipal"]), periods = id(terms, "loanPeriods"), paid = id(terms, "loanPaidPeriods")
        guard principal > 0, principal <= 100_000_000_000_000, (1...480).contains(periods), (0...periods).contains(paid), let first = terms["loanFirstPaymentDate"] as? String, let annual = terms["loanAnnualRate"] as? String,
              let method = terms["loanMethod"] as? String, ["annuity", "equal_principal", "interest_only"].contains(method) else { throw failure("贷款本金、期数、已还期数或还款方式无效") }
        _ = try planDate(first)
        let rate = try localLoanRate(annual)
        var monthly = try LoanNatural(UInt64(principal)).rounded(over: LoanNatural(UInt64(periods)))
        if method == "annuity", rate.0 > 0 {
            let power = LoanNatural(rate.1 + rate.0).power(periods), base = LoanNatural(rate.1).power(periods)
            let numerator = LoanNatural(UInt64(principal)).times(LoanNatural(rate.0)).times(power)
            let denominator = LoanNatural(rate.1).times(power.minus(base))
            monthly = try numerator.rounded(over: denominator)
        }
        var remaining = principal, rows: [[String: Any]] = []
        for i in 1...periods {
            let interest = try localLoanInterest(remaining, rate: rate)
            var part = method == "interest_only" ? 0 : monthly - (method == "annuity" ? interest : 0)
            part = max(0, part)
            if part > remaining || i == periods { part = remaining }
            remaining -= part
            guard part + interest <= 100_000_000_000_000 else { throw failure("单期还款金额超出上限") }
            rows.append(["period": i, "date": try planMonth(first, months: i - 1), "principal": money(part), "interest": money(interest), "payment": money(part + interest), "remaining": money(remaining), "annualRate": annual])
        }
        return try summarizeLocalLoan(terms, schedule: rows)
    }
    /// 汇总权威贷款快照；参数：account 提供原始本金、已还期数和版本，schedule 为按期排序的完整计划；返回值：校验后的动态摘要；不一致抛错，不回退重算历史。
    static func summarizeLocalLoan(_ account: [String: Any], schedule: [[String: Any]]) throws -> [String: Any] {
        let paid = id(account, "loanPaidPeriods"), principal = try cents(account["loanPrincipal"])
        guard (0...schedule.count).contains(paid), schedule.count == id(account, "loanPeriods") else { throw failure("贷款计划期数不一致") }
        var remaining = principal, remainingPrincipal = principal, totalInterest: Int64 = 0, paidPrincipal: Int64 = 0, paidInterest: Int64 = 0, paidTotal: Int64 = 0, remainingInterest: Int64 = 0, remainingTotal: Int64 = 0, totalPayment: Int64 = 0, last = 0
        var next: [String: Any]?
        for (index, row) in schedule.enumerated() {
            let p = try cents(row["principal"]), interest = try cents(row["interest"]), payment = try cents(row["payment"]), balance = try cents(row["remaining"])
            let overridden = row["paymentOverridden"] as? Bool == true
            guard id(row, "period") == index + 1, p >= 0, interest >= 0, p <= remaining, balance == remaining - p, payment >= 0, payment <= 100_000_000_000_000,
                  overridden ? payment > 0 : payment == p + interest else { throw failure("贷款计划金额不一致") }
            remaining = balance; totalInterest += interest; totalPayment += payment
            guard totalInterest <= 100_000_000_000_000 else { throw failure("贷款总利息超出上限") }
            if payment > 0 { last = index + 1 }
            if index + 1 == paid { remainingPrincipal = remaining }
            if index < paid { paidPrincipal += p; paidInterest += interest; paidTotal += payment }
            else { remainingInterest += interest; remainingTotal += payment; if payment > 0 && next == nil { next = row } }
        }
        guard remaining == 0 else { throw failure("贷款计划末期未结清本金") }
        var result: [String: Any] = ["revision": id(account, "loanRevision"), "paidPeriods": paid, "remainingPrincipal": money(remainingPrincipal), "totalInterest": money(totalInterest), "paidPrincipal": money(paidPrincipal), "paidInterest": money(paidInterest), "paidTotal": money(paidTotal), "remainingInterest": money(remainingInterest), "remainingTotal": money(remainingTotal), "totalPayment": money(totalPayment), "lastPaymentPeriod": last, "schedule": schedule]
        if let next { result["next"] = next }
        return result
    }
    /// 读取已保存的贷款计划；参数：account 为完整账户；返回值：权威计划；锁定历史但未下载明细时抛错，禁止用合同重新覆盖调整历史，无副作用。
    static func localLoanPlan(_ account: [String: Any]) throws -> [String: Any] {
        if let plan = account["loanPlan"] as? [String: Any], let rows = plan["schedule"] as? [[String: Any]] { return try summarizeLocalLoan(account, schedule: rows) }
        guard account["loanPlanLocked"] as? Bool != true else { throw failure("本机缺少已调整贷款明细，请先补齐完整计划并保留本机数据") }
        return try buildLocalLoan(account)
    }

    /// 调整贷款权威计划；参数：account 为合同、before 为完整旧计划、input 为白名单调整请求；返回值：不修改余额的计划；版本冲突或非法调整抛错，无副作用。
    static func adjustLocalLoan(_ account: [String: Any], before: [String: Any], input: [String: Any]) throws -> [String: Any] {
        try validatePlanIntegers(input, keys: ["revision", "fromPeriod"])
        for key in ["kind", "scope", "annualRate", "paymentMode"] { if let value = input[key], !(value is String) { throw failure("贷款调整字段格式无效") } }
        let allowed: Set<String> = ["revision", "fromPeriod", "kind", "scope", "annualRate", "paymentMode", "payment"]
        guard Set(input.keys).isSubset(of: allowed), input["revision"] != nil, id(input, "revision") == id(account, "loanRevision"), let old = before["schedule"] as? [[String: Any]] else { throw failure("贷款计划已变化，请刷新后重新试算") }
        let from = id(input, "fromPeriod"), kind = input["kind"] as? String ?? "", scope = input["scope"] as? String ?? "", mode = input["paymentMode"] as? String ?? "", annual = input["annualRate"] as? String ?? ""
        guard (1...old.count).contains(from) else { throw failure("生效期次无效") }
        let start = from - 1
        let opening = start == 0 ? try cents(account["loanPrincipal"]) : try cents(old[start - 1]["remaining"])
        guard opening > 0 else { throw failure("该期之前本金已结清") }
        let payment = input["payment"] is NSNull || input["payment"] == nil ? nil : try cents(input["payment"])
        if kind == "payment" {
            guard annual.isEmpty, scope == "period", mode.isEmpty, let payment, payment > 0, payment <= 100_000_000_000_000 else { throw failure("请提供单期应还金额，不可同时调息") }
            var rows = old; rows[start]["payment"] = money(payment)
            rows[start]["paymentOverridden"] = payment != (try cents(rows[start]["principal"]) + cents(rows[start]["interest"]))
            rows[start]["interestCalibrated"] = false
            return try summarizeLocalLoan(account, schedule: rows)
        }
        if kind == "reprice" {
            guard scope == "period", mode.isEmpty, let payment, payment > 0, payment <= 100_000_000_000_000 else { throw failure("请提供本期应还金额及年利率") }
            var result = try adjustLocalLoan(account, before: before, input: ["kind": "rate", "revision": id(account, "loanRevision"), "fromPeriod": from, "annualRate": annual])
            var rows = result["schedule"] as! [[String: Any]], row = rows[start]
            let principal = try cents(row["principal"])
            guard payment >= principal else { throw failure("本期金额不能小于计划本金") }
            row["payment"] = money(payment); row["interest"] = money(payment - principal); row["paymentOverridden"] = true; row["interestCalibrated"] = true
            rows[start] = row; result = try summarizeLocalLoan(account, schedule: rows)
            return result
        }
        if kind == "rate" {
            guard scope.isEmpty, mode.isEmpty, payment == nil else { throw failure("利率调整不能同时修改还款金额") }
            _ = try localLoanRate(annual)
            var result = before, custom: Int64 = 0, previousMode = "", previousPayment: Int64 = -1
            for (i, row) in old.enumerated() {
                if row["customPayment"] as? Bool != true { custom = 0 }
                else if try custom == 0 || cents(row["remaining"]) > 0 { custom = try cents(row["principal"]) + cents(row["interest"]) }
                if i < start { continue }
                let currentMode = row["customPayment"] as? Bool == true ? "fixed" : "auto"
                var currentRows = result["schedule"] as! [[String: Any]]
                if try cents(currentRows[i]["principal"]) + cents(currentRows[i]["remaining"]) == 0 {
                    currentRows[i]["annualRate"] = annual; currentRows[i]["customPayment"] = currentMode == "fixed"; result["schedule"] = currentRows; continue
                }
                if i == start || currentMode != previousMode || (currentMode == "fixed" && custom != previousPayment) {
                    var segment: [String: Any] = ["revision": id(account, "loanRevision"), "fromPeriod": i + 1, "annualRate": annual, "paymentMode": currentMode]
                    if currentMode == "fixed" { segment["payment"] = money(custom) }
                    result = try adjustLocalLoan(account, before: result, input: segment)
                }
                previousMode = currentMode; previousPayment = custom
            }
            return try summarizeLocalLoan(account, schedule: result["schedule"] as! [[String: Any]])
        }
        guard kind.isEmpty, scope.isEmpty, ["auto", "fixed"].contains(mode), mode == "auto" ? payment == nil : (payment ?? 0) > 0 else { throw failure("贷款调整方式无效") }
        let rate = try localLoanRate(annual)
        var terms = account
        terms["loanPrincipal"] = money(opening); terms["loanAnnualRate"] = annual; terms["loanPeriods"] = old.count - start; terms["loanPaidPeriods"] = 0
        let suffix = try buildLocalLoan(terms)
        var suffixRows = suffix["schedule"] as! [[String: Any]], remaining = opening
        for i in suffixRows.indices {
            var row = suffixRows[i]
            row["period"] = start + i + 1; row["date"] = old[start + i]["date"]
            if mode == "fixed" || account["loanMethod"] as? String == "equal_principal" {
                let interest = try localLoanInterest(remaining, rate: rate)
                var principal: Int64
                if mode == "fixed" {
                    guard let payment, payment <= 100_000_000_000_000, remaining == 0 || payment > interest else { throw failure("每期本息须大于当期利息") }
                    principal = payment - interest; row["customPayment"] = true
                } else { principal = try cents(old[start + i]["principal"]) }
                if principal > remaining || i == suffixRows.count - 1 { principal = remaining }
                remaining -= principal
                row["principal"] = money(principal); row["interest"] = money(interest); row["remaining"] = money(remaining); row["payment"] = money(principal + interest)
            }
            let original = old[start + i]
            if original["paymentOverridden"] as? Bool == true {
                row["payment"] = original["payment"]; row["paymentOverridden"] = true
                if original["interestCalibrated"] as? Bool == true {
                    let interest = try cents(row["payment"]) - cents(row["principal"])
                    guard interest >= 0 else { throw failure("调整后本金超过已校准账单金额") }
                    row["interest"] = money(interest); row["interestCalibrated"] = true
                }
            }
            suffixRows[i] = row
        }
        return try summarizeLocalLoan(account, schedule: Array(old.prefix(start)) + suffixRows)
    }

    /// 执行贷款试算或调整；参数：path/method/body 为请求、space 为账本副本；返回值：完整计划；试算不写入，保存只改计划快照及版本，不动真实余额或流水。
    static func applyLocalLoan(_ path: String, method: String, body: [String: Any], space: inout [String: Any]) throws -> Any {
        if path == "/finance/loan-preview" {
            let keys: Set<String> = ["loanPrincipal", "loanAnnualRate", "loanMethod", "loanPeriods", "loanPaidPeriods", "loanFirstPaymentDate", "loanLender", "loanReceivingAccountId"]
            guard Set(body.keys).isSubset(of: keys) else { throw failure("贷款试算字段无效") }
            return try buildLocalLoan(body)
        }
        let parts = path.split(separator: "/"), target = Int(parts[2]) ?? 0
        var accounts = space["accounts"] as? [[String: Any]] ?? []
        guard let index = accounts.firstIndex(where: { id($0) == target && $0["archived"] as? Bool != true && $0["selectable"] as? Bool != false }), accounts[index]["institution"] as? String == "贷款" else { throw failure("贷款账户不可用") }
        let before = try localLoanPlan(accounts[index])
        var plan = try adjustLocalLoan(accounts[index], before: before, input: body)
        if path.hasSuffix("-preview") { return plan }
        let revision = id(accounts[index], "loanRevision") + 1
        plan["revision"] = revision; accounts[index]["loanRevision"] = revision; accounts[index]["loanPlan"] = plan; accounts[index]["loanPlanLocked"] = true
        space["accounts"] = accounts
        return plan
    }

    /// 校验并合并账户贷款资料；参数：previous 为旧账户或 nil，row 为已合并普通及贷款字段的账户，body 为实际提交字段，space 为引用账本；返回值：无；更新 row 的权威计划与版本，失败抛错，不改其他账户及余额。
    static func updateLocalLoanAccount(previous: [String: Any]?, row: inout [String: Any], body: [String: Any], space: [String: Any]) throws {
        let loanKeys = body.keys.filter { $0.hasPrefix("loan") }
        try validatePlanIntegers(body, keys: ["loanPeriods", "loanPaidPeriods", "loanReceivingAccountId"])
        for key in ["loanPeriods", "loanPaidPeriods"] { if body[key] != nil, !(0...480).contains(id(body, key)) { throw failure("贷款期数须在0至480之间") } }
        if id(body, "loanReceivingAccountId") < 0 { throw failure("收款账户编号无效") }
        for key in ["loanAnnualRate", "loanMethod", "loanFirstPaymentDate", "loanLender"] {
            if let value = body[key] { guard let text = value as? String, text.utf8.count <= 128 else { throw failure("贷款文本字段无效") } }
        }
        if let rate = body["loanAnnualRate"] as? String, !rate.isEmpty { _ = try localLoanRate(rate) }
        if let method = body["loanMethod"] as? String, !["", "annuity", "equal_principal", "interest_only"].contains(method) { throw failure("还款方式无效") }
        if let date = body["loanFirstPaymentDate"] as? String, !date.isEmpty { _ = try planDate(date) }
        if let previous, (try cents(previous["loanPrincipal"] ?? "0.00")) > 0,
           id(previous, "loanPaidPeriods") > 0 || previous["loanPlanLocked"] as? Bool == true {
            for key in ["loanPrincipal", "loanAnnualRate", "loanMethod", "loanPeriods", "loanFirstPaymentDate"] where body[key] != nil {
                guard NSObjectEqual(previous[key], row[key]) else { throw failure("已有还款历史，请从贷款计划调整利率与金额") }
            }
            row["loanPlan"] = try localLoanPlan(previous); row["loanPlanLocked"] = true
        }
        if previous != nil, previous?["institution"] as? String == "贷款", body["currentDebt"] != nil,
           (try cents(previous?["balance"])) != (try cents(row["balance"])) {
            guard !(space["transactions"] as? [[String: Any]] ?? []).contains(where: { $0["status"] as? String == "pending" && (id($0, "accountId") == id(row) || id($0, "targetAccountId") == id(row)) }) else { throw failure("请先处理贷款待确认流水") }
        }
        if row["institution"] as? String == "贷款", body["balance"] != nil || body["currentDebt"] != nil { guard try cents(row["balance"]) <= 0 else { throw failure("贷款剩余本金不能为负数") } }
        if loanKeys.isEmpty && previous != nil { return }
        if !loanKeys.isEmpty { row["loanRevision"] = id(previous ?? [:], "loanRevision") + 1 }
        let receiving = id(row, "loanReceivingAccountId")
        if receiving != 0 {
            guard receiving != id(row), (space["accounts"] as? [[String: Any]] ?? []).contains(where: { id($0) == receiving && $0["archived"] as? Bool != true && $0["selectable"] as? Bool != false }) else { throw failure("贷款收款账户不可用") }
        }
        let principal = try cents(row["loanPrincipal"] ?? "0.00")
        guard principal >= 0 else { throw failure("贷款本金不能为负") }
        if principal == 0 {
            guard id(row, "loanPeriods") == 0, id(row, "loanPaidPeriods") == 0, (row["loanAnnualRate"] as? String ?? "").isEmpty, (row["loanMethod"] as? String ?? "").isEmpty, (row["loanFirstPaymentDate"] as? String ?? "").isEmpty, previous != nil || row["institution"] as? String != "贷款" else { throw failure("请填写完整贷款计划") }
            return
        }
        // 无历史快照时允许编辑合同；锁定后必须保留完整快照，仅重算已还期数对应的展示摘要。
        let plan = row["loanPlanLocked"] as? Bool == true ? try localLoanPlan(row) : try buildLocalLoan(row)
        row["loanPlan"] = plan
        row["loanPlanLocked"] = row["loanPlanLocked"] as? Bool == true || id(row, "loanPaidPeriods") > 0
        if previous == nil && body["balance"] == nil && body["currentDebt"] == nil { row["balance"] = money(-(try cents(plan["remainingPrincipal"]))); row["availableBalance"] = row["balance"] }
        if row["institution"] as? String == "贷款", body["balance"] != nil || body["currentDebt"] != nil { guard try cents(row["balance"]) <= 0 else { throw failure("贷款剩余本金不能为负数") } }
    }
}
