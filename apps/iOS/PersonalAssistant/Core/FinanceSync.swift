import Foundation

extension FinanceLocalStore {
    /// 财务请求统一入口；参数：path/method/body/query 沿用现有 API，api 用于绕过本地层的认证传输；返回值：API 信封；本地保存先完成，复杂操作联网失败保留表单输入。
    func handle(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem], api: APIClient) async throws -> Data {
        let normalizedPath = mappedPath(path), payload = mappedBody(body ?? [:])
        let items = query.map { item -> URLQueryItem in
            guard let value = item.value.flatMap(Int.init), ["accountId", "categoryId"].contains(item.name) else { return item }
            return URLQueryItem(name: item.name, value: String(mappedID(value, table: item.name == "accountId" ? "accounts" : "categories")))
        }
        if method == "GET", let value = try readLocal(normalizedPath, query: items) { return try Self.envelope(value) }
        if method != "GET", supportsLocal(normalizedPath, method: method, body: payload) { return try Self.envelope(writeLocal(normalizedPath, method: method, body: payload)) }
        guard enabled, api.token != nil else { throw Self.failure("此功能需要开启同步并联网使用") }
        let key = activeKey
        // 专用服务端计算不能使用尚未上传的临时 ID，也不能越过本地待处理操作。
        if !queue.isEmpty { try await synchronize(api: api) }
        guard activeKey == key, queue.isEmpty, !syncing else { throw Self.failure("正在同步，请稍后重试") }
        let remotePath = mappedPath(path), remoteBody = mappedBody(body ?? [:])
        if method == "GET" || remotePath.hasSuffix("preview") || remotePath == "/finance/recurring/materialize" {
            let result = try await api.networkData(remotePath, method: method, body: body == nil ? nil : remoteBody, query: items)
            guard activeKey == key else { throw CancellationError() }
            if method != "GET", !remotePath.hasSuffix("preview") { try await synchronize(api: api) }
            return result
        }
        // 复杂写入同样先保存持久命令，响应丢失不会重复修改服务器；本地投影由随后快照更新。
        var next = space, commands = queue
        let operationID = UUID().uuidString
        commands.append(["operationId": operationID, "path": remotePath, "method": method, "body": remoteBody, "localID": 0, "remoteOnly": true])
        next["queue"] = commands; try saveSpace(next)
        try await synchronize(api: api)
        guard activeKey == key, let result = (space["results"] as? [String: Any])?[operationID] else { throw Self.failure("操作已保存，等待同步") }
        return try Self.envelope(result)
    }

    /// 查找旧本机 ID 对应的服务器 ID；参数：id 为旧标识，table 为集合；返回值：映射后标识，无映射时保持原值。
    func mappedID(_ id: Int, table: String) -> Int { (space["aliases"] as? [String: Int])?[table + ":" + String(id)] ?? id }
    /// 规范化路径上的历史本机 ID；参数：path 为 API 路径；返回值：仍引用同一业务对象的路径。
    func mappedPath(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 2, let id = Int(parts[2]) { parts[2] = String(mappedID(id, table: parts[1] == "installments" ? "transactions" : parts[1])) }
        return "/" + parts.joined(separator: "/")
    }
    /// 映射正文中的业务引用；参数：body 为 JSON 字典；返回值：映射后的副本，不修改金额和无关整数。
    func mappedBody(_ body: [String: Any]) -> [String: Any] {
        var result = body
        for (key, value) in body {
            if let table = Self.referenceTable(key), let number = value as? NSNumber { result[key] = mappedID(number.intValue, table: table) }
            else if let nested = value as? [String: Any] { result[key] = mappedBody(nested) }
        }
        return result
    }
    /// 返回外键所属集合；参数：key 为 JSON 字段；返回值：集合名或 nil，无副作用。
    static func referenceTable(_ key: String) -> String? {
        switch key {
        case "accountId", "targetAccountId", "rebateAccountId", "loanReceivingAccountId": return "accounts"
        case "categoryId": return "categories"
        case "refundParentId", "rebateParentId", "installmentParentId": return "transactions"
        default: return nil
        }
    }
    /// 将端点映射到后端允许操作；参数：path/method 为固定业务路由；返回值：操作名和目标 ID，不支持时抛错。
    static func command(_ path: String, method: String) throws -> (String, Int) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw failure("同步端点无效") }
        let id = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        let resource = ["accounts": "account", "categories": "category", "transactions": "transaction", "presets": "preset", "installments": "installment"][parts[1]]
        guard let resource else { throw failure("同步操作不支持") }
        var action = method == "PATCH" ? "update" : method == "DELETE" ? "delete" : "create"
        if method == "DELETE" && resource == "account" { action = "archive" }
        if parts.count == 4 {
            switch parts[3] {
            case "confirm", "void", "refund", "finish": action = parts[3]
            case "installment": return ("finance.installment.create", id)
            case "loan-adjustments": return ("finance.loan.adjustment.save", id)
            default: throw failure("同步操作不支持")
            }
        }
        return ("finance.\(resource).\(action)", id)
    }

    /// 执行上传后下载的自动同步；参数：api 为当前认证连接；返回值：无；每个回执立即持久化，跨账号响应拒绝应用，错误保留队列供原操作重试。
    func synchronize(api: APIClient) async throws {
        guard enabled, api.token != nil else { return }
        guard !syncing else { return }
        let key = activeKey, server = api.baseURL, token = api.token
        let authorization = syncAuthorization
        guard space["server"] as? String == server else { throw Self.failure("账号与服务器不匹配") }
        syncing = true; syncError = nil
        defer { syncing = false }
        var failedCommand: [String: Any]?
        var phase = "上传"
        do {
            // 先校验整批关联记录映射，避免上传部分命令后才发现完整本机计划无法安全同步。
            for command in queue { try Self.validatePlanSync(command) }
            // 上传过程允许界面继续写本机；按原有队列顺序处理，最多一批 200 项避免长期占用前台任务。
            for _ in 0..<200 {
                guard let pending = queue.first else { break }
                failedCommand = pending; phase = "上传"
                guard enabled, syncAuthorization == authorization else { throw CancellationError() }
                for command in queue { try Self.validatePlanSync(command) }
                // 旧回执没有返现编号时，先补身份再发送子项；不能等待队列清空，也不能安装快照覆盖未上传内容。
                if try !unresolvedRebateReferences(pending).isEmpty {
                    phase = "恢复返现关联"
                    let data = try await api.networkData("/finance/sync/snapshot", method: "GET", body: nil)
                    guard enabled, syncAuthorization == authorization, activeKey == key, api.baseURL == server, api.token == token else { throw CancellationError() }
                    try recoverRebateReferences(pending, data: data)
                    phase = "上传"
                }
                guard let path = pending["path"] as? String, let method = pending["method"] as? String, let operationID = pending["operationId"] as? String else { throw Self.failure("本机同步队列损坏") }
                let (operation, id) = try Self.command(mappedPath(path), method: method)
                let payload: [String: Any] = ["operationId": operationID, "operation": operation, "id": id, "body": Self.cardSyncBody(mappedBody(pending["body"] as? [String: Any] ?? [:]))]
                let data = try await api.networkData("/finance/sync/commands", method: "POST", body: payload)
                guard enabled, syncAuthorization == authorization, activeKey == key, api.baseURL == server, api.token == token else { throw CancellationError() }
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = response["data"] else { throw Self.failure("同步响应无效") }
                try acknowledge(pending, result: value)
            }
            // 队列未清空时不下载覆盖乐观投影；下一轮继续上传，避免同时重放已确认但快照尚未覆盖的命令。
            guard queue.isEmpty else { return }
            failedCommand = nil; phase = "下载"
            let data = try await api.networkData("/finance/sync/snapshot", method: "GET", body: nil)
            guard enabled, syncAuthorization == authorization, activeKey == key, api.baseURL == server, api.token == token else { throw CancellationError() }
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], let snapshot = envelope["data"] as? [String: Any], snapshot["schemaVersion"] as? Int == 1 else { throw Self.failure("服务器尚不支持本机同步") }
            var next = space
            for table in ["accounts", "categories", "transactions", "presets"] {
                guard var records = snapshot[table] as? [[String: Any]] else { throw Self.failure("同步快照不完整") }
                // 保留本机创建时的幂等输入，用于上传成功后界面仍重试同一次录入的情况；不覆盖云端业务字段。
                let previous = next[table] as? [[String: Any]] ?? []
                if table == "accounts" {
                    // 云端只返回尾号；仅同账户、同卡片且尾号一致时保留本机完整号码，远端改号或删卡正常生效。
                    for index in records.indices {
                        guard let local = previous.first(where: { Self.id($0) == Self.id(records[index]) }) else { continue }
                        records[index] = Self.preservingLocalCardNumbers(remote: records[index], local: local)
                    }
                }
                if table == "transactions" {
                    var aliases = next["aliases"] as? [String: Int] ?? [:]
                    for row in records where Self.id(row, "rebateParentId") != 0 {
                        if let local = previous.first(where: { Self.id($0, "rebateParentId") == Self.id(row, "rebateParentId") && Self.id($0) >= 1_000_000_000_000 }) {
                            aliases["transactions:" + String(Self.id(local))] = Self.id(row)
                        }
                    }
                    next["aliases"] = aliases
                }
                var originalInputs: [Int: Any] = [:]
                for row in previous { if let input = row["localInput"] { originalInputs[Self.id(row)] = input } }
                for index in records.indices { if let input = originalInputs[Self.id(records[index])] { records[index]["localInput"] = input } }
                next[table] = records
            }
            next["plans"] = snapshot["plans"] ?? [:]; next["installments"] = snapshot["installments"] ?? []
            // 下载等待期间新建的本地命令尚未上传，必须在新快照上重放，不能被云端覆盖。
            for pending in queue where pending["remoteOnly"] as? Bool != true {
                _ = try Self.apply(mappedPath(pending["path"] as? String ?? ""), method: pending["method"] as? String ?? "POST", body: mappedBody(pending["body"] as? [String: Any] ?? [:]), newID: Self.id(pending, "localID"), space: &next)
            }
            next["lastSync"] = Date.now.timeIntervalSince1970
            try saveSpace(next)
        } catch {
            guard !(error is CancellationError), enabled, syncAuthorization == authorization,
                  activeKey == key, api.baseURL == server, api.token == token else { throw CancellationError() }
            let reported = syncFailure(error, pending: failedCommand, phase: phase)
            syncError = reported.localizedDescription
            throw reported
        }
    }

    /// 查找命令引用的未映射返现；参数：pending 为原始队列命令；返回值：本机子 ID 到云端父 ID 的关系，无关命令返回空；关系歧义或父编号未确认时抛错，不修改账本。
    func unresolvedRebateReferences(_ pending: [String: Any]) throws -> [Int: Int] {
        var references = Self.transactionReferences(pending["body"] as? [String: Any] ?? [:])
        let parts = (pending["path"] as? String ?? "").split(separator: "/")
        if parts.count > 2, ["transactions", "installments"].contains(String(parts[1])), let id = Int(parts[2]) { references.insert(id) }
        var unresolved: [Int: Int] = [:]
        for localID in references where localID >= 1_000_000_000_000 && mappedID(localID, table: "transactions") == localID {
            let candidates = rows("transactions").filter { Self.id($0) == localID }
            guard candidates.count <= 1 else { throw Self.failure("本机返现编号重复") }
            guard let child = candidates.first, Self.id(child, "rebateParentId") != 0 else { continue }
            let parentID = mappedID(Self.id(child, "rebateParentId"), table: "transactions")
            guard parentID > 0, parentID < 1_000_000_000_000 else { throw Self.failure("返现原转账尚未同步") }
            guard rows("transactions").filter({ mappedID(Self.id($0, "rebateParentId"), table: "transactions") == parentID }).count == 1 else {
                throw Self.failure("本机返现关联不唯一")
            }
            unresolved[localID] = parentID
        }
        return unresolved
    }

    /// 提取正文中的流水引用；参数：body 为原始 JSON 字典；返回值：已知流水外键 ID 集合，不包含金额和其他整数，无副作用。
    static func transactionReferences(_ body: [String: Any]) -> Set<Int> {
        var result = Set<Int>()
        for (key, value) in body {
            if referenceTable(key) == "transactions", let id = value as? NSNumber { result.insert(id.intValue) }
            else if let nested = value as? [String: Any] { result.formUnion(transactionReferences(nested)) }
        }
        return result
    }

    /// 从旧协议快照恢复所需返现身份；参数：pending 为仍在队首的命令，data 为已验证当前会话的响应；返回值：无；仅原子保存身份，不安装远端业务数据或移除命令，缺失/歧义/落盘错误保留原状态。
    func recoverRebateReferences(_ pending: [String: Any], data: Data) throws {
        guard queue.first?["operationId"] as? String == pending["operationId"] as? String,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = envelope["data"] as? [String: Any], snapshot["schemaVersion"] as? Int == 1,
              let transactions = snapshot["transactions"] as? [[String: Any]],
              ["accounts", "categories", "presets"].allSatisfy({ snapshot[$0] is [[String: Any]] }) else {
            throw Self.failure("返现关联同步响应无效")
        }
        // 网络等待期间可能继续记账，因此基于最新空间重新验证关系，不能提交请求前的账本副本。
        let references = try unresolvedRebateReferences(pending)
        var next = space
        for (localID, parentID) in references {
            let candidates = transactions.filter { Self.id($0, "rebateParentId") == parentID }
            guard candidates.count == 1, let child = candidates.first else { throw Self.failure("云端返现关联缺失或不唯一") }
            let remoteID = Self.id(child)
            guard remoteID != parentID, transactions.filter({ Self.id($0) == remoteID }).count == 1 else { throw Self.failure("云端返现编号无效") }
            try Self.mapRebateIdentity(localID: localID, remoteID: remoteID, space: &next)
        }
        try saveSpace(next)
    }

    /// 更新单个返现子项身份；参数：localID 为本机临时编号，remoteID 为明确关联的云端编号，space 为待提交副本；返回值：无；拒绝编号冲突，只改 ID/外键/别名，不覆盖余额或用户输入。
    static func mapRebateIdentity(localID: Int, remoteID: Int, space: inout [String: Any]) throws {
        guard localID >= 1_000_000_000_000, remoteID > 0, remoteID < 1_000_000_000_000 else { throw failure("返现同步编号无效") }
        var aliases = space["aliases"] as? [String: Int] ?? [:]
        let key = "transactions:" + String(localID)
        guard aliases[key] == nil || aliases[key] == remoteID else { throw failure("返现同步编号冲突") }
        let transactions = space["transactions"] as? [[String: Any]] ?? []
        guard transactions.filter({ id($0) == localID }).count == 1,
              !transactions.contains(where: { id($0) == remoteID }) else { throw failure("返现同步记录冲突") }
        aliases[key] = remoteID; space["aliases"] = aliases
        for table in ["accounts", "categories", "transactions", "presets"] {
            var records = space[table] as? [[String: Any]] ?? []
            for index in records.indices {
                if table == "transactions", id(records[index]) == localID { records[index]["id"] = remoteID }
                records[index] = replaceReferences(records[index], table: "transactions", old: localID, new: remoteID)
            }
            space[table] = records
        }
    }

    /// 为失败命令补充定位信息；参数：error 为原错误，pending 为失败命令或 nil，phase 为当前同步阶段；返回值：保留 HTTP 状态的错误，不包含正文、凭证或卡号，无副作用。
    func syncFailure(_ error: Error, pending: [String: Any]?, phase: String) -> Error {
        guard let pending else { return error }
        let path = mappedPath(pending["path"] as? String ?? "")
        let command = try? Self.command(path, method: pending["method"] as? String ?? "")
        let operation = command?.0 ?? "未知操作"
        let target = command?.1 ?? 0
        let operationID = pending["operationId"] as? String ?? "未知"
        let parts = operation.split(separator: ".").map(String.init)
        let resources = ["transaction": "流水", "account": "账户", "category": "分类", "preset": "预设", "installment": "分期", "loan": "贷款"]
        let actions = ["create": "新增", "update": "修改", "confirm": "确认", "delete": "删除", "void": "冲销", "refund": "退款", "archive": "归档", "finish": "结清"]
        let label = parts.count == 3 ? (actions[parts[2]] ?? parts[2]) + (resources[parts[1]] ?? parts[1]) : operation
        let message = "\(phase)·\(label) #\(target)：\(error.localizedDescription)（操作 \(operationID.prefix(8))）"
        return APIError(status: (error as? APIError)?.status ?? 0, message: message)
    }

    /// 生成同步资料；参数：body 为已校验本机请求；返回值：卡片号码替换为尾号的上传副本，不改变本机号码或其他字段。
    static func cardSyncBody(_ body: [String: Any]) -> [String: Any] {
        var result = body
        if var cards = body["cards"] as? [[String: Any]] {
            for index in cards.indices {
                let digits = (cards[index]["maskedAccountNumber"] as? String ?? "").filter(\.isNumber)
                cards[index]["maskedAccountNumber"] = "**** " + digits.suffix(4)
            }
            result["cards"] = cards
        }
        return result
    }

    /// 合并云端卡片与本机完整号码；参数：remote/local 为同账户资料；返回值：保留匹配尾号的完整号码，云端顺序及其他字段不变；无副作用。
    static func preservingLocalCardNumbers(remote: [String: Any], local: [String: Any]) -> [String: Any] {
        var result = remote
        guard var cards = remote["cards"] as? [[String: Any]], let saved = local["cards"] as? [[String: Any]] else { return result }
        for index in cards.indices {
            guard let old = saved.first(where: { $0["id"] as? String == cards[index]["id"] as? String }),
                  let number = old["maskedAccountNumber"] as? String,
                  let tail = cards[index]["maskedAccountNumber"] as? String else { continue }
            let digits = number.filter(\.isNumber)
            if number.allSatisfy(\.isNumber), digits.count > 4, digits.suffix(4) == tail.filter(\.isNumber).suffix(4) {
                cards[index]["maskedAccountNumber"] = number
            }
        }
        result["cards"] = cards
        return result
    }

    /// 提交服务器回执和 ID 对应关系；参数：pending 为已发送命令，result 为已确认业务结果；返回值：无；单次落盘同时移除队列并修正关联，崩溃重试仍使用原操作标识。
    func acknowledge(_ pending: [String: Any], result: Any) throws {
        var next = space
        let path = pending["path"] as? String ?? "", parts = path.split(separator: "/").map(String.init)
        let table = parts.count > 1 ? parts[1] : ""
        let localID = Self.id(pending, "localID"), remoteID = (result as? [String: Any]).map { Self.id($0) } ?? 0
        // 只有新增记录需要重映射，PATCH/DELETE 回执不能把临时操作编号当作实体 ID。
        let created = pending["method"] as? String == "POST" && (parts.count == 2 || parts.last == "refund")
        if created && localID != 0 && remoteID != 0 && localID != remoteID {
            var aliases = next["aliases"] as? [String: Int] ?? [:]
            aliases[table + ":" + String(localID)] = remoteID; next["aliases"] = aliases
            for collection in ["accounts", "categories", "transactions", "presets"] {
                var records = next[collection] as? [[String: Any]] ?? []
                for index in records.indices {
                    if collection == table && Self.id(records[index]) == localID { records[index]["id"] = remoteID }
                    records[index] = Self.replaceReferences(records[index], table: table, old: localID, new: remoteID)
                }
                // 分类可能与服务器内置目录同名；合并的是服务器明确返回的同一 ID，不是账户名称猜测。
                var seen = Set<Int>()
                next[collection] = records.filter { seen.insert(Self.id($0)).inserted }
            }
        }
        if table == "transactions", let response = result as? [String: Any], response["syncRebateTransactionId"] != nil {
            let childID = Self.id(response, "syncRebateTransactionId")
            let children = (next["transactions"] as? [[String: Any]] ?? []).filter { Self.id($0, "rebateParentId") == remoteID }
            guard remoteID > 0, childID > 0, childID < 1_000_000_000_000, childID != remoteID, children.count <= 1 else {
                throw Self.failure("返现同步关联无效")
            }
            if let child = children.first {
                let oldID = Self.id(child)
                if oldID >= 1_000_000_000_000 { try Self.mapRebateIdentity(localID: oldID, remoteID: childID, space: &next) }
                else if oldID != childID { throw Self.failure("返现同步编号冲突") }
            }
        }
        var results = next["results"] as? [String: Any] ?? [:]
        if pending["remoteOnly"] as? Bool == true { results = [pending["operationId"] as? String ?? "": result] }
        next["results"] = results
        next["queue"] = queue.filter { $0["operationId"] as? String != pending["operationId"] as? String }
        try saveSpace(next)
    }
    /// 递归修正已确认记录的外键；参数：row 为字典，table 为实体类型，old/new 为对应 ID；返回值：修正副本，不匹配字段保持原值。
    static func replaceReferences(_ row: [String: Any], table: String, old: Int, new: Int) -> [String: Any] {
        var result = row
        for (key, value) in row {
            if referenceTable(key) == table, let number = value as? NSNumber, number.intValue == old { result[key] = new }
            else if let nested = value as? [String: Any] { result[key] = replaceReferences(nested, table: table, old: old, new: new) }
        }
        return result
    }
}
