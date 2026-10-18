import Foundation
import HealthKit

/// URLProtocol 契约替身只在测试可执行文件中存在，不访问网络或用户凭证。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    /// 决定接管请求；参数：request 为测试请求；返回值：始终 true，无副作用。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保留规范请求；参数：request 为输入请求；返回值：原请求，无副作用。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 执行替身响应；参数：无；返回值：无；将测试断言错误交回 URLSession，不发网络请求。
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    /// 结束替身请求；参数：无；返回值：无；同步替身不持有待取消资源。
    override func stopLoading() {}
}

@main struct CoreTests {
    @MainActor static var count = 0
    /// 验证断言；参数：condition 为结果，name 为案例名；返回值：无；不满足时终止测试进程。
    @MainActor static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        count += 1
        print("PASS \(name)")
    }
    /// 创建任务 fixture；参数：id 为主键，parent 为父 ID，type 为类型，total/completed 为进度，archived 为归档标记；返回值：固定其他属性的任务。
    static func task(_ id: Int, parent: Int? = nil, type: String = "subtask", total: Double = 10, completed: Double = 0, archived: Bool = false) -> AssistantTask {
        AssistantTask(id: id, title: "任务", remark: "", listId: 1, parentId: parent, taskType: type, priority: "medium", startDate: "", startTime: "", endDate: "", endTime: "", archived: archived, sortOrder: 0, progressTotal: total, progressCompleted: completed, progressStep: 1, progressUnit: "页")
    }
    /// 读取请求 JSON；参数：request 为请求（正文可能通过流传输）；返回值：字典；测试正文无效时抛错。
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    /// 验证归档子树显示规则；参数：无；返回值：无；仅使用内存快照，覆盖自动归档、多层后代、恢复、搜索及异常父关系，不访问服务器或修改真实数据。
    @MainActor static func checkTaskArchiveVisibility() {
        var root = task(701, type: "main", completed: 10, archived: true); root.autoArchive = true
        let branch = task(702, parent: root.id, type: "main")
        var leaf = task(703, parent: branch.id, completed: 10); leaf.title = "归档后代搜索样本"
        let ownArchived = task(704, parent: branch.id, completed: 10, archived: true)
        let completedActive = task(705, completed: 10)
        let orphan = task(706, parent: 999999)
        var otherList = task(707); otherList.listId = 2
        // 故意打乱父子顺序，模拟服务端排序；归档传播必须覆盖任意深度，而非依赖父节点先出现。
        let snapshot = [leaf, completedActive, root, ownArchived, branch, orphan, otherList]
        let original = snapshot
        let active = Values.tasks(in: "active", all: snapshot)
        let archived = Values.tasks(in: "archived", all: snapshot)
        check(active.map(\.id) == [705, 706, 707], "未归档范围隐藏自动归档父节点及多层下级")
        check(archived.map(\.id) == [703, 701, 704, 702], "归档范围保留整棵归档子树且不改变原顺序")
        check(Values.tasks(in: "all", all: snapshot) == original, "包含归档时返回完整原始快照")
        check(Values.tasks(in: "active", all: snapshot, listID: 1).map(\.id) == [705, 706], "清单筛选与归档规则一致")
        check(Values.tasks(in: "unexpected", all: snapshot) == active, "未知范围按未归档处理")
        check(active.contains(completedActive), "已完成但未归档任务仍然可见")
        check(active.contains(orphan), "真正缺失父节点的任务保留可达")
        check(active.filter { $0.title.contains("归档后代") }.isEmpty, "搜索不会泄漏归档祖先的下级")
        check(snapshot == original && !leaf.archived && !branch.archived, "显示筛选不改写下级归档字段及快照")
        check(Values.progress(root, all: snapshot).completed == 20, "完整进度继续包含归档子树")
        var restored = root; restored.archived = false; restored.autoArchive = false
        let restoredSnapshot = snapshot.map { $0.id == root.id ? restored : $0 }
        check(Values.tasks(in: "active", all: restoredSnapshot).map(\.id) == [703, 705, 701, 702, 706, 707], "恢复父节点后原未归档下级重新可见且无重复")
        check(Values.tasks(in: "archived", all: restoredSnapshot).map(\.id) == [704], "恢复父节点不恢复独立归档的下级")
        var crossListLeaf = leaf; crossListLeaf.listId = 2
        check(Values.tasks(in: "active", all: [root, branch, crossListLeaf], listID: 2).isEmpty, "清单筛选前使用完整快照检查归档祖先")
        let cyclicA = task(801, parent: 802, archived: true), cyclicB = task(802, parent: 801)
        check(Values.tasks(in: "active", all: [cyclicA, cyclicB]).isEmpty && Values.tasks(in: "archived", all: [cyclicA, cyclicB]).count == 2, "循环关系的归档传播安全终止")
        var deep = [root]
        for id in 1000..<3000 { deep.append(task(id, parent: id == 1000 ? root.id : id - 1)) }
        check(Values.tasks(in: "active", all: deep).isEmpty && Values.tasks(in: "archived", all: deep).count == deep.count, "深层归档子树迭代处理不依赖递归栈")
        check(Values.tasks(in: "active", all: []).isEmpty && Values.tasks(in: "archived", all: []).isEmpty, "空快照归档范围均为空")
    }

    /// 执行业务和传输回归；参数：无；返回值：无；验证机构兼容、精度、PATCH、进度、查询、错误与 401 行为，不连接实际 API。
    @MainActor static func main() async throws {
        checkTaskArchiveVisibility()
        // 新入口回归仅使用虚构文本和内存任务；识别、层级规则及展示偏好不依赖网络或真实账本。
        try TextBookkeepingTests.run()
        try TaskBrowsingTests.run()
        // 本地日历截止边界：当天时分必须参与逾期判断，空时分使用 23:59。
        var deadlineTask = task(980)
        deadlineTask.endDate = "2026-10-04"; deadlineTask.endTime = "10:30"
        let deadlineFormatter = DateFormatter()
        deadlineFormatter.locale = Locale(identifier: "en_US_POSIX"); deadlineFormatter.calendar = Calendar(identifier: .gregorian)
        deadlineFormatter.timeZone = .current; deadlineFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        check(!Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-04 10:30:00")!), "截止相等未逾期")
        check(Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-04 10:30:01")!), "当天截止后逾期")
        check(!Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-04 09:00:00")!), "当天截止前未逾期")
        deadlineTask.endTime = ""
        check(!Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-04 23:58:59")!), "空截止时间默认23:59前未逾期")
        check(Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-05 00:00:00")!), "次日超过空截止时间")
        deadlineTask.archived = true
        check(!Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-05 00:00:00")!), "归档任务不标逾期")
        deadlineTask.archived = false; deadlineTask.progressCompleted = deadlineTask.progressTotal
        check(!Values.taskIsOverdue(deadlineTask, all: [deadlineTask], now: deadlineFormatter.date(from: "2026-10-05 00:00:00")!), "完成任务不标逾期")
        check(AmountKeypad.calculate("0.1", operation: "+", rhs: "0.2") == "0.3", "优惠计算保持十进制精度")
        check(AmountKeypad.calculate("10", operation: "÷", rhs: "3") == "3.33", "优惠除法按分舍入")
        check(AmountKeypad.calculate("2.55", operation: "×", rhs: "3") == "7.65", "优惠乘法金额正确")
        check(AmountKeypad.calculate("1", operation: "÷", rhs: "0") == nil, "优惠计算拒绝除零")
        check(AmountKeypad.calculate("1", operation: "−", rhs: "2") == nil, "优惠计算拒绝负金额")
        check(AmountKeypad.calculate("1000000000000", operation: "+", rhs: "1") == nil, "优惠计算拒绝超限金额")
        check(AmountKeypad.calculate("-66", operation: "+", rhs: "6", allowNegative: true) == "-60", "账户计算支持已有欠款")
        check(AmountKeypad.calculate("2", operation: "−", rhs: "5", allowNegative: true) == "-3", "账户计算允许负结果")
        check(AmountKeypad.calculate("2oops", operation: "+", rhs: "1") == nil, "金额计算拒绝部分可解析文本")
        var calculation = AmountCalculation()
        var draft = "66"
        // 按真实按键顺序验证替换符号、连续运算和求值后的新输入。
        for key in ["+", "×", "3", "+", "2", "="] { calculation.input(key, draft: &draft) }
        check(draft == "200" && calculation.operation == nil, "连续计算按输入顺序且允许替换符号")
        calculation.input("8", draft: &draft)
        check(draft == "8", "求值后数字开启新金额")
        for key in ["÷", "0", "="] { calculation.input(key, draft: &draft) }
        check(calculation.error == "除数不能为 0" && calculation.operand == "8", "除零保留算式供修改")
        for key in ["删除", "2", "="] { calculation.input(key, draft: &draft) }
        check(draft == "4" && calculation.error == nil, "修正除数后正常求值")
        calculation.input("+", draft: &draft)
        check(!calculation.evaluate(draft: &draft), "完成拒绝缺少右操作数的算式")
        calculation.input("删除", draft: &draft)
        check(calculation.operation == nil && draft == "4", "删除待输入符号恢复原金额")
        for key in ["−", "8"] { calculation.input(key, draft: &draft) }
        check(calculation.evaluate(draft: &draft) && draft == "-4", "完成自动计算负数结果")
        for key in ["×", "清空"] { calculation.input(key, draft: &draft) }
        check(draft == "0" && calculation.operation == nil && calculation.error == nil, "清空重置整笔计算")
        // 预览应按最终结果判断可保存性，同时不消费算式；覆盖右操作数为零、小数、错误及非正值。
        for (keys, expected) in [(["+", "0"], "100"), (["×", "0", ".", "5"], "50"), (["−", "1", "0", "0"], "0"), (["−", "2", "0", "0"], "-100")] {
            var previewCalculation = AmountCalculation()
            var previewDraft = "100"
            for key in keys { previewCalculation.input(key, draft: &previewDraft) }
            let originalDraft = previewDraft
            let originalOperand = previewCalculation.operand
            let originalOperation = previewCalculation.operation
            check(previewCalculation.preview(draft: previewDraft) == expected, "金额预览使用最终结果 \(keys)")
            check(previewDraft == originalDraft && previewCalculation.operand == originalOperand && previewCalculation.operation == originalOperation && previewCalculation.error == nil, "渲染预览不改变草稿或算式")
            check(Values.validMoney(expected, positive: true) == (expected == "100" || expected == "50"), "最终非正金额不可保存")
            check(previewCalculation.evaluate(draft: &previewDraft) && previewDraft == expected, "实际求值与预览一致")
        }
        for keys in [["÷", "0"], ["+"], ["×", "9", "9", "9", "9", "9", "9", "9", "9", "9", "9", "9"]] {
            var invalidCalculation = AmountCalculation()
            var invalidDraft = "100"
            for key in keys { invalidCalculation.input(key, draft: &invalidDraft) }
            check(invalidCalculation.preview(draft: invalidDraft) == nil && invalidCalculation.error == nil, "错误预览不修改原状态")
            check(!invalidCalculation.evaluate(draft: &invalidDraft) && invalidCalculation.error != nil && invalidCalculation.operation != nil, "实际完成保留错误算式并提供反馈")
        }
        AccountIconBackgroundTests.run()
        AccountPresentationTests.run()
        AccountTransactionPeriodTests.run()
        // 计划汇总只依赖期数，验证分项守恒与已结清边界，不误称真实流水已还。
        let loanRows = [LoanPaymentSummary(period: 1, date: "2028-01-31", principal: "10.01", interest: "1.23", payment: "11.24", remaining: "10.02"), LoanPaymentSummary(period: 2, date: "2028-02-29", principal: "10.02", interest: "0.50", payment: "10.52", remaining: "0.00")]
        let totals = LoanPlanTotals(schedule: loanRows, paidPeriods: 1)
        check(totals.paidTotal == Decimal(string: "11.24") && totals.remainingTotal == Decimal(string: "10.52"), "贷款计划本息分项精确汇总")
        check(LoanPlanTotals(schedule: loanRows, paidPeriods: 2).progress == 1, "贷款计划结清本金进度")
        check(LoanPlanTotals(schedule: [], paidPeriods: 0).progress == 0, "空贷款计划无除零")
        let adjustable = LoanPlanSummary(revision: 4, paidPeriods: 0, lastPaymentPeriod: 2, schedule: loanRows, remainingPrincipal: "20.03", totalInterest: "1.73")
        check(LoanDetailPresentation.adjustmentPeriod(adjustable, today: "2028-02-01") == 2, "调整默认从本月未还期次开始")
        check(LoanDetailPresentation.adjustmentPeriod(adjustable, today: "2029-01-01") == 1, "逾期计划仍可明确选择未还期次")
        var closedPlan = adjustable; closedPlan.paidPeriods = 2
        check(LoanDetailPresentation.adjustmentPeriod(closedPlan, today: "2028-02-01") == 1, "计划已还完仍可修正历史分期")
        check((closedPlan.schedule ?? []).allSatisfy(LoanDetailPresentation.canAdjust), "计划已还行仍提供侧滑调整和表单选项")
        var partlyPaid = adjustable; partlyPaid.paidPeriods = 1
        check(LoanDetailPresentation.adjustmentPeriod(partlyPaid, today: "2029-01-01") == 2, "默认入口优先未还期次而不是已还历史")
        let zeroTail = LoanPaymentSummary(period: 3, date: "2028-03-31", principal: "0", interest: "0", payment: "0", remaining: "0")
        check(!LoanDetailPresentation.canAdjust(zeroTail), "提前结清后的零本金尾期不提供调整")
        check(LoanDetailPresentation.adjustmentPeriod(LoanPlanSummary(schedule: [], remainingPrincipal: "0", totalInterest: "0"), today: "2028-02-01") == nil, "空计划没有生效期次")
        let historicalDraft = LoanAdjustmentDraft(row: loanRows[0], fallbackRate: "4.1", kind: .rate)
        check(historicalDraft.fromPeriod == 1 && historicalDraft.valid && historicalDraft.fields(revision: 4)["fromPeriod"] as? Int == 1, "已还期次调整草稿保留所选期数并可提交")
        var adjustment = LoanAdjustmentDraft(row: loanRows[1], fallbackRate: "4.1", kind: .rate)
        check(adjustment.fields(revision: 4)["payment"] == nil, "自动计算不发送自定义金额")
        adjustment.annualRate = "0"
        check(adjustment.valid, "分期调息接受零利率")
        check(adjustment.fields(revision: 4)["kind"] as? String == "rate" && adjustment.fields(revision: 4)["paymentMode"] == nil, "利率入口只提交利率字段")
        adjustment.annualRate = "100.0001"
        check(!adjustment.valid, "分期利率拒绝越界")
        var amountAdjustment = LoanAdjustmentDraft(row: loanRows[1], fallbackRate: "4.1", kind: .payment)
        check(amountAdjustment.payment == "10.52", "金额入口预填选中期次应还额")
        amountAdjustment.payment = "123.45"
        check(amountAdjustment.valid && amountAdjustment.fields(revision: 4)["payment"] as? String == "123.45", "自定义本息保留精确金额")
        check(amountAdjustment.fields(revision: 4)["kind"] as? String == "reprice" && amountAdjustment.fields(revision: 4)["annualRate"] as? String == amountAdjustment.annualRate, "金额校准同时提交后续执行利率")
        amountAdjustment.payment = "0"
        check(!amountAdjustment.valid, "自定义月供拒绝零金额")
        amountAdjustment.payment = "1.001"
        check(!amountAdjustment.valid, "自定义月供拒绝超过两位小数")
        check(amountAdjustment.fields(revision: 4)["scope"] as? String == "period" && amountAdjustment.fields(revision: 4)["paymentMode"] == nil, "金额请求仅限单期，不提交持续月供方式")
        var corrected = loanRows[0]; corrected.payment = "9.99"; corrected.paymentOverridden = true
        let correctedTotals = LoanPlanTotals(schedule: [corrected, loanRows[1]], paidPeriods: 1)
        check(correctedTotals.paidTotal == Decimal(string: "9.99") && correctedTotals.remainingTotal == totals.remainingTotal, "单期修正计入合计但不改变后续期次")
        check(correctedTotals.paidPrincipal == totals.paidPrincipal && correctedTotals.paidInterest == totals.paidInterest, "修正差额不能伪装为本金或利息")
        check(LoanDetailPresentation.paymentCorrection(corrected) != nil && LoanDetailPresentation.paymentCorrection(loanRows[1]) == nil, "只有金额修正期次显示差额")
        let transfer = FinanceTransaction(id: 1, accountId: 2, targetAccountId: 3, type: "transfer", amount: "123.45", categoryId: nil, counterparty: "", transactionDate: "2028-01-31", description: "", status: "posted", source: "http")
        check(transfer.transactionDateTime == "2028-01-31", "旧流水不虚构时间")
        var timedTransfer = transfer
        timedTransfer.transactionTime = "00:00"
        check(timedTransfer.transactionDateTime == "2028-01-31 00:00", "午夜时间保留")
        timedTransfer.transactionTime = "18:42"
        check(timedTransfer.transactionDateTime == "2028-01-31 18:42", "流水日期时间展示")

        check(LoanDetailPresentation.change(transfer, accountID: 3) == Decimal(string: "123.45"), "贷款转入按流入汇总")
        check(LoanDetailPresentation.change(transfer, accountID: 2) == Decimal(string: "-123.45"), "来源账户转账按流出汇总")
        check(LoanDetailPresentation.change(transfer, accountID: 4) == 0, "无关账户流水不参与汇总")
        let monthRange = LoanDetailPresentation.monthRange(Values.date("2028-02-15"))
        check(monthRange.start == "2028-02-01" && monthRange.end == "2028-02-29", "贷款流水自然月范围覆盖闰年")
        // 样本回调输入序号、返回历史流水；跨页和跨年验证自动全量读取及月份汇总。
        let history = (1...1001).map { id in
            FinanceTransaction(id: id, accountId: 2, targetAccountId: 3, type: "transfer", amount: "1.00", categoryId: nil, counterparty: "", transactionDate: id <= 500 ? "2020-01-18" : "2026-09-18", description: "", status: "posted", source: "http")
        }
        var offsets: [Int] = []
        // 分页替身输入偏移量，返回对应最多 500 笔；记录调用次数，不访问网络。
        let allHistory = try await LoanDetailPresentation.allTransactions { offset in
            offsets.append(offset)
            return Array(history.dropFirst(offset).prefix(500))
        }
        check(allHistory.count == 1001 && offsets == [0, 500, 1000], "自动跨分页读取所有历史流水")
        let grouped = LoanDetailPresentation.transactionMonths(allHistory, accountID: 3)
        check(grouped.map(\.id) == ["2026-09-01", "2020-01-01"] && grouped[0].rows.first?.id == 1001, "全部月份及月内流水倒序且不生成空月份")
        check(grouped[0].inflow == 501 && grouped[1].inflow == 500 && grouped[0].outflow == 0, "跨页月份合计完整且转入方向正确")
        // 空页替身无视偏移量，返回无记录，验证空账户只需一次请求。
        let emptyHistory = try await LoanDetailPresentation.allTransactions { _ in [] }
        check(emptyHistory.isEmpty, "空账户全量加载立即结束")
        do {
            // 重复页替身无视偏移量，持续返回同一页，验证不会无限请求。
            _ = try await LoanDetailPresentation.allTransactions { _ in Array(history.prefix(500)) }
            check(false, "重复分页必须中止")
        } catch { check(true, "重复分页中止且不冒充完整数据") }
        do {
            // 故障替身输入偏移量，第二页抛错；返回无完整历史，避免将部分月份显示为总额。
            _ = try await LoanDetailPresentation.allTransactions { offset in
                if offset > 0 { throw URLError(.notConnectedToInternet) }
                return Array(history.prefix(500))
            }
            check(false, "分页失败必须抛错")
        } catch { check(true, "部分加载失败不发布错误合计") }
        // 金额键盘边界回归：只编辑十进制文本，覆盖替换、负数、小数精度及服务端金额上限。
        check(AmountKeypad.apply("8", to: "-0.00", replace: true) == "-8", "首次切换负数后输入金额")
        check(AmountKeypad.apply("8", to: "0.00", replace: true) == "8", "金额首次输入替换原值")
        check(AmountKeypad.apply(".", to: "0", replace: true) == "0.", "金额以小数点开始")
        check(AmountKeypad.apply(".", to: "12.3") == "12.3", "禁止重复小数点")
        check(AmountKeypad.apply("4", to: "12.3") == "12.34", "允许两位小数")
        check(AmountKeypad.apply("5", to: "12.34") == "12.34", "禁止第三位小数")
        check(AmountKeypad.apply("±", to: "12.34") == "-12.34", "欠款切换负数")
        check(AmountKeypad.apply("±", to: "-12.34") == "12.34", "欠款切换正数")
        check(AmountKeypad.apply("删除", to: "-1") == "-", "删除保留中间负号")
        check(AmountKeypad.apply("8", to: "-") == "-8", "负号后继续输入")
        check(AmountKeypad.apply("清空", to: "123.45") == "0", "金额清空")
        check(AmountKeypad.apply("00", to: "0") == "0", "不产生前导零")
        check(AmountKeypad.apply("00", to: "12") == "1200", "金额双零按键")
        check(AmountKeypad.apply("0", to: "100000000000") == "1000000000000", "允许金额上限")
        check(AmountKeypad.apply("1", to: "100000000000") == "100000000000", "阻止超过金额上限")
        check(AmountKeypad.apply("x", to: "12") == "12", "忽略非法金额按键")
        try checkAccountProviders()
        // 编辑旧账户不能因机构别名匹配而隐式改写持久化值；目录外及空机构同样需保留。
        let legacyBank = AccountProvider.resolve(type: "bank", institution: "工行")
        check(legacyBank.icon == "brand-icbc" && legacyBank.institution == "工行", "银行别名命中图标且保留原始名称")
        let customBank = AccountProvider.resolve(type: "bank", institution: "自定义地方银行")
        check(customBank.name == "自定义地方银行" && customBank.type == "bank" && customBank.icon == "bank", "未知银行保留名称和类型")
        check(AccountProvider.resolve(type: "cash", institution: "").institution.isEmpty, "空机构不被自动写入默认名称")
        check(AccountProvider.resolve(type: "bank", institution: "南京银行").name == "南京银行", "南京银行支持统一选择")
        check(AccountProvider.resolve(type: "savings", institution: "中国银行").type == "savings", "相同机构名称不改变原账户类型")
        check(legacyBank.matches("ICBC") && legacyBank.matches(" 工行 ") && !legacyBank.matches("支付宝"), "机构搜索支持别名和大小写")
        for value in ["0", "0.00", "-3.20", "999999999999.99", "1000000000000"] { check(Values.validMoney(value), "合法金额 \(value)") }
        for value in ["1e3", "1.001", " 1", "01", "NaN", "1000000000000.01", ""] { check(!Values.validMoney(value), "拒绝金额 \(value)") }
        check(!Values.validMoney("0", positive: true), "零支出被拒绝")
        check(!Values.validMoney("-1", positive: true), "负支出被拒绝")
        check(Values.money("123456789.01").contains("123,456,789.01"), "金额展示保留两位精度")
        let patch = Values.patch(original: ["enabled": true, "name": "A", "count": 1, "untouched": "keep"], edited: ["enabled": false, "name": "", "count": 0])
        check(patch["enabled"] as? Bool == false && patch["name"] as? String == "" && patch["count"] as? Int == 0 && patch["untouched"] == nil, "PATCH 保留零值且不覆盖未提交字段")
        check(Values.patch(original: ["name": "A"], edited: ["name": "A"]).isEmpty, "无变化不提交")
        check(Values.patch(original: ["parentId": 1], edited: ["parentId": NSNull()])["parentId"] is NSNull, "PATCH 支持清除父节点")
        let parent = task(1, type: "main")
        let child = task(2, parent: 1, completed: 5, archived: true)
        let emptyMain = task(3, parent: 1, type: "main", total: 20, completed: 2)
        let progress = Values.progress(parent, all: [parent, child, emptyMain])
        check(progress.total == 10 && progress.completed == 5, "汇总归档叶而排除空主任务原始配置")
        check(Values.progress(emptyMain, all: [emptyMain]).total == 0 && Values.progress(emptyMain, all: [emptyMain]).fraction == 0, "空主任务展示零而非完成")
        let oneStep = task(4, parent: 1, total: 1, completed: 1)
        let sum = Values.progress(parent, all: [parent, child, oneStep, emptyMain])
        check(sum.total == 11 && sum.completed == 6 && abs(sum.fraction - 6.0 / 11) < 0.000001, "5/10与1/1量化求和6/11")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(child)) as! [String: Any]
        legacyJSON.removeValue(forKey: "icon")
        let legacyDecoded = try JSONDecoder().decode(AssistantTask.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacyDecoded.icon == nil && TaskIcons.symbol(legacyDecoded.icon) == "folder", "缺图标字段旧JSON可解码并回退")
        check(TaskIcons.symbol("unknown-custom-key") == "folder", "未知图标显示回退但不改原字段")
        // 确认整树迁移后的本地快照保持所有后代归属一致，并保留其他字段，读取失败不应撤销此快照。
        var savedRoot = parent; savedRoot.listId = 2; savedRoot.title = "移动后的根"
        var otherList = task(8, total: 2, completed: 1); otherList.listId = 3
        let movedSnapshot = Values.tasksAfterConfirmedWrite(savedRoot, snapshot: [parent, child, emptyMain, oneStep, otherList])
        check(movedSnapshot.filter { $0.id != 8 }.allSatisfy { $0.listId == 2 } && movedSnapshot.last == otherList, "确认整树move本地后代和根同清单，其他清单不动")
        var expectedChild = child; expectedChild.listId = 2
        check(movedSnapshot.first { $0.id == child.id } == expectedChild, "确认move只改后代listId，归档进度标题父关系不变")
        check(movedSnapshot.first { $0.id == 1 } == savedRoot, "确认move根使用完整成功实体")
        let hiddenOrder = Values.taskOrderPreservingHidden([parent, child, emptyMain, oneStep, otherList], orderedVisibleIDs: [4, 2])
        check(hiddenOrder == [1, 4, 3, 2, 8], "可见同父排序保留隐藏子树及其他清单位置")
        check(Values.taskOrderPreservingHidden([parent, child], orderedVisibleIDs: [2, 2]) == [1, 2], "非法重复排序不改变全序列")
        let cyclicA = task(1, parent: 2); let cyclicB = task(2, parent: 1)
        check(Values.progress(cyclicA, all: [cyclicA, cyclicB]).total == 0, "循环关系不会无限递归")
        check(try APIClient.normalize(" https://example.com/ ") == "https://example.com/api", "规范化默认 API 路径")
        check(try APIClient.normalize("http://localhost:16101/api/") == "http://localhost:16101/api", "允许本地开发地址")
        for host in ["192.168.88.185", "10.0.0.1", "172.16.0.1", "172.31.255.254", "127.0.0.2", "Mac.local"] {
            check(try APIClient.normalize("http://\(host):20000/api") == "http://\(host):20000/api", "允许本地 HTTP：\(host)")
        }
        for host in ["172.15.0.1", "172.32.0.1", "192.169.1.1", "8.8.8.8", "192.168.1.999", "192.168.evil.com", "192.168.1.1.evil.com", "010.0.0.1", ".local"] {
            check(!APIClient.isLocalHTTPHost(host), "拒绝伪装或公网 HTTP：\(host)")
        }
        for url in ["http://example.com/api", "https://user:secret@example.com/api", "https://example.com/api?token=secret", "file:///tmp/a"] {
            do { _ = try APIClient.normalize(url); check(false, "危险地址应拒绝") } catch { check(true, "拒绝非预期地址") }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let connectionSession = URLSession(configuration: configuration)
        // 健康替身回调接收请求并返回状态码与 JSON；验证测试只访问草稿地址且不发送凭证。
        StubProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://draft.example.com/api/health")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.timeoutInterval == 10)
            return (200, Data(#"{"code":200,"data":{"service":"personal-assistant","status":"ok"}}"#.utf8))
        }
        try await APIClient.testConnection("https://draft.example.com/api", session: connectionSession)
        check(true, "服务器连接测试匿名访问草稿健康接口")
        // 错误服务替身输入请求、输出其他服务响应；200 状态也不得被当作连接成功。
        StubProtocol.handler = { _ in (200, Data(#"{"code":200,"data":{"service":"other","status":"ok"}}"#.utf8)) }
        do {
            try await APIClient.testConnection("https://draft.example.com/api", session: connectionSession)
            preconditionFailure("接受了其他服务的健康响应")
        } catch { check(error is APIError, "连接测试拒绝错误服务响应") }
        let api = APIClient(baseURL: "https://example.com/api", session: URLSession(configuration: configuration))
        api.token = "test-token"
        // 请求断言回调：输入为请求；输出为状态码与 JSON；验证 Bearer、路径、URL 编码和业务解包。
        StubProtocol.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            precondition(url.path == "/api/users/me" && url.queryItems?.first?.value == "早餐 & 咖啡")
            return (200, Data(#"{"code":200,"message":"ok","data":{"id":1,"account":"test","nickname":"测试","role":"user"}}"#.utf8))
        }
        let profile: Profile = try await api.request("/users/me", query: [URLQueryItem(name: "keyword", value: "早餐 & 咖啡")])
        check(profile.id == 1 && !profile.isAdmin, "认证头、查询编码与业务解包")
        // PATCH 断言回调：输入为请求；输出为成功信封；确保 false 使用 JSON 布尔值。
        // 删除请求契约回调输入真实URLRequest、输出成功信封；断言cascade未被客户端查询规范化丢弃。
        StubProtocol.handler = { request in
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            precondition(request.httpMethod == "DELETE" && url.path == "/api/tasks/980")
            precondition(url.queryItems == [URLQueryItem(name: "cascade", value: "true")])
            return (200, Data(#"{"data":null}"#.utf8))
        }
        try await api.mutate("/tasks/980", method: "DELETE", query: [URLQueryItem(name: "cascade", value: "true")])
        check(true, "任务级联删除保留真实cascade查询")
        StubProtocol.handler = { request in
            let body = try body(request)
            precondition(request.httpMethod == "PATCH" && body.count == 1 && body["includeInNetWorth"] as? Bool == false)
            return (200, Data(#"{"data":null}"#.utf8))
        }
        try await api.mutate("/finance/accounts/1", method: "PATCH", body: ["includeInNetWorth": false])
        check(true, "PATCH 传输保留 false 且忽略空成功体")
        // 错误响应替身：输入为请求（未使用）；输出为 409 业务冲突，测试不自动重试。
        StubProtocol.handler = { _ in (409, Data(#"{"error":"账户余额不足"}"#.utf8)) }
        do { try await api.mutate("/finance/transactions"); check(false, "409 应抛错") }
        catch let error as APIError { check(error.status == 409 && error.message == "账户余额不足", "保留后端业务错误") }
        // 新协议错误回调输入请求（未使用），返回 message/data 信封；旧 error 字段不得覆盖当前业务错误。
        StubProtocol.handler = { _ in (409, Data(#"{"code":409,"message":"当前业务错误","data":null,"error":"旧错误"}"#.utf8)) }
        do { try await api.mutate("/finance/transactions"); check(false, "新协议冲突应抛错") }
        catch let error as APIError { check(error.status == 409 && error.message == "当前业务错误", "优先使用当前协议 message") }
        var expired = false
        // 会话回调：输入无；输出无；记录已触发过期处理。
        api.onUnauthorized = { expired = true }
        StubProtocol.handler = { _ in (401, Data(#"{"error":"登录过期"}"#.utf8)) }
        do { let _: Profile = try await api.request("/users/me"); check(false, "401 应抛错") } catch { check(expired, "401 通知清理会话") }
        let encoded = try JSONEncoder().encode(ChatMessage(role: "user", content: "你好"))
        let message = try JSONSerialization.jsonObject(with: encoded) as! [String: String]
        check(message.count == 2 && message["id"] == nil, "聊天请求不包含 UI 标识")
        // HealthKit 无样本不应中断其他指标；真实读取故障仍必须阻止整批上传。
        let noData = NSError(domain: HKErrorDomain, code: HKError.Code.errorNoData.rawValue)
        check(try HealthReader.queryValue(nil, error: noData) == nil, "健康无样本错误转换为缺失")
        check(try HealthReader.queryValue(0, error: nil) == 0, "健康零值不会丢失")
        let locked = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        do { _ = try HealthReader.queryValue(nil, error: locked); check(false, "锁屏错误应保留") }
        catch { check((error as NSError).code == locked.code, "真实健康读取失败不会被吞掉") }
        let now = ISO8601DateFormatter().date(from: "2026-03-09T16:00:00Z")!
        let intervals = HealthReader.intervals(now: now, timezone: TimeZone(identifier: "America/New_York")!)
        check(intervals.count == 30 && intervals[0].end == now && intervals[0].start < now, "同步范围包含今天且截至当前时刻")
        check(intervals[1].duration == 23 * 3600 && intervals[1].end == intervals[0].start, "健康日期范围正确处理夏令时")
        var day = HealthDay(date: "2026-09-27", timezone: "Asia/Shanghai")
        check(!day.hasData, "全空健康日不会伪装成有效数据")
        // 空数据测试回调：输入请求，返回无；触发即失败，保证授权不足时不会用空快照覆盖服务器。
        StubProtocol.handler = { _ in preconditionFailure("全空健康数据不得上传") }
        do { _ = try await api.uploadHealth([day]); check(false, "空批次应被拒绝") }
        catch { check(true, "全空健康数据阻止上传") }
        day.steps = 0
        check(day.hasData, "零步数属于有效健康数据")
        // 同步契约回调：输入请求，返回带确认条数的响应；验证真实端点、认证、日期及零值传输。
        StubProtocol.handler = { request in
            let payload = try body(request)
            let days = payload["days"] as! [[String: Any]]
            precondition(request.url?.path == "/api/health-management/sync" && request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            precondition(days.count == 1 && days[0]["steps"] as? Double == 0 && days[0]["date"] as? String == "2026-09-27")
            return (200, Data(#"{"data":{"synced":1}}"#.utf8))
        }
        let synced = try await api.uploadHealth([day])
        check(synced == 1, "健康上传验证服务端回执")
        // 错误回执回调：输入请求（未使用），返回错误条数；不允许宣称同步成功。
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"synced":0}}"#.utf8)) }
        do { _ = try await api.uploadHealth([day]); check(false, "错误回执必须拒绝") }
        catch { check(true, "同步回执不完整时不报成功") }
        // 解码后端真实字段形状；可选指标与更新时间不阻止读取健康记录。
        let health = try JSONDecoder().decode(HealthOverview.self, from: Data(#"{"days":[{"id":1,"date":"2026-09-27","timezone":"Asia/Shanghai","steps":10,"weight":null,"updated_at":"2026-09-27T12:00:00+08:00"}],"reports":[]}"#.utf8))
        check(health.days[0].steps == 10 && health.days[0].updated_at != nil, "健康记录及服务器接收时间正确解码")
        // 餐食视觉契约回调：输入待外发请求，返回虚构非食物结果；验证独立端点、配置版本和110秒超时，不发送真实图片。
        StubProtocol.handler = { request in
            let payload = try body(request)
            precondition(request.url?.path == "/api/health-management/meal-analysis" && request.httpMethod == "POST")
            precondition(request.timeoutInterval == 110 && payload["consent"] as? Bool == true)
            precondition(payload["config_version"] as? String == "2026-10-17T12:00:00Z")
            precondition(payload["image"] as? String == "data:image/jpeg;base64,fixture")
            return (200, Data(#"{"data":{"recognized":false,"items":[],"note":"非食物"}}"#.utf8))
        }
        let mealAnalysis: MealAnalysisResult = try await api.request("/health-management/meal-analysis", method: "POST", body: ["config_id": 1, "config_version": "2026-10-17T12:00:00Z", "consent": true, "image": "data:image/jpeg;base64,fixture"])
        check(mealAnalysis.valid && !mealAnalysis.recognized, "饮食视觉请求与后端契约一致")
        // 日期查询回调：输入GET请求，返回未设目标的空日记；不把缺失目标当零。
        StubProtocol.handler = { request in
            precondition(request.httpMethod == "GET" && request.url?.path == "/api/health-management/nutrition")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "2026-10-17")
            return (200, Data(#"{"data":{"daily_goal":null,"meals":[]}}"#.utf8))
        }
        let nutrition: NutritionOverview = try await api.request("/health-management/nutrition", query: [URLQueryItem(name: "date", value: "2026-10-17")])
        check(nutrition.daily_goal == nil && nutrition.meals.isEmpty, "饮食查询保留缺失目标和空记录")
        try await FinanceOfflineTests.run()
        try ScreenshotBookkeepingTests.run()
        try await ScreenshotBookkeepingTests.network()
        print("\(count) tests passed")
    }
}
