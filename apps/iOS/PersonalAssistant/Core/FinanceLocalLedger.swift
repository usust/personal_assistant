import Foundation

extension FinanceLocalStore {
    /// 判断写入能否在本机安全执行；参数：path/method 为端点，body 为输入；返回值：普通账户、分类、收支和模板操作为 true，复杂分期贷款要求联网执行。
    func supportsLocal(_ path: String, method: String, body: [String: Any]) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        if parts[1] == "accounts" {
            if body.keys.contains(where: { $0.hasPrefix("loan") }) || body["institution"] as? String == "贷款" { return false }
            if parts.count > 2, let id = Int(parts[2]), rows("accounts").contains(where: { Self.id($0) == id && $0["institution"] as? String == "贷款" }) { return false }
            return parts.count <= 3
        }
        if parts[1] == "presets" {
            if (body["frequency"] as? String ?? "") != "" { return false }
            if parts.count > 2, let id = Int(parts[2]), let preset = rows("presets").first(where: { Self.id($0) == id }), (preset["frequency"] as? String ?? "") != "" { return false }
            return parts.count <= 3
        }
        if parts[1] == "categories" { return parts.count == 2 && method == "POST" }
        if parts[1] == "transactions" {
            if parts.count > 2, let id = Int(parts[2]), let row = rows("transactions").first(where: { Self.id($0) == id }), Self.id(row, "installmentParentId") != 0 || row["status"] as? String == "installment" || Self.id(row, "rebateParentId") != 0 { return false }
            if parts.last == "confirm", let id = Int(parts[2]), let row = rows("transactions").first(where: { Self.id($0) == id }), (try? Self.cents(row["rebate"] ?? "0.00")) != 0 { return false }
            return parts.count <= 3 || (parts.count == 4 && ["refund", "void", "confirm"].contains(parts[3]))
        }
        return false
    }

    /// 将本地业务变化和上传命令一起保存；参数：path/method 为受支持端点，body 为白名单输入；返回值：业务结果，校验或持久化失败不改内存账本。
    func writeLocal(_ path: String, method: String, body: [String: Any]) throws -> Any {
        var next = space
        if (path == "/finance/transactions" || path.hasSuffix("/refund")), let requestID = body["requestId"] as? String,
           let existing = rows("transactions").first(where: { $0["requestId"] as? String == requestID }) {
            guard let original = existing["localInput"] as? [String: Any], NSDictionary(dictionary: original).isEqual(to: body) else { throw Self.failure("记账标识冲突") }
            return existing
        }
        if path == "/finance/presets", let key = body["key"] as? String, let existing = rows("presets").first(where: { $0["key"] as? String == key }) {
            guard let original = existing["localInput"] as? [String: Any], NSDictionary(dictionary: original).isEqual(to: body) else { throw Self.failure("模板标识冲突") }
            return existing
        }
        if path == "/finance/categories", let existing = rows("categories").first(where: { $0["name"] as? String == body["name"] as? String && $0["type"] as? String == body["type"] as? String }) { return existing }
        let operationID = UUID().uuidString
        var payload = body
        if path == "/finance/transactions", payload["requestId"] == nil { payload["requestId"] = operationID }
        // 临时 ID 在整个数据库内单调分配，两位空间预留给转账返现子项，账号切换也不复用。
        let newID = document["nextLocalID"] as? Int ?? 1_000_000_000_000
        guard newID < 4_000_000_000_000 else { throw Self.failure("本机记录编号已用尽") }
        let result = try Self.apply(path, method: method, body: payload, newID: newID, space: &next)
        var commands = next["queue"] as? [[String: Any]] ?? []
        commands.append(["operationId": operationID, "path": path, "method": method, "body": payload, "localID": (result as? [String: Any]).map { Self.id($0) } ?? newID])
        next["queue"] = commands
        var updated = document, all = spaces
        all[activeKey] = next; updated["spaces"] = all; updated["nextLocalID"] = newID + 2
        try commit(updated); onMutation?()
        return result
    }

    /// 在账本副本执行原子业务操作；参数：path/method 为端点，body 为请求，newID 为稳定本机 ID，space 为可变副本；返回值：结果或校验错误；调用者必须丢弃失败副本，不执行网络请求。
    static func apply(_ path: String, method: String, body: [String: Any], newID: Int, space: inout [String: Any]) throws -> Any {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw failure("操作无效") }
        let table = parts[1], target = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        var records = space[table] as? [[String: Any]] ?? []
        if table == "accounts" {
            let allowed: Set<String> = ["name", "accountType", "institution", "maskedAccountNumber", "cards", "currency", "includeInNetWorth", "sortOrder", "notes", "balance", "currentDebt", "creditLimit", "billingDay", "repaymentDay", "billDayInclusive", "selectable", "reminderDays", "reminderTime"]
            guard Set(body.keys).isSubset(of: allowed) else { throw failure("账户字段无效") }
            var row: [String: Any]
            if method == "POST" {
                row = ["id": newID, "name": "", "accountType": "cash", "institution": "", "maskedAccountNumber": "", "currency": "CNY", "includeInNetWorth": true, "selectable": true, "notes": "", "balance": "0.00", "availableBalance": "0.00", "archived": false]
            } else {
                guard let found = records.first(where: { id($0) == target }) else { throw failure("账户不存在") }
                row = found
            }
            if method == "DELETE" {
                let transactions = space["transactions"] as? [[String: Any]] ?? []
                guard !transactions.contains(where: { ($0["status"] as? String == "pending") && (id($0, "accountId") == target || id($0, "targetAccountId") == target) }) else { throw failure("账户有待确认流水") }
                row["archived"] = true
            } else {
                guard !(row["archived"] as? Bool ?? false) else { throw failure("账户已删除") }
                if method == "PATCH", body["balance"] != nil { throw failure("期初余额仅开户时可填") }
                for (key, value) in body { guard !(value is NSNull) else { throw failure("账户字段不可为空") }; row[key] = value }
                guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128, row["currency"] as? String == "CNY" else { throw failure("账户名称或币种无效") }
                guard ["bank", "alipay", "wechat", "cash", "savings", "investment", "other"].contains(row["accountType"] as? String ?? ""),
                      (row["institution"] as? String ?? "").utf8.count <= 128,
                      (row["notes"] as? String ?? "").utf8.count <= 2000 else { throw failure("账户资料无效") }
                for key in ["billingDay", "repaymentDay"] { if let value = row[key], !(0...31).contains((value as? NSNumber)?.intValue ?? -1) { throw failure("账单日或还款日无效") } }
                if let value = row["reminderDays"], ![-1, 0, 1, 3, 7].contains((value as? NSNumber)?.intValue ?? -2) { throw failure("提醒时间无效") }
                let number = row["maskedAccountNumber"] as? String ?? ""
                guard number.range(of: #"^[0-9* ]{0,24}$"#, options: .regularExpression) != nil else { throw failure("卡号格式无效") }
                row["maskedAccountNumber"] = number.count > 4 ? "**** " + number.suffix(4) : number
                if let raw = body["cards"] {
                    guard let values = raw as? [[String: Any]], values.count <= 30,
                          values.allSatisfy({ Set($0.keys) == Set(["id", "name", "maskedAccountNumber"]) }) else { throw failure("卡片列表无效") }
                    // 映射回调输入卡片资料、返回校验脱敏后的卡片；错误中止整次字段更新，不修改额度余额。
                    let cards = try JSONDecoder().decode([AccountCard].self, from: JSONSerialization.data(withJSONObject: values)).map { try $0.normalized() }
                    guard Set(cards.map { $0.id }).count == cards.count else { throw failure("卡片编号重复") }
                    row["cards"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cards))
                }
                if let debt = body["currentDebt"] { row["balance"] = money(-(try cents(debt))); row.removeValue(forKey: "currentDebt") }
                row["balance"] = money(try cents(row["balance"]))
                row["availableBalance"] = row["balance"]
                if let limit = row["creditLimit"], try cents(limit) < 0 { throw failure("授信额度不可为负") }
            }
            if let index = records.firstIndex(where: { id($0) == target }), method != "POST" { records[index] = row } else { records.append(row) }
            space[table] = records; return row
        }
        if table == "categories" {
            guard let name = body["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 64, ["expense", "income"].contains(body["type"] as? String ?? "") else { throw failure("分类名称或类型无效") }
            var row = body; row["id"] = newID; row["color"] = body["color"] ?? "#808080"
            records.append(row); space[table] = records; return row
        }
        if table == "presets" {
            guard Set(body.keys).isSubset(of: ["key", "name", "transaction", "frequency", "startDate", "endDate", "enabled"]) else { throw failure("模板字段无效") }
            if method == "DELETE" { records.removeAll { id($0) == target }; space[table] = records; return NSNull() }
            var row: [String: Any]
            if method == "POST" {
                guard let key = body["key"] as? String, key.range(of: #"^[A-Za-z0-9_-]{8,96}$"#, options: .regularExpression) != nil else { throw failure("模板标识无效") }
                row = ["id": newID, "name": "", "frequency": "", "nextDate": "", "enabled": true, "lastError": "", "localInput": body]
            } else {
                guard let existing = records.first(where: { id($0) == target }) else { throw failure("模板不存在") }; row = existing
            }
            for (key, value) in body { row[key] = value }
            guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
                  var transaction = row["transaction"] as? [String: Any], (row["frequency"] as? String ?? "") == "" else { throw failure("模板名称或流水无效") }
            // 模板保留原金额；仅在独立副本验证记账规则，不能提前扣余额或应用两次优惠。
            transaction["requestId"] = "template-validation-" + String(newID)
            if transaction["transactionDate"] == nil { transaction["transactionDate"] = Values.day() }
            var validationSpace = space
            _ = try apply("/finance/transactions", method: "POST", body: transaction, newID: newID, space: &validationSpace)
            transaction.removeValue(forKey: "requestId")
            transaction["counterparty"] = transaction["counterparty"] ?? ""; transaction["description"] = transaction["description"] ?? ""
            row["transaction"] = transaction
            if let index = records.firstIndex(where: { id($0) == target }), method != "POST" { records[index] = row } else { records.append(row) }
            space[table] = records; return row
        }
        guard table == "transactions" else { throw failure("此操作需要联网") }
        if method == "POST" && target == 0 {
            let allowed: Set<String> = ["requestId", "accountId", "targetAccountId", "targetCreditCardId", "type", "amount", "categoryId", "counterparty", "transactionDate", "transactionTime", "description", "fee", "discount", "rebate", "rebateAccountId", "rebatePending"]
            guard Set(body.keys).isSubset(of: allowed), (body["targetCreditCardId"] == nil || body["targetCreditCardId"] is NSNull),
                  let key = body["requestId"] as? String, key.range(of: #"^[A-Za-z0-9_-]{8,96}$"#, options: .regularExpression) != nil else { throw failure("流水字段或记账标识无效") }
            // 同一录入会话失败重试保持 requestId；本地也去重，避免界面重试形成两笔消费。
            if let requestID = body["requestId"] as? String, let existing = records.first(where: { $0["requestId"] as? String == requestID }) {
                guard let original = existing["localInput"] as? [String: Any], NSDictionary(dictionary: original).isEqual(to: body) else { throw failure("记账标识冲突") }
                return existing
            }
            var row: [String: Any] = ["id": newID, "type": "expense", "amount": "0.00", "fee": "0.00", "discount": "0.00", "counterparty": "", "description": "", "status": "posted", "source": "http"]
            for (key, value) in body { row[key] = value }
            row["localInput"] = body
            let amount = try cents(body["amount"]), discount = try cents(body["discount"] ?? "0.00"), fee = try cents(body["fee"] ?? "0.00")
            let kind = row["type"] as? String ?? ""
            guard ["income", "expense", "transfer"].contains(kind), amount > 0, discount >= 0, discount < amount, fee >= 0, (kind == "expense" || discount == 0), (kind == "transfer" || fee == 0) else { throw failure("金额、优惠或手续费无效") }
            row["amount"] = money(amount - discount)
            try validateTransaction(row, space: space)
            try adjustBalances(row, direction: 1, space: &space)
            records.append(row)
            let rebate = try cents(body["rebate"] ?? "0.00")
            guard rebate >= 0, kind == "transfer" || rebate == 0,
                  rebate > 0 || (id(body, "rebateAccountId") == 0 && body["rebatePending"] as? Bool != true) else { throw failure("优惠返现金额无效") }
            if rebate > 0 {
                let rebateAccount = id(body, "rebateAccountId") == 0 ? id(row, "accountId") : id(body, "rebateAccountId")
                // 返现子项属于同一原子本地事务；操作身份仍由父转账控制，同步后以服务器子项替换。
                let child: [String: Any] = ["id": newID + 1, "accountId": rebateAccount, "type": "income", "amount": money(rebate), "fee": "0.00", "counterparty": "还款优惠", "description": "", "transactionDate": row["transactionDate"] ?? "", "status": body["rebatePending"] as? Bool == true ? "pending" : "posted", "source": "http", "rebateParentId": newID]
                try validateTransaction(child, space: space)
                if child["status"] as? String == "posted" { try adjustBalances(child, direction: 1, space: &space) }
                records.append(child)
            }
            space[table] = records; return row
        }
        guard let index = records.firstIndex(where: { id($0) == target }) else { throw failure("流水不存在") }
        var row = records[index]
        if method == "PATCH" {
            let allowed: Set<String> = ["accountId", "targetAccountId", "type", "amount", "discount", "fee", "rebate", "rebateAccountId", "rebatePending", "categoryId", "counterparty", "description", "transactionDate", "transactionTime"]
            guard !body.isEmpty, Set(body.keys).isSubset(of: allowed), row["status"] as? String != "deleted", row["status"] as? String != "voided" else { throw failure("流水不可修改") }
            let financial = !Set(body.keys).isSubset(of: ["categoryId", "counterparty", "description"])
            let previous = row
            if financial {
                // 关联账单财务关系由原业务维护；普通流水在同一账本副本内先验证再冲销重记。
                guard row["status"] as? String != "installment", id(row, "installmentParentId") == 0, id(row, "refundParentId") == 0, id(row, "rebateParentId") == 0 else { throw failure("关联分期、退款或优惠流水的金额与账户请在原业务中调整") }
                var input = row.filter { allowed.contains($0.key) }
                input["amount"] = money(try cents(row["amount"]) + cents(row["discount"] ?? "0.00"))
                for (key, value) in body { input[key] = value }
                input["requestId"] = "edit-validation-" + String(newID)
                var validationSpace = space
                // 验证副本先撤回旧余额影响，避免大额流水在验证时被重复扣算而误报溢出。
                if previous["status"] as? String == "posted" { try adjustBalances(previous, direction: -1, space: &validationSpace) }
                for child in records where id(child, "rebateParentId") == target && child["status"] as? String == "posted" {
                    try adjustBalances(child, direction: -1, space: &validationSpace)
                }
                let validated = try apply("/finance/transactions", method: "POST", body: input, newID: newID, space: &validationSpace) as! [String: Any]
                for key in body.keys { row[key] = validated[key] ?? NSNull() }
                if body["amount"] != nil || body["discount"] != nil { row["amount"] = validated["amount"] }
                let refunds = records.filter { id($0, "refundParentId") == target && $0["status"] as? String == "posted" }
                var refunded: Int64 = 0
                for refund in refunds {
                    refunded -= try cents(refund["amount"])
                    guard row["type"] as? String == "expense", id(row, "accountId") == id(previous, "accountId"), (row["transactionDate"] as? String ?? "") <= (refund["transactionDate"] as? String ?? "") else { throw failure("已有退款，不能更改收支类型、账户或晚于退款日期") }
                }
                guard try cents(row["amount"]) >= refunded else { throw failure("金额不能小于已退款金额") }
                if row["status"] as? String == "posted" {
                    try adjustBalances(previous, direction: -1, space: &space)
                    try adjustBalances(row, direction: 1, space: &space)
                }
                // 返现保持子项身份；未提交到账状态时保留已确认结果，避免重复到账。
                let rebate = try cents(input["rebate"] ?? "0.00")
                let childIndex = records.firstIndex { id($0, "rebateParentId") == target }
                if childIndex != nil || rebate > 0 && row["status"] as? String == "posted" {
                    var child = childIndex.map { records[$0] } ?? ["id": newID + 1, "type": "income", "fee": "0.00", "counterparty": "还款优惠", "description": "", "source": "http", "rebateParentId": target]
                    if child["status"] as? String == "posted" { try adjustBalances(child, direction: -1, space: &space) }
                    var status = child["status"] as? String ?? "deleted"
                    if rebate == 0 || row["status"] as? String != "posted" { status = "deleted" }
                    else if body["rebatePending"] != nil || ["deleted", "voided"].contains(status) { status = input["rebatePending"] as? Bool == true ? "pending" : "posted" }
                    child["status"] = status; child["amount"] = money(rebate)
                    child["accountId"] = id(input, "rebateAccountId") == 0 ? id(row, "accountId") : id(input, "rebateAccountId")
                    child["transactionDate"] = row["transactionDate"]
                    if rebate > 0 { try validateTransaction(child, space: space) }
                    if status == "posted" { try adjustBalances(child, direction: 1, space: &space) }
                    if let childIndex { records[childIndex] = child } else { records.append(child) }
                }
            } else {
                for (key, value) in body { row[key] = value }
                try validateCategory(row, space: space)
            }
        } else if parts.last == "refund" {
            guard Set(body.keys).isSubset(of: ["requestId", "amount", "transactionDate", "transactionTime", "description"]),
                  let key = body["requestId"] as? String, key.range(of: #"^[A-Za-z0-9_-]{8,96}$"#, options: .regularExpression) != nil else { throw failure("退款字段或标识无效") }
            guard row["status"] as? String == "posted", row["type"] as? String == "expense", id(row, "refundParentId") == 0 else { throw failure("仅已入账支出可退款") }
            let amount = try cents(body["amount"])
            var available = try cents(row["amount"])
            for refund in records where id(refund, "refundParentId") == target && refund["status"] as? String == "posted" { available += try cents(refund["amount"]) }
            guard amount > 0, amount <= available, (body["transactionDate"] as? String ?? "") >= (row["transactionDate"] as? String ?? "") else { throw failure("退款金额或日期无效") }
            var refund = row
            for key in ["localInput", "rebate", "rebateParentId", "discount"] { refund.removeValue(forKey: key) }
            for (key, value) in body { refund[key] = value }
            refund["localInput"] = body
            refund["id"] = newID; refund["refundParentId"] = target; refund["amount"] = money(-amount); refund["fee"] = "0.00"
            try validateTransaction(refund, space: space)
            try adjustBalances(refund, direction: 1, space: &space)
            records.append(refund); space[table] = records; return refund
        } else if parts.last == "confirm" {
            guard row["status"] as? String == "pending" || row["status"] as? String == "posted" else { throw failure("流水不可确认") }
            if row["status"] as? String == "pending" {
                // 转账草稿确认可能生成返现子项，留给服务端原子处理，避免本机漏记关联收入。
                guard try cents(row["rebate"] ?? "0.00") == 0 else { throw failure("含返现的草稿请联网确认") }
                try validateTransaction(row, space: space); try adjustBalances(row, direction: 1, space: &space); row["status"] = "posted"
            }
        } else if parts.last == "void" || method == "DELETE" {
            let state = method == "DELETE" ? "deleted" : "voided"
            for i in records.indices where id(records[i]) == target || id(records[i], "refundParentId") == target || id(records[i], "rebateParentId") == target {
                if records[i]["status"] as? String == "posted" { try adjustBalances(records[i], direction: -1, space: &space) }
                records[i]["status"] = state
            }
            space[table] = records; return records[index]
        } else { throw failure("此操作需要联网") }
        records[index] = row; space[table] = records; return row
    }

    /// 校验分类归属与收支类型；参数：row 为流水，space 为本机账本；返回值：无；非法分类或转账分类抛错。
    static func validateCategory(_ row: [String: Any], space: [String: Any]) throws {
        for (key, limit) in [("counterparty", 128), ("description", 2000)] {
            guard let value = row[key] as? String, value.utf8.count <= limit else { throw failure("流水文本无效") }
        }
        let categoryID = id(row, "categoryId")
        if categoryID == 0 { return }
        let categories = space["categories"] as? [[String: Any]] ?? []
        guard categories.contains(where: { id($0) == categoryID && $0["type"] as? String == row["type"] as? String }) else { throw failure("分类与收支类型不匹配") }
    }
    /// 校验交易日期和关联账户；参数：row 为流水，space 为当前账本；返回值：无；引用不可用或日期无效抛错。
    static func validateTransaction(_ row: [String: Any], space: [String: Any]) throws {
        guard let date = row["transactionDate"] as? String, date.count == 10, Values.day(Values.date(date)) == date else { throw failure("交易日期无效") }
        if let time = row["transactionTime"] as? String, !time.isEmpty,
           time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil { throw failure("交易时间无效") }
        if row["type"] as? String != "transfer", id(row, "targetAccountId") != 0 { throw failure("仅转账可指定转入账户") }
        try validateCategory(row, space: space)
        let accounts = space["accounts"] as? [[String: Any]] ?? []
        var ids = [id(row, "accountId")]
        if row["type"] as? String == "transfer" {
            guard id(row, "targetAccountId") != ids[0], id(row, "targetAccountId") != 0 else { throw failure("转入转出账户必须不同") }
            ids.append(id(row, "targetAccountId"))
        }
        for accountID in ids {
            guard accounts.contains(where: { id($0) == accountID && $0["archived"] as? Bool != true && $0["selectable"] as? Bool != false }) else { throw failure("记账账户不可用") }
        }
    }
    /// 调整本地余额投影；参数：row 为完整流水，direction 为 1 入账或 -1 冲销，space 为可变账本副本；返回值：无；两端均校验上限，失败由调用者放弃整个副本。
    static func adjustBalances(_ row: [String: Any], direction: Int64, space: inout [String: Any]) throws {
        var accounts = space["accounts"] as? [[String: Any]] ?? []
        let amount = try cents(row["amount"]), fee = try cents(row["fee"] ?? "0.00")
        let kind = row["type"] as? String ?? ""
        var changes = [id(row, "accountId"): (kind == "income" ? amount : -amount) - fee]
        if kind == "transfer" { changes[id(row, "targetAccountId")] = amount }
        for (accountID, change) in changes {
            guard let index = accounts.firstIndex(where: { id($0) == accountID }) else { throw failure("关联账户不存在") }
            let value = try cents(accounts[index]["balance"]) + direction * change
            guard abs(value) <= 100_000_000_000_000 else { throw failure("账户余额超出范围") }
            accounts[index]["balance"] = money(value); accounts[index]["availableBalance"] = money(value)
        }
        space["accounts"] = accounts
    }
}
