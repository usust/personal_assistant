import Foundation

@MainActor enum ScreenshotBookkeepingTests {
    /// 创建确定的单笔识别资料；参数：order 为订单号；返回值：人民币支出候选，无外部请求。
    static func extraction(_ order: String = "ORDER-001") -> ScreenshotExtraction {
        ScreenshotExtraction(channel: "wechat", status: "paid", kind: "expense", currency: "CNY", amount: "20.50", merchant: "午餐店", date: "2026-09-29", time: "12:30", paymentMethod: "招商银行1234", orderId: order, category: "餐饮", amountEvidence: "实付20.50", paymentEvidence: "支付成功", needsReview: false, reason: "", paymentCardLast4: "1234", note: "面筋年糕各两串等3件商品")
    }
    /// 验证渠道不限制入账及旧任务恢复；参数：无；返回值：无，失败抛错或断言；只写临时账本，账户尾号匹配跨渠道复用。
    static func channelsDoNotBlock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinanceLocalStore(url: directory.appendingPathComponent("channels.sqlite"))
        let account = try FinanceOfflineTests.account(store, name: "招商银行", balance: "100.00")
        _ = try store.writeLocal("/finance/accounts/\(account)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        var book = try store.screenshotBook()
        book.settings = ScreenshotSettings(enabled: true, configID: 1, consentID: "test")
        try store.saveScreenshotBook(book)
        for channel in ["unknown", "other", "bank", "", "alipay"] {
            var job = try store.enqueueScreenshot(Data(("image-" + channel).utf8))
            var result = extraction(); result.channel = channel
            result.needsReview = true; result.reason = "支付渠道未知"
            job.extraction = result
            job = try store.prepareScreenshot(job)
            precondition(job.message.isEmpty && job.accountID == account)
            try store.updateScreenshot(job)
            _ = try store.postScreenshot(job, manual: false)
        }
        precondition(store.rows("transactions").count == 5)
        // 旧版仅因渠道未知卡住的任务无需再次外发图片；重新校验后入账，重复恢复保持幂等。
        var old = try store.enqueueScreenshot(Data("legacy-channel".utf8))
        var result = extraction(); result.channel = "unknown"
        old.extraction = result; old.state = "review"; old.message = "仅支持微信、支付宝已支付的人民币支出"
        try store.updateScreenshot(old)
        try check(try store.resumeRecognizedScreenshots() == 1)
        try check(try store.resumeRecognizedScreenshots() == 0)
        precondition(store.rows("transactions").count == 6)
    }

    /// 断言业务拒绝非法操作；参数：action 为应抛错的同步闭包，返回无；返回值：无，操作成功则测试失败。
    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("应拒绝该截图操作") } catch { }
    }
    /// 检查可能抛错的断言；参数：condition 为惰性布尔表达式；返回值：无，错误向上传递，false 中止测试。
    static func check(_ condition: @autoclosure () throws -> Bool) throws { let result = try condition(); precondition(result) }
    /// 执行截图持久化、去重、校验及原子性测试；参数：无；返回值：无；只使用临时 SQLite，不读取真实图片或账本。
    static func run() throws {
        try channelsDoNotBlock()
        try requiredFieldsOnly()
        try sharedCards()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        let account = try FinanceOfflineTests.account(store, name: "招商银行", balance: "100.00")
        _ = try store.writeLocal("/finance/accounts/\(account)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        let categoryRow = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "餐饮", "type": "expense"]) as! [String: Any]
        let category = FinanceLocalStore.id(categoryRow)
        // AI 建议选中已有分类；旧组合名称兼容，未知类型保持空。
        precondition(store.screenshotSuggestedCategory("餐饮") == category)
        precondition(store.screenshotSuggestedCategory("餐饮外卖") == category)
        precondition(store.screenshotSuggestedCategory("完全未知类型") == 0)
        precondition(store.screenshotSuggestedCategory("") == 0)
        rejects { _ = try store.enqueueScreenshot(Data("image1".utf8)) }
        var book = try store.screenshotBook()
        book.settings = ScreenshotSettings(enabled: true, configID: 1, configVersion: "v1", destination: "test", consentID: "consent")
        try store.saveScreenshotBook(book)
        var job = try store.enqueueScreenshot(Data("image1".utf8))
        let sameImage = try store.enqueueScreenshot(Data("image1".utf8))
        precondition(sameImage.id != job.id && sameImage.state == "queued" && sameImage.image != nil)
        try store.deleteScreenshot(sameImage.id)
        job.state = "processing"; try store.updateScreenshot(job)
        rejects { try store.deleteScreenshot(job.id) }
        // 模拟进程中断：重开数据库后同一 UUID 恢复失败任务并保留图片。
        let recovered = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        try recovered.recoverScreenshots()
        let interrupted = try recovered.screenshotBook().jobs[0]
        precondition(interrupted.id == job.id && interrupted.state == "failed" && interrupted.image != nil)
        // 系统上传仍负责的任务在进程恢复时保持处理中；丢失后台任务则保存明确失败原因及原图片。
        var backgroundJob = interrupted; backgroundJob.state = "processing"
        try recovered.updateScreenshot(backgroundJob)
        try recovered.recoverScreenshots(excluding: [job.id])
        try check(try recovered.screenshotBook().jobs[0].state == "processing")
        try recovered.failScreenshot(job.id, spaceKey: recovered.activeKey, message: "后台识别已中断，请重试")
        try check(try recovered.screenshotBook().jobs[0].message == "后台识别已中断，请重试")
        try check(try recovered.screenshotBook().jobs[0].image != nil)
        job.extraction = extraction()
        // AI 建议直接匹配已有分类。
        try check(try store.prepareScreenshot(job).categoryID == category)
        job = try store.prepareScreenshot(job)
        precondition(job.message.isEmpty && job.accountID == account && job.categoryID == category)
        let queuedBefore = store.queue.count
        let completed = try store.postScreenshot(job, manual: false)
        precondition(completed.state == "posted" && completed.image == nil)
        // 系统迟到的失败回调不能覆盖已原子入账的回执和余额。
        try store.failScreenshot(job.id, spaceKey: store.activeKey, message: "迟到的上传错误")
        try check(try store.screenshotBook().jobs.first(where: { $0.id == job.id })?.state == "posted")
        precondition(store.queue.count == queuedBefore + 1 && store.rows("accounts")[0]["balance"] as? String == "79.50")
        _ = try store.postScreenshot(job, manual: false)
        precondition(store.queue.count == queuedBefore + 1)
        let reopened = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        try check(try reopened.screenshotBook().jobs[0].state == "posted")
        precondition(reopened.rows("transactions").count == 1 && reopened.queue.count == queuedBefore + 1)
        // 商品备注随流水和同步队列持久化，重启后保持原文。
        precondition(reopened.rows("transactions")[0]["description"] as? String == "面筋年糕各两串等3件商品")
        precondition((reopened.queue.last?["body"] as? [String: Any])?["description"] as? String == "面筋年糕各两串等3件商品")
        let balanceBeforeDeletion = store.rows("accounts")[0]["balance"] as? String
        try store.deleteScreenshot(completed.id)
        try check(try store.screenshotBook().jobs.isEmpty)
        precondition(store.rows("transactions").count == 1 && store.queue.count == queuedBefore + 1 && store.rows("accounts")[0]["balance"] as? String == balanceBeforeDeletion)
        let afterDeletion = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        try check(try afterDeletion.screenshotBook().jobs.isEmpty)
        // 旧版订单凭据兼容读取，但不阻止用户用同一图片和订单再次自动入账。
        var legacySpace = store.space
        var legacyBook = try FinanceLocalStore.screenshotObject(store.screenshotBook()) as! [String: Any]
        legacyBook["postedOrders"] = [["channel": "wechat", "orderId": "ORDER-001"]]
        legacySpace["screenshotBookkeeping"] = legacyBook
        try store.saveSpace(legacySpace)
        var other = try store.enqueueScreenshot(Data("image2".utf8)); other.extraction = extraction(); other = try store.prepareScreenshot(other)
        precondition(other.message.isEmpty && other.image != nil)
        try store.updateScreenshot(other)
        let otherPosted = try store.postScreenshot(other, manual: false)
        precondition(store.rows("transactions").count == 2)
        // 删除真实流水后，同订单新任务仍能自动入账；同一任务再次提交只返回回执。
        _ = try store.writeLocal("/finance/transactions/\(otherPosted.transactionID!)", method: "DELETE", body: [:])
        precondition(store.rows("transactions").filter { $0["status"] as? String == "posted" }.count == 1)
        var repeated = try store.enqueueScreenshot(Data("image3".utf8)); repeated.extraction = extraction(); repeated = try store.prepareScreenshot(repeated)
        precondition(repeated.message.isEmpty)
        try store.updateScreenshot(repeated)
        _ = try store.postScreenshot(repeated, manual: false)
        _ = try store.postScreenshot(repeated, manual: false)
        precondition(store.rows("transactions").filter { $0["status"] as? String == "posted" }.count == 2)
        // 新版恢复旧重复拦截记录时直接创建流水；再次恢复不会重放已入账任务。
        var legacyBlocked = try store.enqueueScreenshot(Data("legacy-blocked".utf8))
        legacyBlocked.extraction = extraction(); legacyBlocked.state = "review"; legacyBlocked.message = "该订单已经入账"
        try store.updateScreenshot(legacyBlocked)
        try check(try store.resumeRecognizedScreenshots() == 1)
        try check(try store.resumeRecognizedScreenshots() == 0)
        try check(try store.screenshotBook().jobs.first(where: { $0.id == legacyBlocked.id })?.state == "posted")
        for amount in ["0", "-1", "1.001", "1e2", "NaN", "01", "100000000000"] {
            var value = extraction(); value.amount = amount; rejects { try value.validate() }
        }
        var invalid = extraction(); invalid.date = "2026-02-30"; rejects { try invalid.validate() }
        invalid = extraction(); invalid.time = "25:00"; rejects { try invalid.validate() }
        invalid = extraction(); invalid.kind = "transfer"; rejects { try invalid.validate() }
        invalid = extraction(); invalid.currency = "USD"; rejects { try invalid.validate() }
        var unsure = try store.enqueueScreenshot(Data("image4".utf8)); unsure.extraction = extraction("ORDER-004"); unsure.extraction?.amount = ""
        unsure = try store.prepareScreenshot(unsure); try store.updateScreenshot(unsure)
        rejects { _ = try store.postScreenshot(unsure, manual: false) }
        // 重复尾号、未知尾号和禁用账户不得自动选取。
        let account2 = try FinanceOfflineTests.account(store, name: "其他卡", balance: "0.00")
        _ = try store.writeLocal("/finance/accounts/\(account)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        var card = extraction(); card.paymentCardLast4 = "1234"; card.paymentMethod = "招商银行储蓄卡（尾号1234）"
        precondition(store.screenshotAccount(card) == account)
        _ = try store.writeLocal("/finance/accounts/\(account2)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        precondition(store.screenshotAccount(card) == 0)
        _ = try store.writeLocal("/finance/accounts/\(account2)", method: "PATCH", body: ["selectable": false])
        precondition(store.screenshotAccount(card) == account)
        card.paymentCardLast4 = nil
        precondition(store.screenshotAccount(card) == 0)
        card.paymentCardLast4 = "9999"
        precondition(store.screenshotAccount(card) == 0)
        card.paymentCardLast4 = "12345"
        precondition(store.screenshotAccount(card) == 0)
        _ = try store.writeLocal("/finance/accounts/\(account2)", method: "PATCH", body: ["selectable": true])
        try check(try store.prepareScreenshot(unsure).accountID == 0)
        // 在单次提交前模拟磁盘路径消失，失败必须不改变内存余额、队列和任务状态。
        let failureDir = directory.appendingPathComponent("failure"); try FileManager.default.createDirectory(at: failureDir, withIntermediateDirectories: true)
        let failureStore = try FinanceLocalStore(url: failureDir.appendingPathComponent("ledger.sqlite"))
        try failureStore.commit(store.document)
        var failing = try failureStore.enqueueScreenshot(Data("image5".utf8)); failing.extraction = extraction("ORDER-005"); failing.accountID = account; failing.categoryID = category; failing.state = "review"; try failureStore.updateScreenshot(failing)
        let original = try JSONSerialization.data(withJSONObject: failureStore.document, options: .sortedKeys)
        try FileManager.default.removeItem(at: failureDir)
        rejects { _ = try failureStore.postScreenshot(failing, manual: true) }
        rejects { try failureStore.deleteScreenshot(failing.id) }
        try check(try JSONSerialization.data(withJSONObject: failureStore.document, options: .sortedKeys) == original)
        // 切换游客/用户空间不共享图片、同意与处理记录。
        var document = store.document; var spaces = store.spaces; spaces["isolated"] = FinanceLocalStore.emptySpace(); document["spaces"] = spaces; document["active"] = "isolated"; try store.commit(document)
        try check(try store.screenshotBook().jobs.isEmpty)
        rejects { _ = try store.enqueueScreenshot(Data("image1".utf8)) }
        print("Screenshot bookkeeping tests passed")
    }
    /// 验证多卡共用账户、商品备注及删除卡片后的历史；参数：无；返回值：无，仅写临时账本，失败抛错或中止断言。
    static func sharedCards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        let cards = [["id": "domestic", "name": "国内卡", "maskedAccountNumber": "6222 0000 0000 1234"], ["id": "international", "name": "国际卡", "maskedAccountNumber": "8826"]]
        let row = try store.writeLocal("/finance/accounts", method: "POST", body: ["name": "招商信用账户", "accountType": "bank", "cards": cards, "creditLimit": "73000.00", "currentDebt": "0.00"]) as! [String: Any]
        let id = FinanceLocalStore.id(row)
        let saved = row["cards"] as! [[String: String]]
        precondition(saved[0]["maskedAccountNumber"] == "6222000000001234")
        // 完整号码及卡片顺序经过实际落盘重开仍需保留，云端脱敏由同步传输层负责。
        let cardReopened = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        let restoredCards = cardReopened.rows("accounts").first?["cards"] as! [[String: String]]
        precondition(restoredCards == saved)
        _ = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "餐饮", "type": "expense"])
        var book = try store.screenshotBook(); book.settings = ScreenshotSettings(enabled: true, configID: 1, consentID: "test")
        try store.saveScreenshotBook(book)
        for tail in ["1234", "8826"] {
            var job = try store.enqueueScreenshot(Data(tail.utf8))
            var value = extraction("ORDER-" + tail); value.paymentCardLast4 = tail; value.paymentMethod = "信用卡尾号" + tail
            value.note = "午餐套餐"
            value.merchant += tail
            job.extraction = value; job = try store.prepareScreenshot(job)
            precondition(job.accountID == id && job.message.isEmpty)
            try store.updateScreenshot(job)
            _ = try store.postScreenshot(job, manual: false)
        }
        precondition(store.rows("accounts").count == 1 && store.rows("accounts")[0]["balance"] as? String == "-41.00")
        precondition(store.rows("accounts")[0]["creditLimit"] as? String == "73000.00")
        // 回调输入流水、返回备注是否仅含商品；多卡匹配不得将付款信息写入备注。
        precondition(store.rows("transactions").allSatisfy { $0["description"] as? String == "午餐套餐" })
        _ = try store.writeLocal("/finance/accounts/\(id)", method: "PATCH", body: ["notes": "共用账单"])
        precondition((store.rows("accounts")[0]["cards"] as? [[String: Any]])?.count == 2)
        _ = try store.writeLocal("/finance/accounts/\(id)", method: "PATCH", body: ["cards": []])
        var value = extraction(); value.paymentCardLast4 = "8826"
        precondition(store.screenshotAccount(value) == 0)
        precondition(store.rows("transactions").count == 2 && store.rows("accounts")[0]["balance"] as? String == "-41.00")
        let reopened = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        precondition((reopened.rows("accounts")[0]["cards"] as? [[String: Any]])?.isEmpty == true)
    }
}

extension ScreenshotBookkeepingTests {
    /// 验证仅必要字段控制入账，缺失资料也自动进入流水；参数：无；返回值：无；使用临时数据库，检查未知金额不扣余额、重复投影稳定及补全后只生成一笔。
    static func requiredFieldsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinanceLocalStore(url: directory.appendingPathComponent("ledger.sqlite"))
        let account = try FinanceOfflineTests.account(store, name: "测试卡", balance: "100.00")
        _ = try store.writeLocal("/finance/accounts/\(account)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        var book = try store.screenshotBook()
        book.settings = ScreenshotSettings(enabled: true, configID: 1, consentID: "test")
        try store.saveScreenshotBook(book)
        var job = try store.enqueueScreenshot(Data("fixture".utf8))
        var value = extraction(""); value.needsReview = true; value.reason = "未显示完整交易单号"
        value.merchant = ""; value.time = ""; value.category = ""; value.amountEvidence = ""; value.paymentEvidence = ""
        job.extraction = value; job = try store.prepareScreenshot(job)
        precondition(job.message.isEmpty && job.categoryID == 0)
        try store.updateScreenshot(job); _ = try store.postScreenshot(job, manual: false)
        precondition(store.rows("transactions").count == 1)
        var missing = try store.enqueueScreenshot(Data("missing".utf8))
        missing.extraction = extraction(); missing.extraction?.amount = ""
        missing = try store.prepareScreenshot(missing)
        let balance = store.rows("accounts")[0]["balance"] as? String
        missing = try store.includeIncompleteScreenshot(missing)
        let id = missing.transactionID
        missing = try store.includeIncompleteScreenshot(missing)
        precondition(id == missing.transactionID)
        let rows = try store.transactions([:], paginated: true)
        precondition(rows.count == 2 && rows.first(where: { FinanceLocalStore.id($0) == id })?["amount"] as? String == "")
        _ = try JSONDecoder().decode([FinanceTransaction].self, from: JSONSerialization.data(withJSONObject: rows))
        try check(try store.transactions([:], paginated: false).count == 1)
        precondition(store.rows("accounts")[0]["balance"] as? String == balance)
        missing.extraction?.amount = "10.00"
        missing = try store.prepareScreenshot(missing)
        _ = try store.postScreenshot(missing, manual: false)
        try check(try store.incompleteScreenshotTransactions().isEmpty)
        precondition(store.rows("transactions").count == 2)
    }
}

/// 主线程可控响应替身，用于在网络挂起期间改变同意与账号，不访问真实服务器。
final class ScreenshotTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (@MainActor (URLRequest) throws -> (Int, Data))?
    /// 接管测试请求；参数：request 为请求；返回值：true，无副作用。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保留原请求；参数：request 为请求；返回值：原请求，无副作用。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 交由主线程替身完成响应；参数：无；返回值：无，错误通过 URLProtocol 回传。
    override func startLoading() {
        // 任务无参数和返回值；在回应之前执行测试的身份或同意变更，保证竞态可重复。
        Task { @MainActor in
            do {
                let (status, data) = try Self.response!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    /// 停止替身请求；参数：无；返回值：无，替身不持有网络资源。
    override func stopLoading() {}
}

extension ScreenshotBookkeepingTests {
    /// 验证真实 API 编解码下的失败重试、配置失效和跨账号结果隔离；参数：无；返回值：无，使用独立临时数据库与 URLProtocol。
    static func network() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); ScreenshotTestProtocol.response = nil }
        let store = try FinanceLocalStore(url: directory.appendingPathComponent("network.sqlite"))
        let account = try FinanceOfflineTests.account(store, name: "招商", balance: "100.00")
        _ = try store.writeLocal("/finance/accounts/\(account)", method: "PATCH", body: ["maskedAccountNumber": "1234"])
        _ = try store.writeLocal("/finance/categories", method: "POST", body: ["name": "餐饮", "type": "expense"])
        try store.enable(server: "https://test.invalid/api", profile: Profile(id: 7, account: "test", nickname: "测试", role: "user"))
        let originalKey = store.activeKey
        var book = try store.screenshotBook()
        book.settings = ScreenshotSettings(enabled: true, configID: 9, configVersion: "version", destination: "test", consentID: "consent")
        try store.saveScreenshotBook(book)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ScreenshotTestProtocol.self]
        let api = APIClient(baseURL: "https://test.invalid/api", session: URLSession(configuration: configuration)); api.token = "test-token"
        let result = try JSONEncoder().encode(extraction())
        let envelope = try FinanceLocalStore.envelope(JSONSerialization.jsonObject(with: result))
        let first = try store.enqueueScreenshot(Data("network1".utf8))
        // 请求回调输入真实请求，返回网络异常；检查外发只包含识别白名单，不包含写入字段。
        ScreenshotTestProtocol.response = { request in
            let body = try CoreTests.body(request)
            precondition(request.url?.path == "/api/ai/screenshot" && body["configId"] as? Int == 9 && body["configVersion"] as? String == "version" && body["accountId"] == nil)
            throw URLError(.timedOut)
        }
        do { _ = try await store.recognizeScreenshot(first.id, api: api, isCurrent: { true }); preconditionFailure("超时应失败") } catch { }
        try check(try store.screenshotBook().jobs[0].state == "failed")
        precondition(store.rows("transactions").isEmpty)
        // 请求回调返回固定成功信封；稳定任务重试只记一次。
        ScreenshotTestProtocol.response = { _ in (200, envelope) }
        _ = try await store.recognizeScreenshot(first.id, api: api, isCurrent: { true })
        _ = try await store.recognizeScreenshot(first.id, api: api, isCurrent: { true })
        precondition(store.rows("transactions").count == 1)
        // 相同图片及订单再次导入必须重新识别并自动增加一笔，不要求重复确认。
        var repeatedCalls = 0
        ScreenshotTestProtocol.response = { _ in repeatedCalls += 1; return (200, envelope) }
        let sameImage = try store.enqueueScreenshot(Data("network1".utf8))
        _ = try await store.recognizeScreenshot(sameImage.id, api: api, isCurrent: { true })
        precondition(repeatedCalls == 1 && sameImage.id != first.id && store.rows("transactions").count == 2)
        var ignored = try store.screenshotBook().jobs.first { $0.id == sameImage.id }!
        ignored.state = "ignored"; ignored.image = nil; try store.updateScreenshot(ignored)
        let afterIgnore = try store.enqueueScreenshot(Data("network1".utf8))
        _ = try await store.recognizeScreenshot(afterIgnore.id, api: api, isCurrent: { true })
        precondition(repeatedCalls == 2 && afterIgnore.id != ignored.id && store.rows("transactions").count == 3)
        try store.deleteScreenshot(ignored.id)
        try store.deleteScreenshot(afterIgnore.id)
        let second = try store.enqueueScreenshot(Data("network2".utf8))
        // 请求回调在响应前撤回同意，返回模型成功；业务必须拒绝过期结果。
        ScreenshotTestProtocol.response = { _ in
            var next = try store.screenshotBook(); next.settings.enabled = false; next.settings.consentID = ""; try store.saveScreenshotBook(next)
            return (200, envelope)
        }
        do { _ = try await store.recognizeScreenshot(second.id, api: api, isCurrent: { true }); preconditionFailure("关闭后不应接收结果") } catch { }
        precondition(store.rows("transactions").count == 3)
        try check(try store.screenshotBook().jobs[0].state == "failed")
        var calls = 0
        ScreenshotTestProtocol.response = { _ in calls += 1; return (200, envelope) }
        do { _ = try await store.recognizeScreenshot(second.id, api: api, isCurrent: { true }); preconditionFailure("关闭后不应外发") } catch { }
        precondition(calls == 0)
        book = try store.screenshotBook(); book.settings.enabled = true; book.settings.consentID = "new-consent"; try store.saveScreenshotBook(book)
        // 请求回调在响应前退出原空间，返回成功；图片仅保留原空间且新空间没有交易。
        ScreenshotTestProtocol.response = { _ in try store.useGuest(); return (200, envelope) }
        do { _ = try await store.recognizeScreenshot(second.id, api: api, isCurrent: { true }); preconditionFailure("切换空间后不应接收结果") } catch { }
        precondition(store.activeKey == "guest" && store.rows("transactions").isEmpty)
        try check(try store.screenshotBook().jobs.isEmpty)
        let original = store.spaces[originalKey]!["screenshotBookkeeping"]!
        let saved = try JSONDecoder().decode(ScreenshotBook.self, from: JSONSerialization.data(withJSONObject: original))
        precondition(saved.jobs.first { $0.id == second.id }?.state == "failed" && saved.jobs.first { $0.id == second.id }?.image != nil)
        // 系统后台回调同样只写原空间错误；当前游客空间没有截图或流水，不切回旧账号。
        try store.failScreenshot(second.id, spaceKey: originalKey, message: "账号已变化，请重新处理")
        precondition(store.activeKey == "guest" && store.rows("transactions").isEmpty)
        try check(try store.screenshotBook().jobs.isEmpty)
        let updated = try JSONDecoder().decode(ScreenshotBook.self, from: JSONSerialization.data(withJSONObject: store.spaces[originalKey]!["screenshotBookkeeping"]!))
        precondition(updated.jobs.first { $0.id == second.id }?.message == "账号已变化，请重新处理")
        print("Screenshot network lifecycle tests passed")
    }
}
