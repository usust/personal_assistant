import Foundation

extension FinanceLocalStore {
    /// 查询完整本地账本；参数：path 为固定财务路径，query 为列表筛选；返回值：可直接编码的结果，nil 表示需要专用联网能力，失败抛错。
    func readLocal(_ path: String, query: [URLQueryItem]) throws -> Any? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let table = parts[1], target = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        var filters: [String: String] = [:]
        for item in query { filters[item.name] = item.value }
        switch table {
        case "accounts":
            if parts.count == 2 { return rows(table).filter { $0["archived"] as? Bool != true } }
            if parts.last == "impact" {
                let related = rows("transactions").filter { Self.id($0, "accountId") == target || Self.id($0, "targetAccountId") == target }
                return ["transactions": related.count, "snapshots": 0, "pending": related.filter { $0["status"] as? String == "pending" }.count]
            }
            if parts.last == "loan-plan", let account = rows("accounts").first(where: { Self.id($0) == target }), let plan = account["loanPlan"], !(plan is NSNull) { return plan }
            if parts.last == "statement" || parts.last == "statements" { return try statement(target, summary: parts.last == "statement", filters: filters) }
        case "categories", "presets": return rows(table)
        case "transactions":
            if parts.count == 2 { return try transactions(filters, paginated: true) }
            if parts.count == 3 { guard let row = rows(table).first(where: { Self.id($0) == target && $0["status"] as? String != "deleted" }) else { throw Self.failure("流水不存在") }; return row }
            if parts.last == "installment", let plans = space["plans"] as? [String: Any] { return plans[String(target)] }
        case "transactions-summary": return try summary(filters)
        case "overview": return try overview()
        case "installments":
            let list = space["installments"] as? [[String: Any]] ?? []
            if let id = filters["accountId"].flatMap(Int.init) { return list.filter { Self.id($0["bill"] as? [String: Any] ?? [:], "accountId") == id } }
            return list
        default: break
        }
        return nil
    }

    /// 本地筛选和分页；参数：filters 为现有接口字段，paginated 决定是否截取；返回值：交易日期、时分及 ID 倒序的匹配流水，不将未来分期待入账项混入列表。
    func transactions(_ filters: [String: String], paginated: Bool) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        // 列表纳入待补全截图；统计调用不纳入这些投影，避免把未知金额当零或提前计入余额。
        let candidates = rows("transactions") + (paginated ? try incompleteScreenshotTransactions() : [])
        for row in candidates {
            let status = row["status"] as? String ?? "", date = row["transactionDate"] as? String ?? ""
            if status == "deleted" || (status == "pending" && Self.id(row, "installmentParentId") != 0) { continue }
            if let start = filters["startDate"], !start.isEmpty, date < start { continue }
            if let end = filters["endDate"], !end.isEmpty, date > end { continue }
            if let kind = filters["type"], !kind.isEmpty, row["type"] as? String != kind { continue }
            if let wanted = filters["status"], !wanted.isEmpty, status != wanted { continue }
            if let account = filters["accountId"].flatMap(Int.init), Self.id(row, "accountId") != account, Self.id(row, "targetAccountId") != account { continue }
            if let category = filters["categoryId"].flatMap(Int.init), Self.id(row, "categoryId") != category { continue }
            let amount = row["status"] as? String == "incomplete" ? (try? Self.cents(row["amount"])) ?? 0 : try Self.cents(row["amount"])
            if let min = filters["minAmount"], !min.isEmpty, amount < (try Self.cents(min)) { continue }
            if let max = filters["maxAmount"], !max.isEmpty, amount > (try Self.cents(max)) { continue }
            if let keyword = filters["keyword"], !keyword.isEmpty, !(row["counterparty"] as? String ?? "").localizedCaseInsensitiveContains(keyword), !(row["description"] as? String ?? "").localizedCaseInsensitiveContains(keyword) { continue }
            result.append(row)
        }
        // 比较器输入两笔流水；返回交易日期、时分及 ID 的倒序关系；缺失时间排在当天已知时间之后，分页前排序。
        result.sort { left, right in
            let a = left["transactionDate"] as? String ?? "", b = right["transactionDate"] as? String ?? ""
            if a != b { return a > b }
            let leftTime = left["transactionTime"] as? String ?? "", rightTime = right["transactionTime"] as? String ?? ""
            return leftTime == rightTime ? Self.id(left) > Self.id(right) : leftTime > rightTime
        }
        guard paginated else { return result }
        let offset = max(0, Int(filters["offset"] ?? "0") ?? 0), limit = min(500, max(1, Int(filters["limit"] ?? "100") ?? 100))
        return Array(result.dropFirst(offset).prefix(limit))
    }
    /// 以 Decimal 汇总完整范围，避免多账户聚合溢出；参数：filters 为日期范围；返回值：两位小数字符串的收入、支出和结余，无写入。
    func summary(_ filters: [String: String]) throws -> [String: String] {
        var income = Decimal.zero, expense = Decimal.zero
        for row in try transactions(filters, paginated: false) where row["status"] as? String == "posted" {
            let amount = Decimal(try Self.cents(row["amount"]))
            if row["type"] as? String == "income" { income += amount }
            if row["type"] as? String == "expense" { expense += amount }
            expense += Decimal(try Self.cents(row["fee"] ?? "0.00"))
        }
        return ["income": Self.decimalMoney(income), "expense": Self.decimalMoney(expense), "balance": Self.decimalMoney(income - expense)]
    }
    /// 格式化累计分金额；参数：value 为精确 Decimal 分；返回值：两位小数字符串，无浮点舍入。
    static func decimalMoney(_ value: Decimal) -> String {
        let raw = NSDecimalNumber(decimal: value / 100).stringValue
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        return String(parts[0]) + "." + (parts.count > 1 ? String((String(parts[1]) + "00").prefix(2)) : "00")
    }
    /// 生成首页资产及六个月汇总；参数：无；返回值：与现有模型兼容的统计，余额含待同步本机操作。
    func overview() throws -> [String: Any] {
        var assets = Decimal.zero, liabilities = Decimal.zero
        var structure: [[String: Any]] = []
        let accounts = rows("accounts").filter { $0["archived"] as? Bool != true }
        for account in accounts where account["includeInNetWorth"] as? Bool != false {
            var balance = Decimal(try Self.cents(account["balance"]))
            if account["institution"] as? String == "贷款", let plan = account["loanPlan"] as? [String: Any], let remaining = plan["remainingTotal"] { balance = -Decimal(try Self.cents(remaining)) }
            if balance >= 0 { assets += balance; if balance > 0 { structure.append(["name": account["name"] ?? "", "amount": Self.decimalMoney(balance)]) } } else { liabilities -= balance }
        }
        let month = FinanceMonth.current()
        var flows: [[String: Any]] = []
        for offset in -5...0 {
            let period = month.shifted(offset), sums = try summary(["startDate": month.shifted(offset).start, "endDate": month.shifted(offset).end])
            flows.append(["month": period.id, "income": sums["income"]!, "expense": sums["expense"]!, "net": sums["balance"]!])
        }
        let sums = try summary(["startDate": month.start, "endDate": month.end])
        var categories: [String: Decimal] = [:]
        for row in try transactions(["startDate": month.start, "endDate": month.end], paginated: false) where row["status"] as? String == "posted" {
            if row["type"] as? String == "expense" {
                let name = rows("categories").first(where: { Self.id($0) == Self.id(row, "categoryId") })?["name"] as? String ?? "未分类"
                categories[name, default: 0] += Decimal(try Self.cents(row["amount"]))
            }
            let fee = try Self.cents(row["fee"] ?? "0.00")
            if fee != 0 { categories["转账手续费", default: 0] += Decimal(fee) }
        }
        return ["totalAssets": Self.decimalMoney(assets), "totalLiabilities": Self.decimalMoney(liabilities), "netWorth": Self.decimalMoney(assets-liabilities), "monthIncome": sums["income"]!, "monthExpense": sums["expense"]!, "monthBalance": sums["balance"]!, "accountCount": accounts.count, "assetStructure": structure, "cashFlow": flows, "expenseCategories": categories.sorted { $0.value > $1.value }.map { ["name": $0.key, "amount": Self.decimalMoney($0.value)] }]
    }

    /// 计算本地信用账期；参数：accountID 为账户，summary 表示最近应还或历史账单，filters 为历史范围；返回值：原接口兼容结果，未来分期预记本金从计划扣除，非法账户抛错。
    func statement(_ accountID: Int, summary: Bool, filters: [String: String]) throws -> Any {
        guard let account = rows("accounts").first(where: { Self.id($0) == accountID }) else { throw Self.failure("账户不存在") }
        let day = Self.id(account, "billingDay"), inclusive = account["billDayInclusive"] as? Bool ?? true
        guard (1...31).contains(day) else { return summary ? ["configured": false, "month": "", "startDate": "", "endDate": "", "remainingAmount": "0.00"] as [String: Any] : [:] as [String: String] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 28800)!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: .now)
        let current = FinanceMonth.current()
        let related = rows("transactions").filter { Self.id($0, "accountId") == accountID || Self.id($0, "targetAccountId") == accountID }
        var pendingPrincipal: Int64 = 0
        let plans = space["plans"] as? [String: [String: Any]] ?? [:]
        for row in related where row["status"] as? String == "pending" && Self.id(row, "installmentParentId") != 0 {
            if let plan = plans[String(Self.id(row, "installmentParentId"))], plan["debtMode"] as? String == "upfront", let periods = plan["rows"] as? [[String: Any]], let period = periods.first(where: { Self.id($0, "period") == Self.id(row, "installmentPeriod") }) { pendingPrincipal += try Self.cents(period["principal"]) }
        }
        // 日期闭包输入自然月，返回本月账单截止日；短月按月末截断，未含当天时前移一天。
        let closing: (FinanceMonth) -> Date = { month in
            let first = formatter.date(from: month.start)!
            let capped = min(day, calendar.range(of: .day, in: .month, for: first)!.count)
            return calendar.date(byAdding: .day, value: capped - 1 - (inclusive ? 0 : 1), to: first)!
        }
        let balance = try Self.cents(account["balance"])
        if summary {
            let month = formatter.string(from: closing(current)) >= today ? current.shifted(-1) : current
            let end = formatter.string(from: closing(month))
            let start = formatter.string(from: calendar.date(byAdding: .day, value: 1, to: closing(month.shifted(-1)))!)
            var unbilled: Int64 = 0
            for row in related where Self.id(row, "accountId") == accountID && row["status"] as? String == "posted" && (row["transactionDate"] as? String ?? "") > end {
                if Self.id(row, "refundParentId") != 0 {
                    if let parent = related.first(where: { Self.id($0) == Self.id(row, "refundParentId") }), (parent["transactionDate"] as? String ?? "") > end { unbilled += try Self.cents(row["amount"]) }
                } else if row["type"] as? String == "expense" || row["type"] as? String == "transfer" { unbilled += try Self.cents(row["amount"]) }
                unbilled += try Self.cents(row["fee"] ?? "0.00")
            }
            return ["configured": true, "month": month.id, "startDate": start, "endDate": end, "remainingAmount": Self.money(max(0, -balance - max(0, unbilled) - pendingPrincipal))]
        }
        guard let start = filters["startDate"], let end = filters["endDate"], let first = formatter.date(from: start), let last = formatter.date(from: end), first <= last else { throw Self.failure("账期范围无效") }
        var month = FinanceMonth.current(first), result: [String: String] = [:]
        let lastMonth = FinanceMonth.current(last).shifted(1)
        guard lastMonth.year - month.year <= 100 else { throw Self.failure("账期范围过大") }
        while month.id <= lastMonth.id {
            let key = formatter.string(from: closing(month)); month = month.shifted(1)
            if key < start || key > end || key >= today { continue }
            var amount = -balance - pendingPrincipal
            for row in related where row["status"] as? String == "posted" && (row["transactionDate"] as? String ?? "") > key {
                let value = try Self.cents(row["amount"])
                if Self.id(row, "accountId") == accountID { amount += row["type"] as? String == "income" ? value : -value; amount -= try Self.cents(row["fee"] ?? "0.00") }
                if Self.id(row, "targetAccountId") == accountID { amount += value }
            }
            result[key] = Self.money(max(0, amount))
        }
        return result
    }
}
