import Foundation

extension FinanceLocalStore {
    /// 识别本机复杂计划端点；参数：path 为完整财务路径，method 为 HTTP 方法；返回值：是否由计划执行器负责，不修改账本。
    static func supportsLocalPlan(_ path: String, method: String) -> Bool {
        let p = path.split(separator: "/").map(String.init)
        if path == "/finance/recurring/materialize" { return method == "POST" }
        if p.count == 4, p[1] == "transactions", Int(p[2]) != nil, ["installment", "installment-preview"].contains(p[3]) { return method == "POST" }
        if p.count >= 3, p[1] == "installments", Int(p[2]) != nil {
            return p.count == 3 && ["PATCH", "DELETE"].contains(method) || p.count == 4 && p[3] == "finish" && method == "POST"
        }
        return false
    }

    /// 阻止不能可靠映射子记录身份的上传；参数：command 为本机队列命令；返回值：无；抛错时同步器必须保留队列及本机账本，禁止下载快照覆盖。
    static func validatePlanSync(_ command: [String: Any]) throws {
        let path = command["path"] as? String ?? "", method = command["method"] as? String ?? ""
        if supportsLocalLoan(path, method: method) && path.hasSuffix("loan-adjustments") {
            throw failure("贷款调整的完整本机计划尚未建立安全同步映射；请保留本机数据，不能以仅含摘要的云端快照覆盖")
        }
        if supportsLocalPlan(path, method: method) && !path.hasSuffix("installment-preview") {
            throw failure("此计划含本机生成或调整的关联记录，尚不能安全映射服务器编号；请保留本机数据，不能以云端快照覆盖")
        }
    }

    /// 返回 UTC+8 业务日；参数：now 为当前时间，默认真实时钟；返回值：yyyy-MM-dd，无副作用。
    nonisolated static func planToday(_ now: Date = .now) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 28800); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    /// 严格解析计划日期；参数：raw 为 yyyy-MM-dd；返回值：UTC 日期；无效或越界日期抛错，无副作用。
    static func planDate(_ raw: String) throws -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil, let date = f.date(from: raw), f.string(from: date) == raw, !raw.hasPrefix("0000") else { throw failure("计划日期无效") }
        return date
    }

    /// 按原日号计算月偏移；参数：anchor 为首期日期，months 为非负月数；返回值：短月截断、后续恢复日号的日期；越界抛错，不改输入。
    static func planMonth(_ anchor: String, months: Int) throws -> String {
        let date = try planDate(anchor)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = c.dateComponents([.year, .month, .day], from: date)
        let first = c.date(from: DateComponents(year: components.year, month: components.month, day: 1))!
        guard let month = c.date(byAdding: .month, value: months, to: first), c.component(.year, from: month) <= 9999 else { throw failure("计划日期超出范围") }
        let day = min(components.day!, c.range(of: .day, in: .month, for: month)!.count)
        let value = c.date(byAdding: .day, value: day - 1, to: month)!
        let f = DateFormatter(); f.calendar = c; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: value)
    }

    /// 计算周期下一日并保持月日锚点；参数：date 为当前日、start 为原始首日、frequency 为四种周期；返回值：下一日；无效周期或日期抛错，无副作用。
    static func nextLocalOccurrence(_ date: String, start: String, frequency: String) throws -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let current = try planDate(date), anchor = try planDate(start)
        if frequency == "monthly" || frequency == "yearly" {
            let a = c.dateComponents([.year, .month], from: anchor), d = c.dateComponents([.year, .month], from: current)
            let months = frequency == "yearly" ? (d.year! - a.year! + 1) * 12 : (d.year! - a.year!) * 12 + d.month! - a.month! + 1
            return try planMonth(start, months: months)
        }
        guard ["daily", "weekly"].contains(frequency), let next = c.date(byAdding: .day, value: frequency == "daily" ? 1 : 7, to: current), c.component(.year, from: next) <= 9999 else { throw failure("周期无效或日期超出范围") }
        let f = DateFormatter(); f.calendar = c; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: next)
    }

    /// 校验 JSON 整数字段；参数：row 为请求，keys 为需检查的字段名；返回值：无；拒绝布尔、字符串、null、分数和超安全编号范围，缺省字段由业务自行处理，无副作用。
    static func validatePlanIntegers(_ row: [String: Any], keys: [String]) throws {
        for key in keys {
            guard let value = row[key] else { continue }
            guard let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite,
                  abs(number.doubleValue) <= 9_000_000_000_000_000, number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw failure("\(key) 必须为整数") }
        }
    }

    /// 精确分摊整数分；参数：total 为非负分，periods 为 2 至 480，rounding/remainder 为已知规则；返回值：金额守恒的各期分值；负尾差抛错，无副作用。
    static func splitLocalInstallment(_ total: Int64, periods: Int, rounding: String, remainder: String) throws -> [Int64] {
        guard total >= 0, (2...480).contains(periods), ["round", "floor"].contains(rounding), ["first", "last"].contains(remainder) else { throw failure("分期拆分规则无效") }
        let n = Int64(periods)
        let base = total / n + (rounding == "round" && total % n * 2 >= n ? 1 : 0)
        var rows = Array(repeating: base, count: periods)
        let index = remainder == "first" ? 0 : periods - 1
        rows[index] += total - base * n
        guard rows[index] >= 0 else { throw failure("金额过小，请减少期数或选择向下取整") }
        return rows
    }

    /// 试算消费分期；参数：principal 为正数分，terms 为白名单规则；返回值：与服务端兼容的完整计划；失败抛错，不修改账本。
    static func calculateLocalInstallment(principal: Int64, terms: [String: Any]) throws -> [String: Any] {
        let allowed: Set<String> = ["name", "periods", "firstDate", "startPeriod", "restoredCredit", "debtMode", "interest", "interestMode", "interestCreditMode", "rounding", "remainder", "description", "categoryId", "reimbursementStatus"]
        guard Set(terms.keys).isSubset(of: allowed), terms.allSatisfy({ $0.key == "categoryId" || !($0.value is NSNull) }),
              let name = terms["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              let first = terms["firstDate"] as? String, let rounding = terms["rounding"] as? String, let remainder = terms["remainder"] as? String,
              let interestMode = terms["interestMode"] as? String, ["spread", "first"].contains(interestMode),
              ["", "spread", "upfront"].contains(terms["debtMode"] as? String ?? ""), ["", "spread", "upfront"].contains(terms["interestCreditMode"] as? String ?? "") else { throw failure("分期规则无效") }
        _ = try planDate(first)
        try validatePlanIntegers(terms, keys: ["periods", "startPeriod"])
        if terms["categoryId"] != nil && !(terms["categoryId"] is NSNull) { try validatePlanIntegers(terms, keys: ["categoryId"]) }
        let periods = id(terms, "periods"), start = id(terms, "startPeriod") == 0 ? 1 : id(terms, "startPeriod")
        let interest = try cents(terms["interest"] ?? "0.00"), restored = try cents(terms["restoredCredit"] ?? "0.00")
        guard principal > 0, interest >= 0, principal + interest <= 100_000_000_000_000, (2...480).contains(periods), (1...periods).contains(start), restored >= 0 else { throw failure("本金、利息或期数无效") }
        if let status = terms["reimbursementStatus"] { try validateReimbursement(["type": "expense", "amount": money(principal), "reimbursementStatus": status]) }
        if let description = terms["description"] { guard let text = description as? String, text.utf8.count <= 2000 else { throw failure("备注无效") } }
        let principals = try splitLocalInstallment(principal, periods: periods, rounding: rounding, remainder: remainder)
        var interests = Array(repeating: Int64(0), count: periods)
        if interestMode == "first" { interests[0] = interest } else { interests = try splitLocalInstallment(interest, periods: periods, rounding: rounding, remainder: remainder) }
        var rows: [[String: Any]] = [], total: Int64 = 0, generated: Int64 = 0
        for i in (start - 1)..<periods {
            let amount = principals[i] + interests[i]
            guard amount > 0 else { throw failure("每期金额须大于零") }
            rows.append(["period": i + 1, "date": try planMonth(first, months: i), "principal": money(principals[i]), "interest": money(interests[i]), "amount": money(amount), "transactionId": 0, "status": "pending"])
            total += amount; generated += principals[i]
        }
        guard restored <= generated else { throw failure("额度恢复不能超过待生成本金") }
        var result = terms
        result["principal"] = money(principal); result["total"] = money(total); result["rows"] = rows; result["posted"] = 0
        result["interest"] = money(interest); result["restoredCredit"] = money(restored)
        return result
    }

    /// 读取实时分期计划；参数：parent 为主流水 ID，space 为只读账本；返回值：含子项状态、日期及已入账数量的计划；缺失明细抛错，不伪造空计划。
    static func localInstallment(_ parent: Int, space: [String: Any]) throws -> [String: Any] {
        guard var plan = (space["plans"] as? [String: [String: Any]])?[String(parent)], var periods = plan["rows"] as? [[String: Any]] else { throw failure("本机缺少完整分期计划，请保留本机数据") }
        let records = space["transactions"] as? [[String: Any]] ?? []
        var posted = 0
        for i in periods.indices {
            guard let child = records.first(where: { id($0, "installmentParentId") == parent && id($0, "installmentPeriod") == id(periods[i], "period") }) else { throw failure("本机缺少分期子记录，请保留本机数据") }
            periods[i]["transactionId"] = id(child); periods[i]["status"] = child["status"]; periods[i]["date"] = child["transactionDate"]
            if child["status"] as? String == "posted" { posted += 1 }
        }
        plan["rows"] = periods; plan["posted"] = posted
        return plan
    }

    /// 读取复杂计划查询；参数：path 为分期详情或列表端点，query 为可选账户筛选；返回值：结果或 nil 表示非本执行器端点；缺失本机计划抛错，无写入。
    func readLocalPlan(_ path: String, query: [URLQueryItem]) throws -> Any? {
        let p = path.split(separator: "/").map(String.init)
        if p.count == 4, p[1] == "transactions", p[3] == "installment", let parent = Int(p[2]) { return try Self.localInstallment(parent, space: space) }
        guard path == "/finance/installments" else { return nil }
        let account = query.first(where: { $0.name == "accountId" })?.value.flatMap(Int.init)
        var result: [[String: Any]] = []
        for bill in rows("transactions").filter({ $0["status"] as? String == "installment" && (account == nil || Self.id($0, "accountId") == account) }).sorted(by: { Self.id($0) > Self.id($1) }) {
            let plan = try Self.localInstallment(Self.id(bill), space: space)
            var pending: Int64 = 0, interest: Int64 = 0, next = ""
            for row in plan["rows"] as? [[String: Any]] ?? [] where row["status"] as? String == "pending" {
                pending += try Self.cents(row["amount"]); interest += try Self.cents(row["interest"])
                let date = row["date"] as? String ?? ""
                if next.isEmpty || date < next { next = date }
            }
            result.append(["bill": bill, "plan": plan, "pendingAmount": Self.money(pending), "pendingInterest": Self.money(interest), "nextDate": next])
        }
        return result
    }

    /// 重算分期账户展示投影；参数：space 为含完整计划和子流水的账本；返回值：附加待入账本息、专项额度及预留利息的账户，不改变余额或输入；不完整计划抛错。
    static func localPlanAccounts(space: [String: Any]) throws -> [[String: Any]] {
        var accounts = space["accounts"] as? [[String: Any]] ?? []
        var totals: [Int: [Int64]] = [:]
        for bill in space["transactions"] as? [[String: Any]] ?? [] where bill["status"] as? String == "installment" {
            let plan = try localInstallment(id(bill), space: space)
            var restored = try cents(plan["restoredCredit"] ?? "0.00"), pending: Int64 = 0, interest: Int64 = 0, reserved: Int64 = 0
            for period in plan["rows"] as? [[String: Any]] ?? [] {
                let status = period["status"] as? String ?? ""
                if ["posted", "deleted"].contains(status) { restored = max(0, restored - (try cents(period["principal"]))) }
                else if status == "pending" {
                    pending += try cents(period["amount"]); interest += try cents(period["interest"])
                    if plan["interestCreditMode"] as? String == "upfront" { reserved += try cents(period["interest"]) }
                }
            }
            let account = id(bill, "accountId"), prior = totals[account] ?? [0, 0, 0, 0]
            totals[account] = zip(prior, [pending, interest, restored, reserved]).map(+)
        }
        for i in accounts.indices {
            let values = totals[id(accounts[i])] ?? [0, 0, 0, 0]
            guard values.allSatisfy({ $0 <= 100_000_000_000_000 }) else { throw failure("分期汇总金额超出上限") }
            for (key, value) in zip(["installmentPendingAmount", "installmentPendingInterest", "installmentCredit", "installmentInterestReserved"], values) { accounts[i][key] = money(value) }
        }
        return accounts
    }

    /// 在账本副本执行计划命令；参数：path/method/body 为已识别请求，newID 为新编号起点，space 为可变副本，today 为可注入业务日；返回值：业务结果；错误时调用方必须弃置副本，不联网。
    static func applyLocalPlan(_ path: String, method: String, body: [String: Any], newID: Int, space: inout [String: Any], today: String = planToday()) throws -> Any {
        _ = try planDate(today)
        if path == "/finance/recurring/materialize" {
            guard body.isEmpty else { throw failure("周期补齐不接受字段") }
            try materializeLocalPresets(space: &space, newID: newID, today: today)
            try postDueLocalInstallments(space: &space, today: today)
            return NSNull()
        }
        let p = path.split(separator: "/").map(String.init)
        guard p.count >= 3, let parent = Int(p[2]) else { throw failure("分期路径无效") }
        var records = space["transactions"] as? [[String: Any]] ?? []
        guard let index = records.firstIndex(where: { id($0) == parent }) else { throw failure("分期主流水不存在") }
        var bill = records[index]
        var plans = space["plans"] as? [String: [String: Any]] ?? [:]
        if p[1] == "transactions" {
            if let saved = plans[String(parent)], p.last == "installment", let input = saved["localTerms"] as? [String: Any] {
                guard NSDictionary(dictionary: input).isEqual(to: body) else { throw failure("分期规则冲突") }
                return try localInstallment(parent, space: space)
            }
            var plan = try calculateLocalInstallment(principal: cents(bill["amount"]), terms: body)
            if p.last == "installment-preview", bill["status"] as? String == "installment" { return plan }
            guard bill["type"] as? String == "expense", bill["status"] as? String == "posted", id(bill, "installmentParentId") == 0, id(bill, "refundParentId") == 0,
                  !records.contains(where: { id($0, "refundParentId") == parent && $0["status"] as? String != "deleted" && $0["status"] as? String != "voided" }) else { throw failure("仅普通未退款支出可以转分期") }
            for key in ["categoryId", "description", "reimbursementStatus"] { if let value = body[key] { bill[key] = value } }
            try validateTransaction(bill, space: space)
            if p.last == "installment-preview" { return plan }
            try adjustBalances(bill, direction: -1, space: &space)
            var periods = plan["rows"] as! [[String: Any]]
            var principal: Int64 = 0
            for i in periods.indices {
                let number = id(periods[i], "period"), childID = newID + i
                let child: [String: Any] = ["id": childID, "requestId": "installment_\(parent)_\(number)", "installmentParentId": parent, "installmentPeriod": number,
                    "accountId": id(bill, "accountId"), "type": "expense", "amount": periods[i]["amount"]!, "fee": "0.00", "discount": "0.00", "categoryId": bill["categoryId"] ?? NSNull(), "counterparty": bill["counterparty"] ?? "", "description": body["description"] ?? ((bill["description"] as? String ?? "").isEmpty ? "\(body["name"]!) · \(number)/\(id(body, "periods"))" : bill["description"]!), "reimbursementStatus": bill["reimbursementStatus"] ?? "", "transactionDate": periods[i]["date"]!, "status": "pending", "source": "http"]
                records.append(child); periods[i]["transactionId"] = childID
                principal += try cents(periods[i]["principal"])
            }
            if body["debtMode"] as? String == "upfront" { try adjustBalances(["accountId": id(bill, "accountId"), "type": "expense", "amount": money(principal)], direction: 1, space: &space) }
            bill["status"] = "installment"; records[index] = bill
            plan["rows"] = periods; plan["localTerms"] = body; plans[String(parent)] = plan
            space["plans"] = plans; space["transactions"] = records
            // 与后端创建后补记到期分期一致，已过期各期在当前事务内只扣未预记部分。
            try postDueLocalInstallments(space: &space, today: today)
            return try localInstallment(parent, space: space)
        }
        guard let old = plans[String(parent)], bill["status"] as? String == "installment" || method == "DELETE" && bill["status"] as? String == "deleted" else { throw failure("不是有效分期计划") }
        if method == "PATCH" { return try updateLocalInstallment(parent, changes: body, old: old, newID: newID, space: &space, today: today) }
        guard body.isEmpty else { throw failure("分期操作不接受字段") }
        if method == "DELETE", bill["status"] as? String == "deleted" { return old }
        let children = records.filter { id($0, "installmentParentId") == parent }
        for child in children {
            let childID = id(child)
            if method == "DELETE", child["status"] as? String != "deleted" {
                _ = try apply("/finance/transactions/\(childID)", method: "DELETE", body: [:], newID: newID, space: &space)
            } else if p.last == "finish", child["status"] as? String == "pending" {
                var current = space["transactions"] as! [[String: Any]]
                let childIndex = current.firstIndex(where: { id($0) == childID })!
                current[childIndex]["transactionDate"] = today; space["transactions"] = current
                _ = try apply("/finance/transactions/\(childID)/confirm", method: "POST", body: [:], newID: newID, space: &space)
            }
        }
        if method == "DELETE" {
            var current = space["transactions"] as! [[String: Any]]; current[index]["status"] = "deleted"; space["transactions"] = current
            return old
        }
        return try localInstallment(parent, space: space)
    }

    /// 更新分期规则及资料并按净差对账；参数：parent 为主单，changes 为非空白名单字段，old 为旧计划，newID 为编号起点，space 为副本，today 为业务日；返回值：实时计划；校验失败需回滚副本。
    static func updateLocalInstallment(_ parent: Int, changes: [String: Any], old: [String: Any], newID: Int, space: inout [String: Any], today: String) throws -> [String: Any] {
        guard !changes.isEmpty else { throw failure("至少提交一个分期字段") }
        let keys: Set<String> = ["name", "periods", "firstDate", "startPeriod", "restoredCredit", "debtMode", "interest", "interestMode", "interestCreditMode", "rounding", "remainder", "description", "categoryId", "reimbursementStatus"]
        guard Set(changes.keys).isSubset(of: keys) else { throw failure("分期字段无效") }
        var terms = old.filter { keys.contains($0.key) }
        for (key, value) in changes { terms[key] = value }
        var records = space["transactions"] as! [[String: Any]]
        let parentIndex = records.firstIndex(where: { id($0) == parent })!
        var bill = records[parentIndex]
        var next = try calculateLocalInstallment(principal: cents(bill["amount"]), terms: terms)
        let metadata: Set<String> = ["name", "categoryId", "description", "reimbursementStatus"]
        let financial = keys.subtracting(metadata).contains { key in !NSObjectEqual(old[key], terms[key]) }
        let originalCategory = id(bill, "categoryId")
        for key in ["categoryId", "description", "reimbursementStatus"] { if let value = changes[key] { bill[key] = value } }
        try validateCategory(bill, space: space, preservingCategoryID: originalCategory); try validateReimbursement(bill)
        var oldBooked: Int64 = 0, newBooked: Int64 = 0
        let oldRows = old["rows"] as! [[String: Any]]
        let children = records.filter { id($0, "installmentParentId") == parent }
        for child in children {
            if child["status"] as? String == "posted" { oldBooked += try cents(child["amount"]) + cents(child["fee"] ?? "0.00") }
            else if child["status"] as? String == "pending", old["debtMode"] as? String == "upfront" {
                guard let row = oldRows.first(where: { id($0, "period") == id(child, "installmentPeriod") }) else { throw failure("分期本金缺失") }
                oldBooked += try cents(row["principal"])
            }
        }
        if !financial {
            next = old
            for (key, value) in changes { next[key] = value }
            for i in records.indices where id(records[i], "installmentParentId") == parent && records[i]["status"] as? String == "pending" {
                for key in ["categoryId", "description", "reimbursementStatus"] { if let value = changes[key] { records[i][key] = value } }
            }
        } else {
            try validateTransaction(bill, space: space, preservingCategoryID: originalCategory)
            var periods = next["rows"] as! [[String: Any]], retained = Set<Int>(), sequence = newID
            for i in periods.indices {
                let period = id(periods[i], "period"); retained.insert(period)
                let existing = records.firstIndex(where: { id($0, "installmentParentId") == parent && id($0, "installmentPeriod") == period })
                var child = existing.map { records[$0] } ?? ["id": sequence, "accountId": id(bill, "accountId"), "type": "expense", "fee": "0.00", "categoryId": bill["categoryId"] ?? NSNull(), "counterparty": bill["counterparty"] ?? "", "description": bill["description"] ?? "", "reimbursementStatus": bill["reimbursementStatus"] ?? "", "installmentParentId": parent, "installmentPeriod": period, "requestId": "installment_\(parent)_\(period)", "source": "http"]
                if existing == nil { sequence += 1 }
                periods[i]["transactionId"] = id(child)
                if child["status"] as? String == "deleted", child["installmentEditRemoved"] as? Bool != true { periods[i]["status"] = "deleted"; continue }
                var date = periods[i]["date"] as! String, status = date <= today ? "posted" : "pending"
                if child["status"] as? String == "posted", old["firstDate"] as? String == next["firstDate"] as? String { date = child["transactionDate"] as! String; status = "posted" }
                var refunded: Int64 = 0
                for refund in records where id(refund, "refundParentId") == id(child) && refund["status"] as? String == "posted" {
                    refunded -= try cents(refund["amount"])
                    guard status == "posted", date <= refund["transactionDate"] as? String ?? "" else { throw failure("调整后的日期不能晚于退款") }
                }
                guard refunded <= (try cents(periods[i]["amount"])) else { throw failure("单期金额不能小于已退款金额") }
                if child["status"] as? String != "posted" { for key in ["categoryId", "description", "reimbursementStatus"] { if let value = changes[key] { child[key] = value } } }
                child["amount"] = periods[i]["amount"]; child["transactionDate"] = date; child["status"] = status; child["installmentEditRemoved"] = false
                periods[i]["date"] = date; periods[i]["status"] = status
                if status == "posted" { newBooked += try cents(child["amount"]) + cents(child["fee"] ?? "0.00") }
                else if next["debtMode"] as? String == "upfront" { newBooked += try cents(periods[i]["principal"]) }
                if let existing { records[existing] = child } else { records.append(child) }
            }
            for i in records.indices where id(records[i], "installmentParentId") == parent && !retained.contains(id(records[i], "installmentPeriod")) && records[i]["status"] as? String != "deleted" {
                guard !records.contains(where: { id($0, "refundParentId") == id(records[i]) && $0["status"] as? String == "posted" }) else { throw failure("已有退款的期次不能移出范围") }
                records[i]["status"] = "deleted"; records[i]["installmentEditRemoved"] = true
            }
            next["rows"] = periods
            try adjustBalances(["accountId": id(bill, "accountId"), "type": "expense", "amount": money(newBooked - oldBooked)], direction: 1, space: &space)
        }
        records[parentIndex] = bill; space["transactions"] = records
        var plans = space["plans"] as! [String: [String: Any]]; next["localTerms"] = terms; plans[String(parent)] = next; space["plans"] = plans
        try postDueLocalInstallments(space: &space, today: today)
        return try localInstallment(parent, space: space)
    }

    /// 比较 JSON 可选值；参数：left/right 为规则值或 nil；返回值：结构相等结果，无副作用。
    static func NSObjectEqual(_ left: Any?, _ right: Any?) -> Bool {
        if left == nil && right == nil { return true }
        guard let left = left as? NSObject, let right = right as? NSObject else { return false }
        return left == right
    }

    /// 原子补记到期分期；参数：space 为账本副本、today 为业务日；返回值：无；只处理 pending 子单，重复调用不重复扣款，缺失计划抛错。
    static func postDueLocalInstallments(space: inout [String: Any], today: String) throws {
        let due = (space["transactions"] as? [[String: Any]] ?? []).filter { id($0, "installmentParentId") != 0 && $0["status"] as? String == "pending" && ($0["transactionDate"] as? String ?? "") <= today }
        for child in due { _ = try apply("/finance/transactions/\(id(child))/confirm", method: "POST", body: [:], newID: 0, space: &space) }
    }

    /// 生成到期周期草稿；参数：space 为账本副本，newID 为编号起点，today 为 UTC+8 业务日；返回值：无；每模板最多120期，确定性键幂等，不改变余额；失效引用记录 lastError。
    static func materializeLocalPresets(space: inout [String: Any], newID: Int, today: String) throws {
        var presets = space["presets"] as? [[String: Any]] ?? [], sequence = newID
        for i in presets.indices {
            let frequency = presets[i]["frequency"] as? String ?? ""
            guard !frequency.isEmpty, presets[i]["enabled"] as? Bool != false, let start = presets[i]["startDate"] as? String, var next = presets[i]["nextDate"] as? String, !next.isEmpty, next <= today,
                  var input = presets[i]["transaction"] as? [String: Any] else { continue }
            let end = presets[i]["endDate"] as? String ?? ""
            input["transactionDate"] = next; input["requestId"] = "recurring_\(id(presets[i]))_\(next)"
            do {
                var validation = space
                _ = try apply("/finance/transactions", method: "POST", body: input, newID: sequence, space: &validation, draft: true)
            } catch {
                presets[i]["lastError"] = "账户或分类不可用，请删除计划后重新设置"; continue
            }
            for _ in 0..<120 {
                if next > today || !end.isEmpty && next > end { break }
                let key = "recurring_\(id(presets[i]))_\(next)"
                var transactions = space["transactions"] as? [[String: Any]] ?? []
                if !transactions.contains(where: { $0["requestId"] as? String == key }) {
                    input["requestId"] = key; input["transactionDate"] = next
                    // 复用普通写入校验，但丢弃其余额及返现副本；周期只存主草稿，确认时才真正入账和创建返现。
                    var validation = space
                    var row = try apply("/finance/transactions", method: "POST", body: input, newID: sequence, space: &validation, draft: true) as! [String: Any]
                    row["status"] = "pending"; row["source"] = "recurring"
                    transactions.append(row); space["transactions"] = transactions; sequence += 1
                }
                next = try nextLocalOccurrence(next, start: start, frequency: frequency)
            }
            presets[i]["nextDate"] = next; presets[i]["lastError"] = ""
            if !end.isEmpty && next > end { presets[i]["enabled"] = false }
        }
        space["presets"] = presets
    }
}
