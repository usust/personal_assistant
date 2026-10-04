import Foundation
import CryptoKit

/// 视觉识别资料只包含候选字段，不包含可执行操作或服务端账户 ID。
nonisolated struct ScreenshotExtraction: Codable, Equatable {
    var channel: String
    var status: String
    var kind: String
    var currency: String
    var amount: String
    var merchant: String
    var date: String
    var time: String
    var paymentMethod: String
    var orderId: String
    var category: String
    var amountEvidence: String
    var paymentEvidence: String
    var needsReview: Bool
    var reason: String
    var paymentCardLast4: String? = nil
    var note: String? = nil

    /// 判断交易能否按支出入账；参数：无；返回值：已支付人民币支出为 true，旧结果空币种按默认人民币处理，明确外币拒绝，支付渠道不参与校验，无副作用。
    var supported: Bool { status == "paid" && kind == "expense" && (currency.isEmpty || currency == "CNY") }

    /// 验证实际入账必要资料；参数：无；返回值：无；金额、交易日期或已有时间非法抛错；商户、时分及订单号可缺省，不依赖模型自报需确认标记。
    func validate() throws {
        guard (note ?? "").utf8.count <= 1500 else { throw APIError(status: 0, message: "备注过长") }
        guard supported, amount.range(of: #"^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: amount), value > 0, Values.validMoney(amount), merchant.utf8.count <= 128,
              paymentMethod.utf8.count <= 128,
              Self.parsedDate(date, time.isEmpty ? "00:00" : time) != nil else { throw APIError(status: 0, message: "请补全有效金额或交易日期") }
    }
    /// 严格解析交易本地时间；参数：day 为 yyyy-MM-dd，time 为 HH:mm；返回值：有效日期或 nil，不推断缺失时间。
    static func parsedDate(_ day: String, _ time: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let text = day + " " + time
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

nonisolated struct ScreenshotSettings: Codable, Equatable {
    var enabled = false
    var configID = 0
    var configVersion = ""
    var destination = ""
    var consentID = ""
}
nonisolated struct ScreenshotJob: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt = Date()
    var hash: String
    var image: String?
    var state = "queued"
    var message = "等待识别"
    var extraction: ScreenshotExtraction?
    var accountID = 0
    var categoryID = 0
    var transactionID: Int?

    /// 展示稳定状态文字；参数：无；返回值：中文标签，无副作用。
    var stateTitle: String {
        switch state {
        case "processing": return "识别中"
        case "failed": return "识别失败"
        case "review": return "已添加流水"
        case "posted": return "已入账"
        case "ignored": return "已忽略"
        default: return "待处理"
        }
    }
}
nonisolated struct ScreenshotBook: Codable {
    var settings = ScreenshotSettings()
    var jobs: [ScreenshotJob] = []
}

extension FinanceLocalStore {
    /// 读取当前空间的截图状态；参数：无；返回值：已保存状态，损坏时抛错而不覆盖原资料。
    func screenshotBook() throws -> ScreenshotBook {
        guard let raw = space["screenshotBookkeeping"] else { return ScreenshotBook() }
        return try JSONDecoder().decode(ScreenshotBook.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    /// 编码任务元数据并剔除图片；参数：book 为已校验截图状态；返回值：不含图片的 JSON 字典；编码失败抛错。
    static func screenshotObject(_ book: ScreenshotBook) throws -> Any {
        // 图片只供内存识别使用，持久化仅保留任务与识别字段，并清理旧版本图片。
        var metadata = book
        for index in metadata.jobs.indices { metadata.jobs[index].image = nil }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
    }
    /// 保存当前空间截图配置与任务；参数：book 为新状态；返回值：无；磁盘成功后才更新观察状态。
    func saveScreenshotBook(_ book: ScreenshotBook) throws {
        var next = space; next["screenshotBookkeeping"] = try Self.screenshotObject(book); try saveSpace(next)
    }
    /// 每次选图保存任务元数据，图片仅留在内存；参数：data 为已规范化且不超过 3 MB 的 JPEG；返回值：新任务，即使同图也重新识别；待处理总量超过 10 张时拒绝，避免无界存图。
    func enqueueScreenshot(_ data: Data) throws -> ScreenshotJob {
        var book = try screenshotBook()
        guard book.settings.enabled, !book.settings.consentID.isEmpty else { throw Self.failure("请先在财务→右上角菜单→图片记账中启用并同意图片外发") }
        guard !data.isEmpty, data.count <= 3 * 1024 * 1024 else { throw Self.failure("截图大小无效") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard book.jobs.filter({ ["queued", "processing"].contains($0.state) }).count < 10 else { throw Self.failure("请先处理待确认或失败的截图") }
        let job = ScreenshotJob(hash: hash, image: data.base64EncodedString())
        book.jobs.insert(job, at: 0); try saveScreenshotBook(book); screenshotImages[job.id] = job.image; return job
    }
    /// 更新单个任务；参数：job 为当前空间已有任务；返回值：无；不存在时拒绝，不跨空间新增任务。
    func updateScreenshot(_ job: ScreenshotJob) throws {
        var book = try screenshotBook()
        guard let index = book.jobs.firstIndex(where: { $0.id == job.id }) else { throw Self.failure("截图任务不存在") }
        book.jobs[index] = job; try saveScreenshotBook(book)
        if ["posted", "review", "failed", "ignored"].contains(job.state) { screenshotImages.removeValue(forKey: job.id) }
    }
    /// 删除分析记录及图片；参数：id 为当前空间的任务 ID；返回值：无，不存在时不操作；处理中拒绝删除，不修改交易、余额或同步队列，磁盘失败抛错。
    func deleteScreenshot(_ id: String) throws {
        var book = try screenshotBook()
        guard let job = book.jobs.first(where: { $0.id == id }) else { return }
        guard job.state != "processing" else { throw Self.failure("请等待分析完成后删除") }
        book.jobs.removeAll { $0.id == id }
        try saveScreenshotBook(book); screenshotImages.removeValue(forKey: id)
    }
    /// 恢复中断任务；参数：pendingIDs 为系统后台仍负责的任务 ID，默认无；返回值：无；仅将无后台接管的未完成识别改为失败，保留图片和任务 ID。
    func recoverScreenshots(excluding pendingIDs: Set<String> = []) throws {
        var book = try screenshotBook(); var changed = false
        // 清除旧版本保存在账本中的图片，保留任务与识别字段。
        for index in book.jobs.indices where book.jobs[index].image != nil {
            book.jobs[index].image = nil; changed = true
        }
        for index in book.jobs.indices where book.jobs[index].state == "processing" && !pendingIDs.contains(book.jobs[index].id) {
            book.jobs[index].state = "failed"; book.jobs[index].message = "上次识别已中断，请重新选图"; changed = true
        }
        if changed { try saveScreenshotBook(book) }
    }
    /// 标记所属空间失败；参数：id 为截图任务，spaceKey 为创建时空间，message 为错误原因；返回值：无；不切换当前空间或覆盖终态，磁盘失败抛错。
    func failScreenshot(_ id: String, spaceKey: String, message: String) throws {
        guard var original = spaces[spaceKey], let raw = original["screenshotBookkeeping"] else { return }
        var book = try JSONDecoder().decode(ScreenshotBook.self, from: JSONSerialization.data(withJSONObject: raw))
        guard let index = book.jobs.firstIndex(where: { $0.id == id }), ["queued", "processing", "failed"].contains(book.jobs[index].state) else { return }
        book.jobs[index].state = "failed"; book.jobs[index].message = message; book.jobs[index].image = nil
        screenshotImages.removeValue(forKey: id)
        original["screenshotBookkeeping"] = try Self.screenshotObject(book)
        var next = document, all = spaces; all[spaceKey] = original; next["spaces"] = all
        try commit(next)
    }
    /// 按明确尾号匹配本机账户；参数：extraction 为识别资料；返回值：唯一可用 ID，缺少尾号或存在歧义时为 0；不依赖支付渠道，不外发账户资料。
    func screenshotAccount(_ extraction: ScreenshotExtraction) -> Int {
        guard let last4 = extraction.paymentCardLast4, !last4.isEmpty else { return 0 }
        guard last4.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else { return 0 }
        // 筛选回调输入账户行、返回是否可用且尾号相同；不从任意文本抓数字或按银行译名猜选。
        let candidates = rows("accounts").filter { row in
            let numbers: [String]
            if let cards = row["cards"] as? [[String: Any]] { numbers = cards.compactMap { $0["maskedAccountNumber"] as? String } }
            else { numbers = [row["maskedAccountNumber"] as? String ?? ""] }
            return numbers.contains(where: { $0.replacingOccurrences(of: " ", with: "").hasSuffix(last4) }) && row["archived"] as? Bool != true &&
                row["selectable"] as? Bool != false && row["currency"] as? String == "CNY"
        }
        guard candidates.count == 1, let account = candidates.first else { return 0 }
        return Self.id(account)
    }
    /// 匹配 AI 分类建议；参数：suggestion 为分类名称或父子路径；返回值：已有支出分类 ID，无合适或存在歧义时为 0；不创建分类。
    func screenshotSuggestedCategory(_ suggestion: String) -> Int {
        let text = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let categories = rows("categories").filter { $0["type"] as? String == "expense" }
        // 优先精确名称；旧识别结果可能组合了父子名称，仅在唯一命中时兼容包含关系。
        let exact = categories.filter { ($0["name"] as? String ?? "").caseInsensitiveCompare(text) == .orderedSame }
        if exact.count == 1 { return Self.id(exact[0]) }
        if !exact.isEmpty { return 0 }
        let contained = categories.filter {
            guard let name = $0["name"] as? String, !name.isEmpty else { return false }
            return text.localizedCaseInsensitiveContains(name)
        }
        guard let longest = contained.map({ ($0["name"] as? String ?? "").count }).max() else { return 0 }
        let matches = contained.filter { ($0["name"] as? String ?? "").count == longest }
        return matches.count == 1 ? Self.id(matches[0]) : 0
    }
    /// 自动匹配并准备结果；参数：job 为已有任务；返回值：匹配后的任务，必要时设为待确认；不改变余额。
    func prepareScreenshot(_ job: ScreenshotJob) throws -> ScreenshotJob {
        var value = job
        guard let extraction = value.extraction else { throw Self.failure("尚未识别截图") }
        value.accountID = screenshotAccount(extraction)
        value.categoryID = screenshotSuggestedCategory(extraction.category)
        value.state = "review"
        // 用户允许重复添加；只校验本次截图资料与映射，不以历史订单或相同商户金额阻止入账。
        if !extraction.supported { value.message = "请确认交易已支付且为人民币支出" }
        else if (try? extraction.validate()) == nil { value.message = "请补全有效金额或交易日期" }
        else if value.accountID == 0 { value.message = "请选择扣款账户" }
        else { value.message = "" }
        return value
    }
    /// 将识别结果直接纳入本机流水并清除图片；参数：job 为已识别的任务；返回值：带稳定流水编号的任务；缺失字段留空，未满足入账条件前不扣余额、不上传。
    func includeIncompleteScreenshot(_ job: ScreenshotJob) throws -> ScreenshotJob {
        var value = job
        value.image = nil; value.message = ""
        screenshotImages.removeValue(forKey: job.id)
        if value.transactionID == nil {
            let id = document["nextLocalID"] as? Int ?? 1_000_000_000_000
            guard id < 4_000_000_000_000 else { throw Self.failure("本机编号已用尽") }
            value.transactionID = id
            var book = try screenshotBook()
            guard let index = book.jobs.firstIndex(where: { $0.id == value.id }) else { throw Self.failure("截图任务不存在") }
            value.state = "review"; book.jobs[index] = value
            var next = space; next["screenshotBookkeeping"] = try Self.screenshotObject(book)
            var updated = document, all = spaces; all[activeKey] = next; updated["spaces"] = all; updated["nextLocalID"] = id + 2
            try commit(updated)
        } else { try updateScreenshot(value) }
        return value
    }

    /// 生成缺失资料流水的只读投影；参数：无；返回值：已有稳定编号的截图流水；未知金额保持空，不参与余额和统计，缺日期按截图日期排列。
    func incompleteScreenshotTransactions() throws -> [[String: Any]] {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        // 投影回调输入任务、返回截图流水或 nil；完成任务自动从投影消失，由真正入账流水替代。
        return try screenshotBook().jobs.compactMap { job in
            guard job.state == "review", let id = job.transactionID, let value = job.extraction else { return nil }
            return ["id": id, "accountId": job.accountID, "type": value.kind == "income" ? "income" : "expense", "amount": Values.validMoney(value.amount, positive: true) ? value.amount : "",
                    "categoryId": job.categoryID, "counterparty": value.merchant, "description": value.note ?? "", "status": "incomplete", "source": "screenshot",
                    "transactionDate": value.date.isEmpty ? formatter.string(from: job.createdAt) : value.date, "transactionTime": value.time,
                    "screenshotJobID": job.id, "screenshotIssue": job.message, "fee": "0.00"]
        }
    }
    /// 恢复旧版未自动入账的识别任务；参数：无；返回值：本次自动创建的流水数量；启用且已同意时重新校验资料和映射，符合条件直接入账，其他记录更新真实阻塞原因。
    func resumeRecognizedScreenshots() throws -> Int {
        let book = try screenshotBook()
        guard book.settings.enabled, !book.settings.consentID.isEmpty else { return 0 }
        var posted = 0
        // 重新校验旧版待确认任务，不重新提交已有“已入账”任务或擅自填写缺失资料。
        for job in book.jobs where job.state == "review" {
            let prepared = try prepareScreenshot(job)
            if prepared.message.isEmpty {
                _ = try postScreenshot(prepared, manual: false)
                posted += 1
            } else { _ = try includeIncompleteScreenshot(prepared) }
        }
        return posted
    }
    /// 从通用流水编辑器保存截图交易；参数：id 为当前空间已有截图任务，body 为编辑器校验后的白名单交易字段；返回值：无；交易、余额、队列与截图终态原子提交，失败不修改原资料。
    func saveScreenshotTransaction(_ id: String, body: [String: Any]) throws {
        var book = try screenshotBook()
        guard let index = book.jobs.firstIndex(where: { $0.id == id }), book.jobs[index].state == "review" else { throw Self.failure("截图流水不存在") }
        let allowed = Set(["type", "accountId", "targetAccountId", "amount", "discount", "fee", "rebate", "rebateAccountId", "rebatePending", "categoryId", "counterparty", "description", "transactionDate", "transactionTime"])
        // 只复制编辑器允许的交易字段，账本 apply 继续校验金额、账户、类型及关联约束。
        var fields = body.filter { allowed.contains($0.key) }
        let operationID = "screenshot-" + id
        fields["requestId"] = operationID
        var next = space
        let newID = document["nextLocalID"] as? Int ?? 1_000_000_000_000
        guard newID < 4_000_000_000_000 else { throw Self.failure("本机编号已用尽") }
        let result = try Self.apply("/finance/transactions", method: "POST", body: fields, newID: newID, space: &next)
        var commands = next["queue"] as? [[String: Any]] ?? []
        commands.append(["operationId": operationID, "path": "/finance/transactions", "method": "POST", "body": fields, "localID": newID])
        book.jobs[index].state = "posted"; book.jobs[index].image = nil; book.jobs[index].message = "已入账"
        book.jobs[index].transactionID = (result as? [String: Any]).map { Self.id($0) }
        next["screenshotBookkeeping"] = try Self.screenshotObject(book); next["queue"] = commands
        var updated = document, all = spaces; all[activeKey] = next; updated["spaces"] = all; updated["nextLocalID"] = newID + 2
        try commit(updated); onMutation?()
    }

    /// 原子完成截图入账；参数：job 为待确认资料，manual 表示已由用户核对；不同任务允许同图同订单重复入账；返回值：完成任务；交易、余额、队列和回执同事务提交，失败保留原状态。
    func postScreenshot(_ job: ScreenshotJob, manual: Bool) throws -> ScreenshotJob {
        var book = try screenshotBook()
        guard let index = book.jobs.firstIndex(where: { $0.id == job.id }) else { throw Self.failure("截图任务不存在") }
        if book.jobs[index].state == "posted" { return book.jobs[index] }
        guard ["processing", "review"].contains(book.jobs[index].state), let extraction = job.extraction else { throw Self.failure("任务不可入账") }
        try extraction.validate()
        if !manual {
            let prepared = try prepareScreenshot(job)
            guard book.settings.enabled, prepared.message.isEmpty, prepared.accountID == job.accountID, prepared.categoryID == job.categoryID else { throw Self.failure("资料需要确认") }
        }
        let accountID = mappedID(job.accountID, table: "accounts"), categoryID = mappedID(job.categoryID, table: "categories")
        guard accountID != 0, rows("accounts").contains(where: { Self.id($0) == accountID && $0["currency"] as? String == "CNY" }) else { throw Self.failure("请选择人民币账户") }
        let operationID = "screenshot-" + job.id
        let note = (extraction.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 备注保存原商品或订单描述及其中的平台来源；付款方式和卡尾号用于账户匹配，不拼入消费备注。
        let body: [String: Any] = ["requestId": operationID, "type": "expense", "amount": extraction.amount, "accountId": accountID, "categoryId": categoryID,
                                   "counterparty": extraction.merchant, "transactionDate": extraction.date, "transactionTime": extraction.time, "description": note, "fee": "0.00"]
        var next = space
        let newID = document["nextLocalID"] as? Int ?? 1_000_000_000_000
        guard newID < 4_000_000_000_000 else { throw Self.failure("本机编号已用尽") }
        let result = try Self.apply("/finance/transactions", method: "POST", body: body, newID: newID, space: &next)
        var commands = next["queue"] as? [[String: Any]] ?? []
        commands.append(["operationId": operationID, "path": "/finance/transactions", "method": "POST", "body": body, "localID": newID])
        var completed = job; completed.state = "posted"; completed.message = "已记账 ¥" + extraction.amount; completed.image = nil
        completed.accountID = accountID; completed.categoryID = categoryID; completed.transactionID = (result as? [String: Any]).map { Self.id($0) }
        book.jobs[index] = completed; next["screenshotBookkeeping"] = try Self.screenshotObject(book); next["queue"] = commands
        var updated = document, all = spaces; all[activeKey] = next; updated["spaces"] = all; updated["nextLocalID"] = newID + 2
        try commit(updated); screenshotImages.removeValue(forKey: job.id); onMutation?(); return completed
    }
}

extension FinanceLocalStore {
    /// 执行可恢复的图片识别；参数：id 为本空间任务，api 为认证客户端，isCurrent 为会话仍有效的无参布尔回调；返回值：处理状态；成功或失败均清理内存图片，仅保留错误元数据，在途设置变化拒绝入账。
    func recognizeScreenshot(_ id: String, api: APIClient, isCurrent: () -> Bool) async throws -> String {
        let book = try self.screenshotBook(), settings = book.settings
        guard var job = book.jobs.first(where: { $0.id == id }) else { throw APIError(status: 0, message: "截图任务不存在") }
        guard !["posted", "ignored", "review"].contains(job.state) else { return job.message }
        guard settings.enabled, settings.configID > 0, !settings.consentID.isEmpty else { throw APIError(status: 0, message: "请启用图片记账并同意图片外发") }
        guard api.token != nil, self.space["server"] as? String == api.baseURL, self.cachedProfile != nil else { throw APIError(status: 0, message: "请先登录并开启同步，以使用 AI 配置") }
        guard let image = screenshotImages[id] ?? job.image else { throw APIError(status: 0, message: "截图已清理") }
        defer { screenshotImages.removeValue(forKey: id) }
        let spaceKey = activeKey, token = api.token, server = api.baseURL
        job.state = "processing"; job.message = "正在识别"; try self.updateScreenshot(job)
        do {
            let result: ScreenshotExtraction = try await api.request("/ai/screenshot", method: "POST", body: ["configId": settings.configID, "configVersion": settings.configVersion, "image": "data:image/jpeg;base64," + image, "categories": rows("categories").filter { $0["type"] as? String == "expense" }.compactMap { $0["name"] as? String }])
            guard isCurrent(), self.activeKey == spaceKey, api.baseURL == server, api.token == token,
                  try self.screenshotBook().settings == settings else { throw APIError(status: 0, message: "账号或截图设置已变化，请重新处理") }
            job.extraction = result
            job = try self.prepareScreenshot(job)
            if job.state == "review", job.message.isEmpty { job = try self.postScreenshot(job, manual: false) }
            else { job = try self.includeIncompleteScreenshot(job) }
            return job.state == "review" ? "已添加流水" : (job.message.isEmpty ? job.stateTitle : job.message)
        } catch {
            // 原空间任务单独标记失败，不能把旧账号图片写入新账号；不覆盖已原子完成的交易回执。
            if var original = self.spaces[spaceKey], let raw = original["screenshotBookkeeping"],
               var saved = try? JSONDecoder().decode(ScreenshotBook.self, from: JSONSerialization.data(withJSONObject: raw)),
               let index = saved.jobs.firstIndex(where: { $0.id == id }), saved.jobs[index].state == "processing" {
                saved.jobs[index].state = "failed"; saved.jobs[index].message = error.localizedDescription
                original["screenshotBookkeeping"] = try FinanceLocalStore.screenshotObject(saved)
                var next = self.document, all = self.spaces; all[spaceKey] = original; next["spaces"] = all; try self.commit(next)
            }
            throw error
        }
    }
}
