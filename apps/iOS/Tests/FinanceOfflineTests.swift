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
    /// 执行离线业务、磁盘恢复及真实传输封装测试；参数：无；返回值：无，失败抛错或断言，不访问实际网络和钥匙串。
    static func run() async throws {
        try transactionEditing()
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
