import Foundation

/// 固定协议脚本；不模拟记账业务，只核对请求顺序、目标编号及重试正文。
final class RebateSyncScript: @unchecked Sendable {
    struct Step {
        let operation: String?
        let id: Int
        let status: Int
        let response: [String: Any]
        var disconnect = false
    }
    private let lock = NSLock()
    private let steps: [Step]
    private var index = 0
    private(set) var payloads: [[String: Any]] = []
    var hook: ((Int) -> Void)?

    /// 初始化脚本；参数：steps 为按顺序返回的命令或快照响应；返回值：替身实例，无网络及磁盘副作用。
    init(_ steps: [Step]) { self.steps = steps }

    /// 核对并响应请求；参数：request 为真实传输层请求；返回值：HTTP 状态及 JSON，disconnect 步骤抛断网错误；未预期请求令测试失败。
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        precondition(index < steps.count, "出现脚本外的同步请求")
        let current = index, step = steps[index]; index += 1
        if let operation = step.operation {
            precondition(request.url?.path.hasSuffix("/commands") == true && request.httpMethod == "POST")
            let payload = try CoreTests.body(request)
            precondition(payload["operation"] as? String == operation && (payload["id"] as? NSNumber)?.intValue == step.id, "必须上传正确的云端流水编号")
            payloads.append(payload)
        } else {
            precondition(request.url?.path.hasSuffix("/snapshot") == true && request.httpMethod == "GET")
        }
        hook?(current)
        if step.disconnect { throw URLError(.networkConnectionLost) }
        return (step.status, try JSONSerialization.data(withJSONObject: step.response))
    }

    /// 验证所有步骤完成；参数：无；返回值：无；未消费的步骤令测试失败。
    func checkComplete() {
        lock.lock(); defer { lock.unlock() }
        precondition(index == steps.count, "返现同步脚本未完整执行")
    }
}

extension FinanceOfflineTests {
    /// 创建返现同步夹具；参数：directory/name 为独立测试数据库位置，entry 为 create/update/confirm 生成入口；返回值：账本、本机父 ID、本机子 ID；仅写测试目录，不访问真实服务。
    static func rebateFixture(_ directory: URL, name: String, entry: String = "create") throws -> (FinanceLocalStore, Int, Int) {
        let store = try ledger(directory, name)
        let a = try account(store, name: "现金", balance: "100.00")
        try store.acknowledge(store.queue[0], result: ["id": 7])
        let b = try account(store, name: "银行卡", balance: "0.00")
        try store.acknowledge(store.queue[0], result: ["id": 9])
        var input = payment(store.mappedID(a, table: "accounts"), kind: "transfer", amount: "20.00", key: "rebate-fixture-transfer")
        input["targetAccountId"] = store.mappedID(b, table: "accounts")
        if entry != "update" { input["rebate"] = "2.00"; input["rebatePending"] = true }
        let parentID: Int
        if entry == "confirm" {
            // 草稿视为云端已下载数据；只排队确认，验证确认父流水生成子项的入口。
            var next = store.space
            _ = try FinanceLocalStore.apply("/finance/transactions", method: "POST", body: input, newID: 21, space: &next, draft: true)
            try store.saveSpace(next)
            parentID = 21
            _ = try store.writeLocal("/finance/transactions/21/confirm", method: "POST", body: [:])
        } else {
            let parent = try store.writeLocal("/finance/transactions", method: "POST", body: input) as! [String: Any]
            parentID = FinanceLocalStore.id(parent)
            if entry == "update" {
                try store.acknowledge(store.queue[0], result: ["id": 21])
                _ = try store.writeLocal("/finance/transactions/21", method: "PATCH", body: ["rebate": "2.00", "rebatePending": true])
            }
        }
        let childID = FinanceLocalStore.id(store.rows("transactions").first { FinanceLocalStore.id($0, "rebateParentId") != 0 }!)
        _ = try store.writeLocal("/finance/transactions/\(childID)/confirm", method: "POST", body: [:])
        _ = try store.writeLocal("/finance/transactions/\(childID)", method: "PATCH", body: ["description": "本机最新备注"])
        try store.enable(server: "https://test.invalid/api", profile: Profile(id: 1, account: "one", nickname: "用户", role: "user"))
        return (store, parentID, childID)
    }

    /// 构造独立云端快照；参数：childID 为云子编号，duplicate 表示返回歧义关联；返回值：完整信封，不读取本机投影，金额刻意不同以检测提前覆盖。
    static func rebateSnapshot(childID: Int = 22, duplicate: Bool = false) -> [String: Any] {
        var children: [[String: Any]] = [["id": childID, "rebateParentId": 21, "status": "posted", "description": "云端备注"]]
        if duplicate { children.append(["id": 23, "rebateParentId": 21]) }
        return ["data": ["schemaVersion": 1, "accounts": [["id": 7, "balance": "999.00"]], "categories": [[String: Any]](), "transactions": [["id": 21]] + children, "presets": [[String: Any]](), "plans": [:], "installments": []] as [String: Any]]
    }

    /// 为脚本创建认证客户端；参数：script 为固定协议响应器；返回值：仅使用 URLProtocol 的客户端，不访问外网。
    static func rebateAPI(_ script: RebateSyncScript) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: "https://test.invalid/api", session: URLSession(configuration: configuration)); api.token = "test"
        // 传输回调输入请求，返回脚本响应；不读取真实账号或凭证。
        StubProtocol.handler = { request in try script.respond(request) }
        return api
    }

    /// 验证新回执和旧协议的返现同步闭环；参数：无；返回值：无；失败抛错或断言，所有数据库写入限临时目录。
    static func rebateSyncRegression() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rebate-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in ["create", "update", "confirm"] {
            let (store, _, childID) = try rebateFixture(directory, name: entry, entry: entry)
            let operation = "finance.transaction." + entry
            let script = RebateSyncScript([
                .init(operation: operation, id: entry == "create" ? 0 : 21, status: 200, response: ["data": ["id": 21, "syncRebateTransactionId": 22]]),
                .init(operation: "finance.transaction.confirm", id: 22, status: 200, response: ["data": ["id": 22]]),
                .init(operation: "finance.transaction.update", id: 22, status: 200, response: ["data": ["id": 22]]),
                .init(operation: nil, id: 0, status: 200, response: rebateSnapshot())
            ])
            try await store.synchronize(api: rebateAPI(script))
            script.checkComplete()
            CoreTests.check(store.queue.isEmpty && store.lastSync != nil, "三种父操作回执均解除返现队列阻塞")
            CoreTests.check(store.mappedID(childID, table: "transactions") == 22, "子流水别名已保存")
            let restored = try ledger(directory, entry)
            CoreTests.check(restored.mappedID(childID, table: "transactions") == 22, "重启保留返现编号映射")
        }

        // 旧版父回执已确认、命令已移除；重启后只补映射，故意令子上传失败以观察快照未覆盖本机。
        let (old, _, childID) = try rebateFixture(directory, name: "old")
        try old.acknowledge(old.queue[0], result: ["id": 21])
        let store = try ledger(directory, "old")
        let originalQueue = store.queue
        let script = RebateSyncScript([
            .init(operation: nil, id: 0, status: 200, response: rebateSnapshot()),
            .init(operation: "finance.transaction.confirm", id: 22, status: 409, response: ["message": "财务操作冲突"])
        ])
        do { try await store.synchronize(api: rebateAPI(script)); preconditionFailure("应保留冲突命令") }
        catch {
            CoreTests.check((error as? APIError)?.status == 409, "诊断保留 HTTP 状态")
            CoreTests.check(error.localizedDescription.contains("确认流水") && error.localizedDescription.contains("22"), "诊断包含失败操作和云端编号")
        }
        script.checkComplete()
        CoreTests.check(NSArray(array: originalQueue).isEqual(to: store.queue), "补映射及409不改变任何原始队列命令")
        balance(store, 7, "82.00")
        CoreTests.check(store.lastSync == nil && store.rows("transactions").first { FinanceLocalStore.id($0) == 22 }?["description"] as? String == "本机最新备注", "补映射不安装云端余额或旧备注")
        let reopened = try ledger(directory, "old")
        CoreTests.check(reopened.mappedID(childID, table: "transactions") == 22 && reopened.queue.count == 2, "补映射独立持久化且失败项保留")
        let retry = RebateSyncScript([
            .init(operation: "finance.transaction.confirm", id: 22, status: 200, response: ["data": ["id": 22]]),
            .init(operation: "finance.transaction.update", id: 22, status: 200, response: ["data": ["id": 22]]),
            .init(operation: nil, id: 0, status: 200, response: rebateSnapshot())
        ])
        try await reopened.synchronize(api: rebateAPI(retry)); retry.checkComplete()
        CoreTests.check(reopened.queue.isEmpty, "已卡队列重启后继续成功同步")

        // 父命令响应丢失时，第一次不确认；下一次必须以完全相同的 operationId/正文重放。
        let (lost, _, _) = try rebateFixture(directory, name: "lost")
        let lossScript = RebateSyncScript([
            .init(operation: "finance.transaction.create", id: 0, status: 200, response: [:], disconnect: true),
            .init(operation: "finance.transaction.create", id: 0, status: 200, response: ["data": ["id": 21]]),
            .init(operation: nil, id: 0, status: 200, response: rebateSnapshot()),
            .init(operation: "finance.transaction.confirm", id: 22, status: 200, response: ["data": ["id": 22]]),
            .init(operation: "finance.transaction.update", id: 22, status: 200, response: ["data": ["id": 22]]),
            .init(operation: nil, id: 0, status: 200, response: rebateSnapshot())
        ])
        let api = rebateAPI(lossScript)
        do { try await lost.synchronize(api: api); preconditionFailure("应模拟响应丢失") } catch { CoreTests.check(lost.queue.count == 3, "未确认父命令及后续命令完整保留") }
        let lostRestarted = try ledger(directory, "lost")
        try await lostRestarted.synchronize(api: api); lossScript.checkComplete()
        CoreTests.check(NSDictionary(dictionary: lossScript.payloads[0]).isEqual(to: lossScript.payloads[1]), "父命令重试指纹输入不变")

        try await rebateRecoverySafety(directory)
    }

    /// 验证恢复失败与授权失效的安全边界；参数：directory 为临时目录；返回值：无；覆盖缺失、歧义、普通404、并发编辑和取消，不访问真实网络。
    static func rebateRecoverySafety(_ directory: URL) async throws {
        var missing = rebateSnapshot()
        var missingData = missing["data"] as! [String: Any]; missingData["transactions"] = [["id": 21]]; missing["data"] = missingData
        for (name, response) in [("missing", missing), ("duplicate", rebateSnapshot(duplicate: true)), ("invalid", ["data": ["schemaVersion": 2]])] {
            let (store, _, _) = try rebateFixture(directory, name: name)
            try store.acknowledge(store.queue[0], result: ["id": 21])
            let before = store.document
            let script = RebateSyncScript([.init(operation: nil, id: 0, status: 200, response: response)])
            do { try await store.synchronize(api: rebateAPI(script)); preconditionFailure("无可靠关联不得恢复") }
            catch { CoreTests.check(NSDictionary(dictionary: before).isEqual(to: store.document), "失败恢复不改变账本或队列") }
            script.checkComplete()
        }
        let (ordinary, _, _) = try rebateFixture(directory, name: "ordinary")
        try ordinary.acknowledge(ordinary.queue[0], result: ["id": 21, "syncRebateTransactionId": 22])
        let before = ordinary.document
        let notFound = RebateSyncScript([.init(operation: "finance.transaction.confirm", id: 22, status: 404, response: ["message": "财务记录不存在"])])
        do { try await ordinary.synchronize(api: rebateAPI(notFound)); preconditionFailure("普通404不可跳过") }
        catch { CoreTests.check((error as? APIError)?.status == 404 && NSDictionary(dictionary: before).isEqual(to: ordinary.document), "真实云端ID不存在时保留原操作且不拉快照") }
        notFound.checkComplete()

        for action in ["edit", "pause", "token", "server", "account"] {
            let (store, _, childID) = try rebateFixture(directory, name: "during-" + action)
            try store.acknowledge(store.queue[0], result: ["id": 21])
            let steps: [RebateSyncScript.Step] = [.init(operation: nil, id: 0, status: 200, response: rebateSnapshot())] + (action == "edit" ? [.init(operation: "finance.transaction.confirm", id: 22, status: 409, response: ["message": "财务操作冲突"])] : [])
            let script = RebateSyncScript(steps), api = rebateAPI(script)
            // 请求钩子输入步骤序号、返回无；在恢复网络等待期间模拟主线程写入或授权变化。
            script.hook = { index in
                guard index == 0 else { return }
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    defer { done.signal() }
                    do {
                        switch action {
                        case "edit": _ = try store.writeLocal("/finance/transactions/\(childID)", method: "PATCH", body: ["description": "网络等待期间新增备注"])
                        case "pause": try store.pauseSync()
                        case "token": api.token = "changed"
                        case "server": api.baseURL = "https://another.invalid/api"
                        default:
                            var document = store.document, spaces = store.spaces
                            spaces["other-account"] = FinanceLocalStore.emptySpace()
                            document["active"] = "other-account"; document["spaces"] = spaces
                            try store.commit(document)
                        }
                    } catch { preconditionFailure("测试并发操作失败：\(error)") }
                }
                precondition(done.wait(timeout: .now() + 5) == .success)
            }
            do { try await store.synchronize(api: api); preconditionFailure("并发测试应终止同步") }
            catch {
                if action == "edit" {
                    CoreTests.check(store.queue.count == 3 && store.rows("transactions").first { FinanceLocalStore.id($0) == 22 }?["description"] as? String == "网络等待期间新增备注", "恢复保留并发追加命令及最新输入")
                } else {
                    CoreTests.check(error is CancellationError && store.syncError == nil, "失效授权不落盘旧响应或旧错误")
                    CoreTests.check(store.mappedID(childID, table: "transactions") == childID, "取消期间不建立旧会话映射")
                }
            }
            script.checkComplete()
        }
    }
}
