#if DEBUG
import Foundation

/// 仅 Debug 命令行 --preview 启用：固定示例响应，所有写入明确拒绝，不触达实际服务器。
nonisolated final class PreviewProtocol: URLProtocol, @unchecked Sendable {
    /// 接管预览请求；参数：request 为预览 URLSession 请求；返回值：true；无副作用。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保留请求；参数：request 为原请求；返回值：原请求；无副作用。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 返回静态预览数据；参数：无；返回值：无；所有变更返回 409，预览不发送网络请求。
    override func startLoading() {
        let path = request.url?.path ?? ""
        // 贷款试算是只读 POST；仅专用 Debug 预览使用固定计划，其他写入仍拒绝。
        let loanPreview = ProcessInfo.processInfo.arguments.contains("--loan-ui")
        let adjustmentPreview = loanPreview && path == "/api/finance/accounts/3/loan-adjustment-preview"
        let writable = request.httpMethod != "GET" && !(loanPreview && path == "/api/finance/loan-preview") && !adjustmentPreview
        var status = writable ? 409 : 200
        var content: [String: Any] = writable ? ["error": "这是界面预览，不能保存数据。请正常启动后连接自己的服务器。"] : ["data": loanPreview ? Self.loanPayload(request) : Self.payload(path)]
        if adjustmentPreview {
            if let result = Self.adjustmentSample(request) { content = ["data": result] }
            else { status = 422; content = ["error": "此输入没有对应的界面预览样本。"] }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: content)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    /// 结束同步预览响应；参数：无；返回值：无；无资源需释放。
    override func stopLoading() {}
    /// 匹配后端计算器导出的试算样本；参数：request 为只读调整请求；返回值：输入完全匹配的计划，否则 nil，不在客户端伪造计算。
    private static func adjustmentSample(_ request: URLRequest) -> Any? {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let input = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let url = Bundle.main.url(forResource: "LoanAdjustmentUIPreview", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let samples = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        // 样本匹配回调输入一份固定请求和计划，输出是否与本次提交完全相同；拒绝把无关结果当作预览。
        return samples.first { sample in
            guard let fields = sample["request"] as? [String: Any] else { return false }
            return NSDictionary(dictionary: input).isEqual(to: fields)
        }?["plan"]
    }
    /// 加载贷款视觉验收的固定样本；参数：无；返回值：JSON 字典，失败返回空对象；仅 Debug 访问，不含真实用户数据。
    private static let loanSample: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "LoanUIPreview", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }()
    /// 响应贷款视觉预览；参数：request 为模拟请求；返回值：固定样本或原预览响应，按请求月份过滤记录，不联网。
    private static func loanPayload(_ request: URLRequest) -> Any {
        let path = request.url?.path ?? ""
        if path == "/api/finance/accounts", let account = loanSample["account"] {
            return (payload(path) as? [Any] ?? []) + [account]
        }
        if path == "/api/finance/loan-preview" || path == "/api/finance/accounts/3/loan-plan" { return loanSample["plan"] ?? [:] }
        if path == "/api/finance/transactions" {
            if ProcessInfo.processInfo.arguments.contains("--loan-empty") { return [] }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = query.first { $0.name == "startDate" }?.value ?? ""
            let end = query.first { $0.name == "endDate" }?.value ?? "9999-12-31"
            // 筛选回调输入样本流水，返回是否落在请求自然月内；无副作用。
            let rows = (loanSample["transactions"] as? [[String: Any]] ?? []).filter {
                let date = $0["transactionDate"] as? String ?? ""
                return date >= start && date <= end
            }
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "500") ?? 500
            return Array(rows.dropFirst(max(0, offset)).prefix(max(0, limit)))
        }
        return payload(path)
    }
    /// 创建单个任务；参数：id/title 为标识，parent 为可选父任务，completed 为进度；返回值：与后端一致的 JSON 对象；无副作用。
    static func task(_ id: Int, _ title: String, parent: Int? = nil, completed: Int = 0) -> [String: Any] {
        ["id": id, "title": title, "remark": "给重要的事情，留出专注的时间。", "listId": 1, "parentId": parent as Any? ?? NSNull(), "taskType": parent == nil && id == 1 ? "main" : "subtask", "priority": id == 1 ? "high" : "medium", "startDate": Values.day(), "startTime": "", "endDate": Values.day(), "endTime": "", "archived": false, "sortOrder": id, "progressTotal": 10, "progressCompleted": completed, "progressStep": 1, "progressUnit": "页"]
    }
    /// 返回端点示例；参数：path 为 API 路径；返回值：可编码 JSON；未定义端点返回空数组。
    static func payload(_ path: String) -> Any {
        switch path {
        case "/api/users/me": return ["id": 1, "account": "preview", "nickname": "林予", "role": "admin"]
        case "/api/tasks": return [task(1, "为新的一周留点空间", completed: 3), task(2, "读完《设计心理学》第三章", parent: 1, completed: 4), task(3, "整理本月订阅与开销", completed: 2), task(4, "写下三个值得记住的瞬间", completed: 0)]
        case "/api/task-lists": return [["id": 1, "name": "日常与成长", "remark": "让每一天，更有条理", "color": "#14B8A6", "icon": "folder"], ["id": 2, "name": "工作计划", "remark": "专注重要的事", "color": "#3B82F6", "icon": "folder"]]
        case "/api/finance/overview": return ["totalAssets": "86520.50", "totalLiabilities": "0.00", "netWorth": "86520.50", "monthIncome": "18500.00", "monthExpense": "4268.80", "monthBalance": "14231.20", "savingsRate": "76.93", "debtRatio": "0.00", "accountCount": 2, "assetStructure": [["name": "日常储蓄", "amount": "86000.00"], ["name": "现金钱包", "amount": "520.50"]], "cashFlow": [["month": "2026-07", "income": "18500.00", "expense": "6820.00", "net": "11680.00"], ["month": "2026-08", "income": "18500.00", "expense": "5360.00", "net": "13140.00"], ["month": "2026-09", "income": "18500.00", "expense": "4268.80", "net": "14231.20"]], "expenseCategories": [["name": "餐饮", "amount": "1820.00"], ["name": "生活", "amount": "1600.00"], ["name": "出行", "amount": "848.80"]]]
        case "/api/finance/transactions-summary": return ["income": "0.00", "expense": "0.00", "balance": "0.00"]
        case "/api/finance/accounts": return [["id": 1, "name": "日常储蓄", "accountType": "bank", "institution": "招商银行", "maskedAccountNumber": "**** 8260", "balance": "86000.00", "availableBalance": "86000.00", "currency": "CNY", "includeInNetWorth": true, "notes": ""], ["id": 2, "name": "现金钱包", "accountType": "cash", "institution": "", "maskedAccountNumber": "", "balance": "520.50", "availableBalance": "520.50", "currency": "CNY", "includeInNetWorth": true, "notes": ""]]
        case "/api/finance/categories": return [["id": 1, "name": "餐饮", "type": "expense", "color": "#14B8A6"]]
        case "/api/setting/ai/provider_config": return [["id": 1, "name": "日常助手", "model_name": "个人模型", "provider_name": "自定义", "is_selected": true]]
        default: return []
        }
    }
}
/// Debug 专用可写内存任务服务；所有请求均被接管，永不访问真实服务器。
nonisolated final class TaskScenarioProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rows = PreviewProtocol.payload("/api/tasks") as! [[String: Any]]
    nonisolated(unsafe) private static var lists = PreviewProtocol.payload("/api/task-lists") as! [[String: Any]]
    nonisolated(unsafe) private static var wrote = false
    nonisolated(unsafe) private static var initialized = false
    nonisolated(unsafe) private static var refreshFailuresRemaining = 0
    nonisolated(unsafe) private static var responseLost = false
    /// 接管隔离服务请求；参数：request 为请求；返回值：true；无副作用。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保留隔离请求；参数：request 为请求；返回值：原请求；无副作用。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 结束内存响应；参数：无；返回值：无；没有后台资源。
    override func stopLoading() {}
    /// 响应内存任务场景；参数：无；返回值：无；串行锁保护样本，写入失败和响应丢失均不自动重试。
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--task-ui-scenario")
        // 参数转换回调输入参数索引、输出场景名称；边界检查避免缺少参数时越界，不产生网络副作用。
        let scenario = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "normal"
        if !Self.initialized {
            Self.initialized = true
            if scenario == "empty" { Self.rows = []; Self.lists = [] }
        }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let isModule = path.hasPrefix("/api/tasks") || path.hasPrefix("/api/task-lists")
        var status = 200
        var result: Any = PreviewProtocol.payload(path)
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; bodyData.append(contentsOf: bytes.prefix(count)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        if isModule && method == "GET" {
            if scenario == "load-error" { status = 503 }
            else if ["refresh-error", "lost-response-read-error"].contains(scenario) && path == "/api/tasks" && Self.refreshFailuresRemaining > 0 { status = 503; Self.refreshFailuresRemaining -= 1 }
            result = path == "/api/tasks" ? Self.rows : Self.lists
        } else if isModule {
            if scenario == "write-error" { status = 400 }
            else {
                Self.wrote = true
                if scenario == "refresh-error" || (scenario == "lost-response-read-error" && !Self.responseLost) { Self.refreshFailuresRemaining = 2 }
                // 清单写入保持任务级联删除和服务端实体响应的最小契约。
                if path.hasPrefix("/api/task-lists") {
                    let id = Int(path.split(separator: "/").last ?? "")
                    if method == "DELETE", let id { Self.lists.removeAll { $0["id"] as? Int == id }; Self.rows.removeAll { $0["listId"] as? Int == id }; result = NSNull() }
                    // 合并回调输入旧值与新值、输出新值；仅更新模拟清单草稿请求提交字段。
                    else if let id, let offset = Self.lists.firstIndex(where: { $0["id"] as? Int == id }) { Self.lists[offset].merge(body) { _, new in new }; result = Self.lists[offset] }
                    else { var list = body; list["id"] = (Self.lists.compactMap { $0["id"] as? Int }.max() ?? 0) + 1; Self.lists.append(list); result = list }
                } else if path == "/api/tasks/reorder" {
                    for (order, id) in (body["taskIds"] as? [Int] ?? []).enumerated() { if let offset = Self.rows.firstIndex(where: { $0["id"] as? Int == id }) { Self.rows[offset]["sortOrder"] = order } }; result = NSNull()
                } else {
                    let components = path.split(separator: "/")
                    let id = components.count > 2 ? Int(components[2]) : nil
                    // 样本删除按父级闭包递归清理，便于验收真实页面的级联行为。
                    if method == "DELETE", let id {
                        var removed: Set<Int> = [id]
                        var count = 0
                        repeat { count = removed.count; for row in Self.rows { if removed.contains(row["parentId"] as? Int ?? 0), let child = row["id"] as? Int { removed.insert(child) } } } while count != removed.count
                        Self.rows.removeAll { removed.contains($0["id"] as? Int ?? 0) }; result = NSNull()
                    } else if let id, let offset = Self.rows.firstIndex(where: { $0["id"] as? Int == id }) {
                        if path.hasSuffix("/progress") {
                            let value = (Self.rows[offset]["progressCompleted"] as? NSNumber)?.doubleValue ?? 0
                            let step = (Self.rows[offset]["progressStep"] as? NSNumber)?.doubleValue ?? 1
                            let target = (Self.rows[offset]["progressTotal"] as? NSNumber)?.doubleValue ?? 1
                            let requested = value + (body["operation"] as? String == "decrement" ? -step : step)
                            Self.rows[offset]["progressCompleted"] = max(0, min(target, requested))
                        // 合并回调输入旧值和请求新值、输出新值；不变字段保留，仅用于隔离样本。
                        } else { Self.rows[offset].merge(body) { _, new in new } }
                        result = Self.rows[offset]
                    } else {
                        let next = (Self.rows.compactMap { $0["id"] as? Int }.max() ?? 0) + 1
                        var row = PreviewProtocol.task(next, body["title"] as? String ?? "任务")
                        // 新建合并回调输入样本默认值和草稿值、输出草稿值；随后把进度字符串转换为响应数值。
                        row.merge(body) { _, new in new }; Self.rows.append(row); result = row
                    }
                    // 请求草稿的进度字符串转换成响应数值，保持模型解码契约。
                    for offset in Self.rows.indices { for key in ["progressTotal", "progressCompleted", "progressStep"] { if let raw = Self.rows[offset][key] as? String { Self.rows[offset][key] = Double(raw) ?? 0 } } }
                    if let dictionary = result as? [String: Any], let id = dictionary["id"] as? Int { result = Self.rows.first { $0["id"] as? Int == id } ?? dictionary }
                }
                if ["lost-response", "lost-response-read-error"].contains(scenario) && !Self.responseLost { Self.responseLost = true; client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            }
        }
        let envelope: [String: Any] = status == 200 ? ["data": result] : ["message": status == 400 ? "示例业务拒绝，请调整后重试。" : "示例加载失败。"]
        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
#endif
