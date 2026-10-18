import Foundation

/// 同步协议替身；仅模拟确定的开户、分类和一笔消费，不调用本地记账实现，首次入账后故意丢失响应。
final class OfflineSyncServer: @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: [String: Data] = [:]
    private(set) var creates = 0
    private(set) var payments = 0
    var losePaymentResponse = true
    var snapshotHook: (() -> Void)?
    var account: [String: Any] = ["id": 7, "name": "现金", "accountType": "cash", "institution": "", "maskedAccountNumber": "", "balance": "100.00", "availableBalance": "100.00", "currency": "CNY", "includeInNetWorth": true, "notes": "", "archived": false]
    var category: [String: Any] = ["id": 11, "name": "午餐", "type": "expense", "color": "#123456"]
    var transaction: [String: Any]?

    /// 返回测试服务响应；参数：request 为客户端真实编码的 URLRequest；返回值：状态码和 JSON；模拟提交后断线以验证同一操作重放。
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/snapshot") {
            var cloud = account; cloud["id"] = 9; cloud["balance"] = "500.00"; cloud["availableBalance"] = "500.00"
            let snapshot: [String: Any] = ["schemaVersion": 1, "accounts": [account, cloud], "categories": [category], "transactions": transaction.map { [$0] } ?? [], "presets": [], "plans": [:], "installments": []]
            let bytes = try JSONSerialization.data(withJSONObject: ["data": snapshot])
            snapshotHook?()
            return (200, bytes)
        }
        precondition(path.hasSuffix("/commands"), "未通过同步协议上传")
        let payload = try CoreTests.body(request)
        let key = payload["operationId"] as! String
        if let receipt = receipts[key] { return (200, receipt) }
        let body = payload["body"] as! [String: Any]
        let op = payload["operation"] as! String
        var value: [String: Any]
        switch op {
        case "finance.account.create": creates += 1; value = account
        case "finance.category.create": value = category
        case "finance.transaction.create":
            precondition((body["accountId"] as? Int) == 7 && (body["categoryId"] as? Int) == 11, "本机引用未映射成服务器 ID")
            payments += 1
            value = body; value["id"] = 13; value["status"] = "posted"; value["source"] = "http"; value["fee"] = "0.00"; value["counterparty"] = ""; value["description"] = ""
            transaction = value; account["balance"] = "80.00"; account["availableBalance"] = "80.00"
        default: throw APIError(status: 400, message: "测试不支持操作")
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["data": value]); receipts[key] = bytes
        if op == "finance.transaction.create", losePaymentResponse { losePaymentResponse = false; throw URLError(.networkConnectionLost) }
        return (200, bytes)
    }
}

/// 固定脚本同步替身；逐项核对上传身份并返回预置回执和快照，不实现后端业务，不调用本地 apply。
final class CategoryRecreationSyncServer: @unchecked Sendable {
    struct Step {
        let operation: String
        let id: Int
        let categoryID: Int?
        let result: [String: Any]
    }
    private let lock = NSLock()
    private let steps: [Step]
    private let snapshots: [[String: Any]]
    private var commandIndex = 0
    private var snapshotIndex = 0
    var snapshotHook: ((Int) -> Void)?

    /// 构造静态协议脚本；参数：steps 为按上传顺序预置的操作与回执，snapshots 为每次下载的完整快照；返回值：替身实例；无副作用，不读取真实数据。
    init(steps: [Step], snapshots: [[String: Any]]) {
        self.steps = steps; self.snapshots = snapshots
    }

    /// 核对请求并返回固定结果；参数：request 为客户端编码请求；返回值：HTTP 状态与信封字节；脚本越界或身份不符终止测试，JSON 错误抛出；快照钩子在生成响应后执行。
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        if request.url?.path.hasSuffix("/snapshot") == true {
            precondition(request.httpMethod == "GET" && snapshotIndex < snapshots.count, "意外快照请求")
            let index = snapshotIndex; snapshotIndex += 1
            let data = try JSONSerialization.data(withJSONObject: ["data": snapshots[index]])
            snapshotHook?(index)
            return (200, data)
        }
        precondition(request.url?.path.hasSuffix("/commands") == true && request.httpMethod == "POST" && commandIndex < steps.count, "意外上传请求")
        let payload = try CoreTests.body(request), step = steps[commandIndex]
        precondition(payload["operation"] as? String == step.operation && (payload["id"] as? NSNumber)?.intValue == step.id, "同名分类命令不得映射至其他身份")
        if let expected = step.categoryID {
            let body = payload["body"] as! [String: Any]
            precondition((body["categoryId"] as? NSNumber)?.intValue == expected, "新流水必须上传新分类 ID，不能引用同名墓碑")
        }
        commandIndex += 1
        return (200, try JSONSerialization.data(withJSONObject: ["data": step.result]))
    }

    /// 核对所有静态脚本已消费；参数：无；返回值：无；加锁读取计数，遗漏任何命令或快照即终止测试。
    func checkComplete() {
        lock.lock(); defer { lock.unlock() }
        precondition(commandIndex == steps.count && snapshotIndex == snapshots.count, "分类重建上传及快照脚本完整执行")
    }
}

@MainActor enum FinanceOfflineTests {
    /// 新建独立临时账本；参数：directory 为测试目录，name 为文件名；返回值：账本；失败抛错，不读取真实用户数据。
    static func ledger(_ directory: URL, _ name: String) throws -> FinanceLocalStore { try FinanceLocalStore(url: directory.appendingPathComponent(name + ".sqlite")) }
    /// 构造基本账户；参数：store 为账本，name 为名称，balance 为期初金额；返回值：本机账户 ID；本地持久写入失败抛错。
    static func account(_ store: FinanceLocalStore, name: String, balance: String) throws -> Int {
        let result = try store.writeLocal("/finance/accounts", method: "POST", body: ["name": name, "accountType": "cash", "balance": balance]) as! [String: Any]
        return FinanceLocalStore.id(result)
    }
    /// 构造流水请求；参数：id 为账户，kind 为类型，amount 为原金额，key 为稳定请求键；返回值：使用固定日期的输入字典。
    static func payment(_ id: Int, kind: String = "expense", amount: String = "20.00", key: String = "offline-payment-001") -> [String: Any] {
        ["requestId": key, "accountId": id, "type": kind, "amount": amount, "transactionDate": "2026-09-29"]
    }
    /// 断言账户余额；参数：store 为账本，id 为账户，expected 为精确字符串；返回值：无，失败终止测试。
    static func balance(_ store: FinanceLocalStore, _ id: Int, _ expected: String) {
        CoreTests.check(store.rows("accounts").first { FinanceLocalStore.id($0) == id }?["balance"] as? String == expected, "离线余额 \(expected)")
    }
    /// 验证离线流水财务更正；参数：无；返回值：无；使用隔离账本验证转账余额、零优惠及失败回滚，失败抛错。
    static func transactionEditing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ledger(directory, "editing")
        let a = try account(store, name: "现金", balance: "100.00")
        let b = try account(store, name: "银行卡", balance: "100.00")
        let created = try store.writeLocal("/finance/transactions", method: "POST", body: payment(a)) as! [String: Any]
        let path = "/finance/transactions/" + String(FinanceLocalStore.id(created))
        _ = try store.writeLocal(path, method: "PATCH", body: ["amount": "30.00", "discount": "5.00", "transactionTime": "12:34"])
        balance(store, a, "75.00")
        _ = try store.writeLocal(path, method: "PATCH", body: ["type": "transfer", "accountId": b, "targetAccountId": a, "discount": "0.00", "fee": "2.00", "rebate": "3.00", "rebateAccountId": b])
        balance(store, a, "130.00"); balance(store, b, "71.00")
        _ = try store.writeLocal(path, method: "PATCH", body: ["rebate": "0.00", "rebateAccountId": NSNull(), "rebatePending": false])
        balance(store, b, "68.00")
        let before = store.document
        do {
            _ = try store.writeLocal(path, method: "PATCH", body: ["targetAccountId": b])
            CoreTests.check(false, "相同转账账户必须拒绝")
        } catch { CoreTests.check(NSDictionary(dictionary: before).isEqual(to: store.document), "编辑失败完整回滚余额与队列") }
    }
    /// 验证分类编辑和跨月报销净额；参数：无；返回值：无；使用独立账本验证稳定引用、零值清空、退款和重新打开后的资料，不访问真实数据。
    static func reimbursementAndCategoryEditing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reimbursement-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ledger(directory, "reimbursement")
        let a = try account(store, name: "报销钱包", balance: "1000.00")
        let b = try account(store, name: "其他钱包", balance: "100.00")
        let category = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "工作午餐", "type": "expense", "groupKey": "food", "icon": "fork.knife", "color": "#123456"]) as! [String: Any]
        let categoryID = FinanceLocalStore.id(category), categoryPath = "/finance/categories/\(categoryID)"
        var body = payment(a, amount: "100.00", key: "reimbursement-expense-001")
        body["discount"] = "10.00"; body["reimbursementStatus"] = "pending"; body["categoryId"] = categoryID
        let created = try store.writeLocal("/finance/transactions", method: "POST", body: body) as! [String: Any]
        let id = FinanceLocalStore.id(created), path = "/finance/transactions/\(id)"
        CoreTests.check(store.supportsLocal(categoryPath, method: "PATCH", body: ["name": "商务午餐"]), "分类更正支持离线")
        _ = try store.writeLocal(categoryPath, method: "PATCH", body: ["name": "商务午餐", "icon": "cup.and.saucer"])
        let edited = store.rows("categories").first { FinanceLocalStore.id($0) == categoryID }!
        CoreTests.check(edited["name"] as? String == "商务午餐" && edited["groupKey"] as? String == "food" && edited["color"] as? String == "#123456", "分类只更新提交字段")
        CoreTests.check(store.rows("transactions").first { FinanceLocalStore.id($0) == id }?["categoryId"] as? Int == categoryID, "分类更正保留原流水引用")
        _ = try store.writeLocal(categoryPath, method: "PATCH", body: ["groupKey": "", "icon": ""])
        CoreTests.check(store.rows("categories").first { FinanceLocalStore.id($0) == categoryID }?["icon"] as? String == "", "分类可显式清除图标")
        let categoryBefore = store.document
        do {
            _ = try store.writeLocal(categoryPath, method: "PATCH", body: ["type": "income"])
            CoreTests.check(false, "有关联流水的分类不得跨收支类型")
        } catch { CoreTests.check(NSDictionary(dictionary: categoryBefore).isEqual(to: store.document), "非法分类更正原子回滚") }
        // 跨月退款必须回到原支出月份，不能受当前月份流水分页或退款日期限制。
        _ = try store.writeLocal(path + "/refund", method: "POST", body: ["requestId": "reimbursement-refund-001", "amount": "20.00", "transactionDate": "2026-10-02"])
        let refund = store.rows("transactions").first { FinanceLocalStore.id($0, "refundParentId") == id }!
        CoreTests.check((refund["reimbursementStatus"] as? String ?? "").isEmpty, "退款不复制报销状态")
        var other = payment(b, amount: "5.00", key: "reimbursement-other-001"); other["reimbursementStatus"] = "reimbursed"
        _ = try store.writeLocal("/finance/transactions", method: "POST", body: other)
        let filters = ["startDate": "2026-09-01", "endDate": "2026-09-30", "accountId": String(a), "limit": "1"]
        var sums = try store.summary(filters)
        CoreTests.check(sums["reimbursementPending"] == "70.00" && sums["reimbursementReceived"] == "0.00" && sums["reimbursementTotal"] == "70.00", "实付扣退款并隔离账户")
        _ = try store.writeLocal(path, method: "PATCH", body: ["reimbursementStatus": "reimbursed"])
        balance(store, a, "930.00")
        sums = try store.summary(filters)
        CoreTests.check(sums["reimbursementPending"] == "0.00" && sums["reimbursementReceived"] == "70.00", "状态更正仅重新分类，不重复入账")
        let restored = try ledger(directory, "reimbursement")
        CoreTests.check(restored.rows("transactions").first { FinanceLocalStore.id($0) == id }?["reimbursementStatus"] as? String == "reimbursed", "重启保留报销标记")
        _ = try store.writeLocal(path, method: "PATCH", body: ["reimbursementStatus": ""])
        let cleared = try store.summary(filters)
        CoreTests.check(cleared["reimbursementTotal"] == "0.00", "显式空值取消报销")
        let before = store.document
        var invalid = payment(a, kind: "income", key: "invalid-reimbursement-001"); invalid["reimbursementStatus"] = "pending"
        do {
            _ = try store.writeLocal("/finance/transactions", method: "POST", body: invalid)
            CoreTests.check(false, "收入不能标记报销")
        } catch { CoreTests.check(NSDictionary(dictionary: before).isEqual(to: store.document), "非法报销回滚余额和队列") }
    }
    /// 验证同步贷款摘要不会冒充完整计划；参数：无；返回值：无；在隔离账本验证明细联网回退、断网报错及完整缓存读取，不访问真实数据。
    static func loanPlanReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loan-reading-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ledger(directory, "loan")
        try store.enable(server: "https://test.invalid/api", profile: Profile(id: 1, account: "loan", nickname: "测试", role: "user"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: "https://test.invalid/api", session: URLSession(configuration: configuration))
        api.token = "test"; api.localFinance = store
        defer { StubProtocol.handler = nil }
        let server = OfflineSyncServer()
        let summary: [String: Any] = ["remainingPrincipal": "565138.68", "totalInterest": "325000.00", "paidPeriods": 47, "revision": 3, "next": NSNull()]
        server.account["institution"] = "贷款"; server.account["loanPrincipal"] = "650000.00"
        server.account["loanPeriods"] = 360; server.account["loanPaidPeriods"] = 47; server.account["loanPlan"] = summary
        // 快照回调输入请求、返回独立服务端数据；账户只含摘要，与生产同步协议一致。
        StubProtocol.handler = { request in try server.respond(request) }
        try await store.synchronize(api: api)
        let accounts: [FinancialAccount] = try await api.request("/finance/accounts")
        CoreTests.check(accounts.first?.loanPaidPeriods == 47 && accounts.first?.loanPlan?.remainingPrincipal == "565138.68", "摘要仍可展示已有贷款及还款进度")
        let path = "/finance/accounts/7/loan-plan"
        let summaryResult = try store.readLocal(path, query: [])
        CoreTests.check(summaryResult == nil, "缺少明细的同步摘要应回退完整计划接口")
        // 期次映射输入期数，返回仅用于读取契约的固定金额明细，不验证贷款计算公式。
        let schedule: [[String: Any]] = (1...360).map { period in
            ["period": period, "date": "2026-10-18", "principal": "2000.00", "interest": "1312.60", "payment": "3312.60", "remaining": "565138.68"]
        }
        var full = summary; full["schedule"] = schedule
        let response = try FinanceLocalStore.envelope(full)
        // 完整计划回调输入请求、返回完整明细；端点或方法错误立即让测试失败。
        StubProtocol.handler = { request in
            precondition(request.url?.path == "/api/finance/accounts/7/loan-plan" && request.httpMethod == "GET", "贷款明细应调用专用读取端点")
            return (200, response)
        }
        let plan: LoanPlanSummary = try await api.request(path)
        CoreTests.check(plan.schedule?.count == 360 && plan.paidPeriods == 47 && plan.revision == 3, "摘要缓存存在时仍能读取完整360期计划及原版本")
        // 断网回调输入请求并抛出网络错误；摘要不能让失败请求伪装为成功的空计划。
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            let _: LoanPlanSummary = try await api.request(path)
            CoreTests.check(false, "只有摘要且断网时应抛出明细加载错误")
        } catch {
            CoreTests.check((error as? URLError)?.code == .notConnectedToInternet, "完整计划网络失败保留真实错误")
        }
        // 缓存边界仍接受空明细数组；null、缺失或错误类型均不是完整计划。
        for value in [NSNull(), "invalid"] as [Any] {
            var incomplete = summary; incomplete["schedule"] = value
            var account = server.account; account["loanPlan"] = incomplete
            var next = store.space; next["accounts"] = [account]; try store.saveSpace(next)
            let local = try store.readLocal(path, query: [])
            CoreTests.check(local == nil, "无效明细缓存不能冒充完整贷款计划")
        }
        for rows in [schedule, [[String: Any]]()] {
            var cached = summary; cached["schedule"] = rows
            var account = server.account; account["loanPlan"] = cached
            var next = store.space; next["accounts"] = [account]; try store.saveSpace(next)
            let local: LoanPlanSummary = try await api.request(path)
            CoreTests.check(local.schedule?.count == rows.count && local.paidPeriods == 47, "完整缓存和合法空明细均可离线读取")
        }
        CoreTests.check(store.queue.isEmpty, "读取计划不重新填写贷款或产生写入队列")
    }
    /// 验证分类墓碑、同名重建和临时 ID 重映射；参数：无；返回值：无；隔离账本验证新 ID、历史引用与外观、多轮重建和活动名称唯一，失败抛错或断言，不访问真实数据。
    static func categoryTombstones() throws {
        let legacy = Data(#"{"id": 3, "name": "旧分类", "type": "expense", "color": "#123456"}"#.utf8)
        let decoded = try JSONDecoder().decode(TransactionCategory.self, from: legacy)
        CoreTests.check(decoded.deleted == false, "旧分类 JSON 缺少 deleted 时默认为未删除")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("category-tombstone-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ledger(directory, "references")
        let accountID = try account(store, name: "墓碑测试钱包", balance: "100.00")
        let created = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "墓碑午餐", "type": "expense", "groupKey": "food", "icon": "fork.knife", "color": "#123456"]) as! [String: Any]
        let categoryID = FinanceLocalStore.id(created)
        CoreTests.check(categoryID >= 1_000_000_000_000 && store.supportsLocal("/finance/categories/\(categoryID)", method: "DELETE", body: [:]), "删除支持正数临时分类 ID")
        var paymentBody = payment(accountID, key: "tombstone-old-001"); paymentBody["categoryId"] = categoryID
        let oldTransaction = try store.writeLocal("/finance/transactions", method: "POST", body: paymentBody) as! [String: Any]
        let oldTransactionID = FinanceLocalStore.id(oldTransaction)
        _ = try store.writeLocal("/finance/categories/\(categoryID)", method: "DELETE", body: [:])
        let deleted = store.rows("categories").first { FinanceLocalStore.id($0) == categoryID }
        CoreTests.check(deleted?["deleted"] as? Bool == true, "本地分类删除写入墓碑")
        _ = try store.writeLocal("/finance/categories/\(categoryID)", method: "DELETE", body: [:])
        CoreTests.check(store.rows("categories").filter { FinanceLocalStore.id($0) == categoryID }.count == 1, "重复删除墓碑幂等且不复制分类")
        do {
            _ = try store.writeLocal("/finance/categories/\(categoryID)", method: "PATCH", body: ["name": "不应修改"])
            CoreTests.check(false, "已删除分类禁止 PATCH")
        } catch { CoreTests.check(true, "已删除分类禁止 PATCH") }
        let rebuilt = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "墓碑午餐", "type": "expense", "groupKey": "food", "icon": "cup.and.saucer", "color": "#654321"]) as! [String: Any]
        let rebuiltID = FinanceLocalStore.id(rebuilt)
        CoreTests.check(rebuiltID != categoryID && rebuilt["deleted"] as? Bool == false, "同名重建分配新 ID，不恢复墓碑")
        let oldCategory = store.rows("categories").first { FinanceLocalStore.id($0) == categoryID }!
        CoreTests.check(NSDictionary(dictionary: oldCategory).isEqual(to: deleted!), "重建不改写墓碑的任何字段")
        CoreTests.check(oldCategory["name"] as? String == "墓碑午餐" && oldCategory["icon"] as? String == "fork.knife" && oldCategory["color"] as? String == "#123456", "旧分类名称与图标颜色保留")
        let queued = store.queue.count
        let duplicate = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "墓碑午餐", "type": "expense"]) as! [String: Any]
        CoreTests.check(FinanceLocalStore.id(duplicate) == rebuiltID && store.queue.count == queued, "墓碑排在前面时仍复用活动同名分类且不重复排队")
        let spacedDuplicate = try store.writeLocal("/finance/categories", method: "POST", body: ["name": " 墓碑午餐 ", "type": "expense"]) as! [String: Any]
        CoreTests.check(FinanceLocalStore.id(spacedDuplicate) == rebuiltID && store.queue.count == queued, "首尾空白规范化后仍复用活动同名分类")
        var rebuiltPayment = payment(accountID, amount: "1.00", key: "tombstone-rebuilt-001"); rebuiltPayment["categoryId"] = rebuiltID
        let newTransaction = try store.writeLocal("/finance/transactions", method: "POST", body: rebuiltPayment) as! [String: Any]
        CoreTests.check(FinanceLocalStore.id(newTransaction, "categoryId") == rebuiltID, "新流水引用重建后的新 ID")

        // 同名只约束活动记录；改名冲突回滚，其他收支类型仍可使用同名。
        let other = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "另一分类", "type": "expense"]) as! [String: Any]
        let otherID = FinanceLocalStore.id(other)
        let beforeConflict = store.document
        do {
            _ = try store.writeLocal("/finance/categories/\(otherID)", method: "PATCH", body: ["name": "墓碑午餐"])
            CoreTests.check(false, "活动同名冲突必须拒绝")
        } catch { CoreTests.check(NSDictionary(dictionary: beforeConflict).isEqual(to: store.document), "活动名称冲突不改账本或队列") }
        _ = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "墓碑午餐", "type": "income"])
        _ = try store.writeLocal("/finance/categories/\(rebuiltID)", method: "DELETE", body: [:])
        _ = try store.writeLocal("/finance/categories/\(otherID)", method: "PATCH", body: ["name": "墓碑午餐"])
        CoreTests.check(store.rows("categories").first { FinanceLocalStore.id($0) == otherID }?["name"] as? String == "墓碑午餐", "允许活动分类重命名为墓碑名称")
        var lastID = otherID
        var historicalIDs = Set([categoryID, rebuiltID, otherID])
        for round in 1...3 {
            _ = try store.writeLocal("/finance/categories/\(lastID)", method: "DELETE", body: [:])
            let next = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "墓碑午餐", "type": "expense", "icon": "cup.and.saucer", "color": "#654321"]) as! [String: Any]
            lastID = FinanceLocalStore.id(next)
            CoreTests.check(historicalIDs.insert(lastID).inserted, "第 \(round) 轮删除重建不复用旧 ID")
            let sameName = store.rows("categories").filter { $0["name"] as? String == "墓碑午餐" && $0["type"] as? String == "expense" }
            CoreTests.check(sameName.count == round + 3 && sameName.filter { $0["deleted"] as? Bool != true }.count == 1, "多轮重建保留所有墓碑且仅一个活动分类")
        }
        let restored = try ledger(directory, "references")
        CoreTests.check(restored.rows("categories").count == store.rows("categories").count && restored.rows("transactions").first { FinanceLocalStore.id($0) == oldTransactionID }?["categoryId"] as? Int == categoryID, "重新打开后保留多轮墓碑及原流水引用")
        CoreTests.check(restored.rows("transactions").first { FinanceLocalStore.id($0) == FinanceLocalStore.id(newTransaction) }?["categoryId"] as? Int == rebuiltID, "多轮重建不迁移前轮新流水的原分类引用")
        var newBody = payment(accountID, key: "tombstone-new-001"); newBody["categoryId"] = categoryID
        do {
            _ = try store.writeLocal("/finance/transactions", method: "POST", body: newBody)
            CoreTests.check(false, "新流水禁止引用墓碑分类")
        } catch { CoreTests.check(true, "新流水禁止引用墓碑分类") }
        _ = try store.writeLocal("/finance/transactions/\(oldTransactionID)", method: "PATCH", body: ["description": "保留历史分类"])
        CoreTests.check(store.rows("transactions").first { FinanceLocalStore.id($0) == oldTransactionID }?["categoryId"] as? Int == categoryID, "旧流水编辑保留墓碑分类引用")
        _ = try store.writeLocal("/finance/transactions/\(oldTransactionID)/refund", method: "POST", body: ["requestId": "tombstone-refund-001", "amount": "1.00", "transactionDate": "2026-09-29", "description": ""])
        CoreTests.check(store.rows("transactions").contains { FinanceLocalStore.id($0, "refundParentId") == oldTransactionID && FinanceLocalStore.id($0, "categoryId") == categoryID }, "旧流水退款保留墓碑分类引用")

        var pendingSpace = store.space
        pendingSpace["transactions"] = [["id": 9_000_000_000_000, "accountId": accountID, "type": "expense", "amount": "1.00", "fee": "0.00", "counterparty": "", "description": "", "transactionDate": "2026-09-29", "status": "pending", "categoryId": categoryID]]
        _ = try FinanceLocalStore.apply("/finance/transactions/9000000000000/confirm", method: "POST", body: [:], newID: 9_000_000_000_002, space: &pendingSpace)
        CoreTests.check((pendingSpace["transactions"] as? [[String: Any]])?.first?["status"] as? String == "posted", "确认旧流水允许保留墓碑分类")

        let sync = try ledger(directory, "remap")
        let syncCategory = try sync.writeLocal("/finance/categories", method: "POST", body: ["name": "待删分类", "type": "expense", "color": "#123456"]) as! [String: Any]
        let syncLocalID = FinanceLocalStore.id(syncCategory)
        _ = try sync.writeLocal("/finance/categories/\(syncLocalID)", method: "DELETE", body: [:])
        let createCommand = sync.queue.first!
        try sync.acknowledge(createCommand, result: ["id": 77, "name": "待删分类", "type": "expense", "color": "#123456"])
        CoreTests.check(sync.mappedPath("/finance/categories/\(syncLocalID)") == "/finance/categories/77", "分类 create 回执映射后 delete 使用服务器 ID")
        CoreTests.check(sync.rows("categories").first { FinanceLocalStore.id($0) == 77 }?["deleted"] as? Bool == true, "分类 ID 重映射保留本地墓碑")
        let deleteCommand = sync.queue.first!
        try sync.acknowledge(deleteCommand, result: ["id": 77, "deleted": true])
        CoreTests.check(sync.queue.isEmpty && sync.rows("categories").first { FinanceLocalStore.id($0) == 77 }?["deleted"] as? Bool == true, "分类删除回执保留墓碑并清空队列")
    }

    /// 验证同名重建的真实传输封装与下载期间重放；参数：无；返回值：无；固定 fake 核对旧建→删→新建→流水的独立 ID，多个墓碑不合并，失败抛错或断言，不访问线上。
    static func categoryRecreationSync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("category-recreation-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ledger(directory, "sync")
        let localAccount = try account(store, name: "现金", balance: "100.00")
        let input: [String: Any] = ["name": "同名午餐", "type": "expense", "groupKey": "food", "icon": "fork.knife", "color": "#123456"]
        let old = try store.writeLocal("/finance/categories", method: "POST", body: input) as! [String: Any]
        let oldID = FinanceLocalStore.id(old)
        _ = try store.writeLocal("/finance/categories/\(oldID)", method: "DELETE", body: [:])
        var nextInput = input; nextInput["icon"] = "cup.and.saucer"; nextInput["color"] = "#654321"
        let current = try store.writeLocal("/finance/categories", method: "POST", body: nextInput) as! [String: Any]
        let currentID = FinanceLocalStore.id(current)
        var body = payment(localAccount, key: "recreation-before-download"); body["categoryId"] = currentID
        _ = try store.writeLocal("/finance/transactions", method: "POST", body: body)
        CoreTests.check(oldID != currentID && store.queue.count == 5, "旧建删与新建流水分别排队")
        try store.enable(server: "https://test.invalid/api", profile: Profile(id: 1, account: "categories", nickname: "测试", role: "user"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: "https://test.invalid/api", session: URLSession(configuration: configuration)); api.token = "test"
        defer { StubProtocol.handler = nil }

        // 以下是独立预置的云端资料与命令回执；不从本地 apply 生成结果，避免以被测实现验证自身。
        let remoteAccount: [String: Any] = ["id": 7, "name": "现金", "accountType": "cash", "balance": "100.00", "availableBalance": "100.00", "currency": "CNY", "archived": false]
        var remoteOld = input; remoteOld["id"] = 71; remoteOld["deleted"] = false
        var deletedOld = remoteOld; deletedOld["deleted"] = true
        var ancient = deletedOld; ancient["id"] = 70; ancient["icon"] = "carrot"; ancient["color"] = "#ABCDEF"
        var remoteCurrent = nextInput; remoteCurrent["id"] = 73; remoteCurrent["deleted"] = false
        var deletedCurrent = remoteCurrent; deletedCurrent["deleted"] = true
        var remoteNewest = remoteCurrent; remoteNewest["id"] = 74; remoteNewest["icon"] = "takeoutbag.and.cup.and.straw"
        var remoteTransaction = payment(7, key: "recreation-before-download")
        remoteTransaction["id"] = 91; remoteTransaction["categoryId"] = 73; remoteTransaction["status"] = "posted"
        remoteTransaction["fee"] = "0.00"; remoteTransaction["counterparty"] = ""; remoteTransaction["description"] = ""
        var newestTransaction = remoteTransaction
        newestTransaction["id"] = 92; newestTransaction["categoryId"] = 74; newestTransaction["requestId"] = "recreation-during-download"; newestTransaction["amount"] = "5.00"
        var firstAccount = remoteAccount; firstAccount["balance"] = "80.00"; firstAccount["availableBalance"] = "80.00"
        var lastAccount = firstAccount; lastAccount["balance"] = "75.00"; lastAccount["availableBalance"] = "75.00"
        let firstSnapshot: [String: Any] = ["schemaVersion": 1, "accounts": [firstAccount], "categories": [ancient, deletedOld, remoteCurrent], "transactions": [remoteTransaction], "presets": [], "plans": [:], "installments": []]
        let lastSnapshot: [String: Any] = ["schemaVersion": 1, "accounts": [lastAccount], "categories": [ancient, deletedOld, deletedCurrent, remoteNewest], "transactions": [remoteTransaction, newestTransaction], "presets": [], "plans": [:], "installments": []]
        let server = CategoryRecreationSyncServer(steps: [
            .init(operation: "finance.account.create", id: 0, categoryID: nil, result: remoteAccount),
            .init(operation: "finance.category.create", id: 0, categoryID: nil, result: remoteOld),
            .init(operation: "finance.category.delete", id: 71, categoryID: nil, result: deletedOld),
            .init(operation: "finance.category.create", id: 0, categoryID: nil, result: remoteCurrent),
            .init(operation: "finance.transaction.create", id: 0, categoryID: 73, result: remoteTransaction),
            .init(operation: "finance.category.delete", id: 73, categoryID: nil, result: deletedCurrent),
            .init(operation: "finance.category.create", id: 0, categoryID: nil, result: remoteNewest),
            .init(operation: "finance.transaction.create", id: 0, categoryID: 74, result: newestTransaction)
        ], snapshots: [firstSnapshot, lastSnapshot])
        // 传输回调输入真实编码请求，返回静态脚本回执；身份或顺序错误由替身立即拒绝。
        StubProtocol.handler = { request in try server.respond(request) }
        // 下载钩子输入快照序号、返回值无；首份快照生成后在主线程写入删、建、流水，以触发实际 synchronize 重放。
        server.snapshotHook = { index in
            guard index == 0 else { return }
            let completed = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { completed.signal() }
                do {
                    let duplicate = try store.writeLocal("/finance/categories", method: "POST", body: nextInput) as! [String: Any]
                    CoreTests.check(FinanceLocalStore.id(duplicate) == 73 && store.queue.isEmpty, "上传后活动同名去重忽略较早墓碑")
                    _ = try store.writeLocal("/finance/categories/73", method: "DELETE", body: [:])
                    var newestInput = nextInput; newestInput["icon"] = "takeoutbag.and.cup.and.straw"
                    let newest = try store.writeLocal("/finance/categories", method: "POST", body: newestInput) as! [String: Any]
                    var paymentBody = payment(7, amount: "5.00", key: "recreation-during-download")
                    paymentBody["categoryId"] = FinanceLocalStore.id(newest)
                    _ = try store.writeLocal("/finance/transactions", method: "POST", body: paymentBody)
                } catch { preconditionFailure("下载期间同名重建失败：\(error)") }
            }
            precondition(completed.wait(timeout: .now() + 5) == .success, "下载期间写入未完成")
        }
        try await store.synchronize(api: api)
        CoreTests.check(store.mappedID(oldID, table: "categories") == 71 && store.mappedID(currentID, table: "categories") == 73, "旧墓碑与新分类分别映射服务器 ID")
        let replayed = store.rows("categories")
        let newest = replayed.first { $0["deleted"] as? Bool != true }!
        let newestID = FinanceLocalStore.id(newest)
        CoreTests.check(newestID >= 1_000_000_000_000 && replayed.count == 4 && store.queue.count == 3, "多个同名墓碑和活动快照上重放后保留新临时 ID 与全部墓碑")
        for expected in [ancient, deletedOld, deletedCurrent] {
            let actual = replayed.first { FinanceLocalStore.id($0) == FinanceLocalStore.id(expected) }!
            CoreTests.check(NSDictionary(dictionary: actual).isEqual(to: expected), "重放不合并或恢复墓碑，保留各自名称图标颜色")
        }
        let replayedPayment = store.rows("transactions").first { $0["requestId"] as? String == "recreation-during-download" }!
        CoreTests.check(FinanceLocalStore.id(replayedPayment, "categoryId") == newestID && store.rows("transactions").first { FinanceLocalStore.id($0) == 91 }?["categoryId"] as? Int == 73, "重放中新流水引用新 ID，旧流水仍引用原分类")
        balance(store, 7, "75.00")
        let reopened = try ledger(directory, "sync")
        try await reopened.synchronize(api: api)
        server.checkComplete()
        CoreTests.check(reopened.queue.isEmpty && reopened.mappedID(newestID, table: "categories") == 74, "重启后新分类回执只重映射新身份并清空队列")
        CoreTests.check(reopened.rows("categories").count == 4 && reopened.rows("categories").filter { $0["deleted"] as? Bool != true }.count == 1, "完整快照保留三个同名墓碑和唯一活动分类")
        CoreTests.check(reopened.rows("transactions").first { FinanceLocalStore.id($0) == 91 }?["categoryId"] as? Int == 73 && reopened.rows("transactions").first { FinanceLocalStore.id($0) == 92 }?["categoryId"] as? Int == 74, "快照下载后新旧流水仍分别引用原 ID")
        balance(reopened, 7, "75.00")
    }

    /// 执行离线业务、磁盘恢复及真实传输封装测试；参数：无；返回值：无，失败抛错或断言，不访问实际网络和钥匙串。
    static func run() async throws {
        try categoryTombstones()
        try await categoryRecreationSync()
        try transactionEditing()
        try reimbursementAndCategoryEditing()
        try await loanPlanReading()
        // 使用虚构号码验证本机保存、同步脱敏及快照合并，防止保存或下载后丢失完整号码。
        let card = try AccountCard(id: "card-test", name: "测试卡", maskedAccountNumber: "1234-5678 9012 3456").normalized()
        precondition(card.maskedAccountNumber == "1234567890123456")
        let decoded = try JSONDecoder().decode(AccountCard.self, from: JSONEncoder().encode(card))
        precondition(decoded == card)
        let localCards: [[String: Any]] = [["id": card.id, "name": card.name, "maskedAccountNumber": card.maskedAccountNumber]]
        let cardUpload = FinanceLocalStore.cardSyncBody(["cards": localCards])
        let uploaded = cardUpload["cards"] as! [[String: Any]]
        precondition(uploaded[0]["maskedAccountNumber"] as? String == "**** 3456")
        let merged = FinanceLocalStore.preservingLocalCardNumbers(remote: cardUpload, local: ["cards": localCards])
        precondition((merged["cards"] as! [[String: Any]])[0]["maskedAccountNumber"] as? String == card.maskedAccountNumber)
        var changedCards = uploaded; changedCards[0]["maskedAccountNumber"] = "**** 9876"
        let replaced = FinanceLocalStore.preservingLocalCardNumbers(remote: ["cards": changedCards], local: ["cards": localCards])
        precondition((replaced["cards"] as! [[String: Any]])[0]["maskedAccountNumber"] as? String == "**** 9876")
        let deleted = FinanceLocalStore.preservingLocalCardNumbers(remote: ["cards": [[String: Any]]()], local: ["cards": localCards])
        precondition((deleted["cards"] as! [[String: Any]]).isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 在独立账本中乱序补录，验证本机负 ID 不改变时分排序、午夜与无时间记录顺序以及分页结果。
        let orderingStore = try ledger(directory, "ordering")
        let orderingAccount = try account(orderingStore, name: "排序钱包", balance: "100.00")
        var orderingIDs: [Int] = []
        for (index, clock) in ["12:08", "11:56", "09:57", "", "00:00"].enumerated() {
            var body = payment(orderingAccount, amount: "1.00", key: "ordering-\(index)")
            body["transactionTime"] = clock
            let row = try orderingStore.writeLocal("/finance/transactions", method: "POST", body: body) as! [String: Any]
            orderingIDs.append(FinanceLocalStore.id(row))
        }
        let ordered = try orderingStore.transactions([:], paginated: true)
        let expectedOrder = [orderingIDs[0], orderingIDs[1], orderingIDs[2], orderingIDs[4], orderingIDs[3]]
        // 映射回调输入一笔流水，返回其 ID，用于与业务时间决定的预期顺序比较。
        CoreTests.check(ordered.map { FinanceLocalStore.id($0) } == expectedOrder, "本地流水按交易时分倒序")
        let orderingPage = try orderingStore.transactions(["offset": "1", "limit": "2"], paginated: true)
        // 映射回调输入分页流水，返回其 ID，验证排序发生在截取分页之前。
        CoreTests.check(orderingPage.map { FinanceLocalStore.id($0) } == Array(expectedOrder[1...2]), "本地交易时间分页")

        let store = try ledger(directory, "guest")
        let a = try account(store, name: "现金", balance: "100.00"), b = try account(store, name: "银行卡", balance: "10.00")
        var expense = payment(a); expense["discount"] = "2.00"
        let expenseRow = try store.writeLocal("/finance/transactions", method: "POST", body: expense) as! [String: Any]
        balance(store, a, "82.00")
        let count = store.queue.count
        _ = try store.writeLocal("/finance/transactions", method: "POST", body: expense)
        CoreTests.check(store.queue.count == count, "离线重复提交不重复排队或扣款")
        var changed = expense; changed["amount"] = "21.00"
        do { _ = try store.writeLocal("/finance/transactions", method: "POST", body: changed); CoreTests.check(false, "异内容幂等冲突") } catch { CoreTests.check(true, "同键异内容拒绝") }
        var transfer = payment(a, kind: "transfer", amount: "30.00", key: "offline-transfer-001")
        transfer["targetAccountId"] = b; transfer["fee"] = "1.00"; transfer["rebate"] = "2.00"
        let transferRow = try store.writeLocal("/finance/transactions", method: "POST", body: transfer) as! [String: Any]
        balance(store, a, "53.00"); balance(store, b, "40.00")
        let sums = try store.summary(["startDate": "2026-09-01", "endDate": "2026-09-30"])
        CoreTests.check(sums["expense"] == "19.00" && sums["income"] == "2.00", "手续费与返现统计不计转账本金")
        let id = FinanceLocalStore.id(transferRow)
        _ = try store.writeLocal("/finance/transactions/\(id)", method: "DELETE", body: [:])
        balance(store, a, "82.00"); balance(store, b, "10.00")
        _ = try store.writeLocal("/finance/transactions/\(id)", method: "DELETE", body: [:])
        balance(store, a, "82.00")
        let expenseID = FinanceLocalStore.id(expenseRow)
        _ = try store.writeLocal("/finance/transactions/\(expenseID)/refund", method: "POST", body: ["requestId": "offline-refund-001", "amount": "8.00", "transactionDate": "2026-09-29", "description": ""])
        balance(store, a, "90.00")
        _ = try store.writeLocal("/finance/accounts/\(a)", method: "PATCH", body: ["includeInNetWorth": false, "notes": ""])
        CoreTests.check(store.rows("accounts").first { FinanceLocalStore.id($0) == a }?["includeInNetWorth"] as? Bool == false, "离线 PATCH 保留 false 与空值")
        let templateInput: [String: Any] = ["key": "offline-template-001", "name": "午餐", "transaction": payment(a, amount: "5.00", key: "template-input-001")]
        _ = try store.writeLocal("/finance/presets", method: "POST", body: templateInput)
        _ = try store.writeLocal("/finance/presets", method: "POST", body: templateInput)
        CoreTests.check(store.rows("presets").count == 1, "模板重复保存本机去重")
        balance(store, a, "90.00")
        let presetBytes = try FinanceLocalStore.envelope(store.rows("presets"))
        let presetModels = try JSONDecoder().decode(Envelope<[FinancePreset]>.self, from: presetBytes)
        CoreTests.check(presetModels.data.first?.transaction.amount == "5.00", "离线模板兼容原有模型且不提前扣款")
        let restored = try ledger(directory, "guest")
        balance(restored, a, "90.00")
        CoreTests.check(restored.queue.count == store.queue.count, "模拟强退重开保留完整上传队列")
        let before = restored.document
        var invalid = payment(a, kind: "transfer", key: "offline-bad-transfer"); invalid["targetAccountId"] = 444
        do { _ = try restored.writeLocal("/finance/transactions", method: "POST", body: invalid); CoreTests.check(false, "非法关联必须拒绝") } catch { CoreTests.check(NSDictionary(dictionary: before).isEqual(to: restored.document), "失败操作不留下半笔转账或队列") }
        let user = Profile(id: 1, account: "one", nickname: "用户", role: "user")
        try restored.enable(server: "https://test.invalid/api", profile: user)
        let ownedCount = restored.queue.count
        try restored.useGuest()
        CoreTests.check(restored.rows("accounts").isEmpty && restored.queue.isEmpty, "退出隐藏账号数据但不删除")
        try restored.enable(server: "https://test.invalid/api", profile: Profile(id: 2, account: "two", nickname: "另一用户", role: "user"))
        CoreTests.check(restored.rows("accounts").isEmpty && restored.queue.isEmpty, "另一账号不会收到旧账号队列")
        try restored.useGuest(); try restored.enable(server: "https://test.invalid/api", profile: user)
        CoreTests.check(restored.queue.count == ownedCount, "重新登录恢复原账号待同步操作")
        try restored.enable(server: "https://another.invalid/api", profile: user)
        CoreTests.check(restored.rows("accounts").isEmpty, "同 ID 不同服务器仍隔离")

        let sync = try ledger(directory, "sync")
        let localAccount = try account(sync, name: "现金", balance: "100.00")
        let category = try sync.writeLocal("/finance/categories", method: "POST", body: ["name": "午餐", "type": "expense", "color": "#123456"]) as! [String: Any]
        var body = payment(localAccount); body["categoryId"] = FinanceLocalStore.id(category)
        _ = try sync.writeLocal("/finance/transactions", method: "POST", body: body)
        try sync.enable(server: "https://test.invalid/api", profile: user)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: "https://test.invalid/api", session: URLSession(configuration: configuration)); api.token = "test"
        let server = OfflineSyncServer()
        // 传输回调输入请求，输出测试响应；所有服务端数据由独立替身生成。
        StubProtocol.handler = { request in try server.respond(request) }
        do { try await sync.synchronize(api: api); CoreTests.check(false, "首次提交后应模拟断线") } catch { CoreTests.check(sync.queue.count == 1, "响应丢失仅保留未确认命令") }
        let recovered = try ledger(directory, "sync")
        try await recovered.synchronize(api: api)
        CoreTests.check(server.creates == 1 && server.payments == 1, "跨重启重试仅开户一次并扣款一次")
        balance(recovered, 7, "80.00")
        CoreTests.check(recovered.rows("accounts").count == 2, "同名本机与云端账户分别保留")
        CoreTests.check(recovered.queue.isEmpty && recovered.lastSync != nil, "完整快照成功后显示已同步")
        CoreTests.check(recovered.mappedID(localAccount, table: "accounts") == 7, "旧界面 ID 继续解析到正确账户")
        var duplicate = body; duplicate["accountId"] = 7; duplicate["categoryId"] = 11
        _ = try recovered.writeLocal("/finance/transactions", method: "POST", body: duplicate)
        CoreTests.check(recovered.queue.isEmpty, "快照下载后重试同一次录入仍不重复排队")
        let revision = recovered.revision
        try await recovered.synchronize(api: api)
        CoreTests.check(recovered.revision == revision, "无变化同步不重置流水列表")

        // 下载回调无输入和返回；服务器快照已生成后在主线程新增流水，验证同步不能覆盖并发本地写入。
        server.snapshotHook = {
            let completed = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { completed.signal() }
                do { _ = try recovered.writeLocal("/finance/transactions", method: "POST", body: payment(7, kind: "income", amount: "5.00", key: "during-download-001")) }
                catch { preconditionFailure("并发本机写入失败：\(error)") }
            }
            precondition(completed.wait(timeout: .now() + 5) == .success)
        }
        try await recovered.synchronize(api: api)
        balance(recovered, 7, "85.00")
        CoreTests.check(recovered.queue.count == 1, "下载期间新增记录保留且只投影一次")
        server.snapshotHook = nil
        let isolated = try ledger(directory, "switch-during-sync")
        try isolated.enable(server: "https://test.invalid/api", profile: user)
        // 下载回调无输入和返回；模拟用户在请求过程中退出，旧账号响应不能落入游客空间。
        server.snapshotHook = {
            let completed = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { completed.signal() }
                do { try isolated.useGuest() } catch { preconditionFailure("测试退出失败：\(error)") }
            }
            precondition(completed.wait(timeout: .now() + 5) == .success)
        }
        do { try await isolated.synchronize(api: api); CoreTests.check(false, "跨空间响应必须丢弃") }
        catch { CoreTests.check(isolated.activeKey == "guest" && isolated.rows("accounts").isEmpty, "同步期间退出不会将云端数据写入游客账本") }
        server.snapshotHook = nil
        api.localFinance = recovered
        // 离线读取回调输入请求，无正常返回；任何意外网络访问都会让断言失败。
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let accounts: [FinancialAccount] = try await api.request("/finance/accounts")
        let overview: FinanceOverview = try await api.request("/finance/overview")
        CoreTests.check(accounts.count == 2 && overview.totalAssets == "585.00", "断网查询完全使用本机完整账本")
        let corrupt = directory.appendingPathComponent("corrupt.sqlite"); try Data("broken database".utf8).write(to: corrupt)
        do { _ = try FinanceLocalStore(url: corrupt); CoreTests.check(false, "损坏数据库不能重建覆盖") } catch { CoreTests.check(try Data(contentsOf: corrupt) == Data("broken database".utf8), "数据库损坏保留原文件") }
    }
}
