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
#endif
