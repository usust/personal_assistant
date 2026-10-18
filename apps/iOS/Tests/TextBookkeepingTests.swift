import Foundation

@MainActor enum TextBookkeepingTests {
    /// 创建完全虚构的账户；参数：id 为正整数、name 为完整账户名、tail 为虚构卡尾号、selectable 控制能否选择；返回值：人民币账户，不接触用户真实账本。
    static func account(_ id: Int, _ name: String, tail: String = "", selectable: Bool = true) -> FinancialAccount {
        var result = FinancialAccount(id: id, name: name, accountType: "bank", institution: "测试银行", maskedAccountNumber: tail,
                                      balance: "0.00", availableBalance: "0.00", currency: "CNY", includeInNetWorth: true, notes: "")
        result.selectable = selectable
        return result
    }

    /// 执行本机文本解析与幂等请求状态测试；参数：无；返回值：无，断言失败中止、编码失败抛错；不联网、不读取短信或真实账本。
    static func run() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let now = TextBookkeepingParser.date(day: "2026-10-17", time: "17:45", timeZone: zone)!
        let bank = account(1, "工资储蓄卡", tail: "1234")
        let cash = account(2, "现金钱包")
        let categories = [TransactionCategory(id: 1, name: "餐饮", type: "expense", color: "#ff0000"),
                          TransactionCategory(id: 2, name: "工资", type: "income", color: "#00ff00")]
        // 解析辅助闭包输入一段测试文本、返回确定日期和固定选项下的候选；不读写外部资料。
        let parse: (String) -> TextBookkeepingDraft = { text in
            TextBookkeepingParser.parse(text, accounts: [bank, cash], categories: categories, now: now, calendar: calendar)
        }
        let sms = parse("【测试银行】您尾号1234的卡于2026年10月16日12:30消费人民币35.60元，余额9,876.54元。")
        precondition(sms.blockingReason == nil && sms.amount == "35.60" && sms.type == "expense")
        precondition(sms.accountID == bank.id && sms.day == "2026-10-16" && sms.time == "12:30" && !sms.dateNeedsCorrection)
        precondition(sms.counterparty.isEmpty)
        let numbered = parse("您尾号1234账户10月17日08:09支付￥1,234.50元，可用余额12,345.67元")
        precondition(numbered.amount == "1234.50" && numbered.accountID == bank.id && numbered.day == "2026-10-17")
        let income = parse("尾号1234账户收入人民币8,000.00元，余额9,000.00元")
        precondition(income.type == "income" && income.amount == "8000.00" && income.accountID == bank.id)
        let salary = parse("工资收入8000元")
        precondition(salary.type == "income" && salary.amount == "8000.00" && salary.categoryID == 2 && salary.accountID == 0)
        let lunch = parse("昨天午餐花了35元")
        precondition(lunch.type == "expense" && lunch.amount == "35.00" && lunch.day == "2026-10-16" && lunch.categoryID == 1)
        precondition(lunch.time == "00:00" && lunch.notices.contains("未提供时分，暂用 00:00"))
        let today = parse("支付35元")
        precondition(today.day == "2026-10-17" && today.time == "00:00" && today.notices.contains("未提供日期，暂用今天"))
        precondition(today.accountID == 0 && today.counterparty.isEmpty)
        precondition(parse("下午3点午餐花了35元").time == "15:00")
        precondition(parse("下午3点半午餐花了35元").time == "15:30")
        precondition(parse("下午3:30午餐花了35元").time == "15:30")
        precondition(parse("上午12:30消费35元").time == "00:30")
        precondition(parse("下午15:30消费35元").dateNeedsCorrection)
        precondition(parse("商户：午餐店，消费￥35.8，余额100元").counterparty == "午餐店")
        precondition(parse("消费￥35.8").amount == "35.80")
        precondition(parse("收入CNY1000").amount == "1000.00")
        precondition(parse("尾号1234于2026-10-17付款，余额300元").amount.isEmpty)
        precondition(parse("昨天午餐，尾号1234").amount.isEmpty)
        precondition(parse("2026年10月17日12:30尾号1234，余额100元").amount.isEmpty)
        precondition(parse("消费2026年10月17日").amount.isEmpty)
        precondition(parse("消费12:30").amount.isEmpty)
        precondition(parse("消费1234").amount.isEmpty)
        precondition(parse("消费￥1，234.50").amount.isEmpty)
        for input in ["消费0元", "消费-1元", "消费1.001元", "消费1,23元", "消费01元", "消费1000000000001元", "消费1e3元", "消费1万元", "消费35元3角", "消费35 元3角", "消费35元 3角"] {
            precondition(parse(input).amount.isEmpty, input)
        }
        precondition(parse("支出人民币1,000,000,000,000.00元").amount == "1000000000000.00")
        for input in ["消费35元，消费50元", "消费35元，收入50元", "消费35元和50元", "消费35元及50", "消费35元，实际金额50元", "支出35元，实付30元", "转账35元，手续费1元"] {
            precondition(parse(input).blockingReason != nil, input)
        }
        for input in ["消费USD35.00", "消费35美元", "支付港币100元", "支付€35", "消费JPY1000", "消费35元（外币结算）"] {
            precondition(parse(input).blockingReason != nil, input)
        }
        for input in ["支付35元失败", "消费35元尚未完成", "待付款35元", "账单应还350元", "收入验证码123456，有效期5分钟", "消费35元预授权", "转账35元处理中", "消费35元余额不足", "支付35元未扣款", "累计消费350元", "消费350元，合计两笔"] {
            precondition(parse(input).blockingReason != nil, input)
        }
        for input in ["退款收入35元", "消费退款35元", "信用卡还款350元", "还信用卡350元", "已还款350元"] {
            precondition(parse(input).blockingReason != nil, input)
        }
        for input in ["2026-02-30消费35元", "2026年13月1日消费35元", "2月30日消费35元", "2026年2月消费35元", "2026-10-17 25:00消费35元", "昨天和今天消费35元", "2026-10-17 12:60消费35元", "17日消费35元", "上周午餐花了35元", "12:xx消费35元", "下午3点一刻消费35元"] {
            precondition(parse(input).dateNeedsCorrection, input)
        }
        precondition(TextBookkeepingParser.date(day: "2026-02-30", time: "00:00", timeZone: zone) == nil)
        precondition(parse("2024-02-29 00:00消费35元").dateNeedsCorrection == false)
        precondition(parse(String(repeating: "字", count: 4_001)).blockingReason != nil)
        precondition(parse(" \n").blockingReason != nil)
        try accountMatching(bank: bank, cash: cash, now: now, calendar: calendar)
        categoryMatching(categories)
        try submissionIdentity()
        print("Text bookkeeping tests passed")
    }

    /// 验证唯一证据、账户范围及转账方向；参数：bank/cash 为虚构账户、now/calendar 为固定本地时刻；返回值：无，失败中止或抛错；无真实账本写入。
    static func accountMatching(bank: FinancialAccount, cash: FinancialAccount, now: Date, calendar: Calendar) throws {
        let duplicate = account(3, "另一储蓄卡", tail: "1234")
        precondition(TextBookkeepingParser.matchAccount(in: "尾号1234消费35元", accounts: [bank]) == bank.id)
        precondition(TextBookkeepingParser.matchAccount(in: "卡(1234)消费35元", accounts: [bank]) == bank.id)
        precondition(TextBookkeepingParser.matchAccount(in: "卡****1234消费35元", accounts: [bank]) == bank.id)
        precondition(TextBookkeepingParser.matchAccount(in: "尾号12345消费35元", accounts: [bank]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "尾号1234消费35元", accounts: [bank, duplicate]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "尾号9999消费35元", accounts: [bank]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "2026-10-17消费1234元", accounts: [bank]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "工资储蓄卡消费35元", accounts: [bank, cash]) == bank.id)
        precondition(TextBookkeepingParser.matchAccount(in: "工资储蓄卡消费35元", accounts: [bank, account(4, bank.name)]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "现金钱包尾号1234消费35元", accounts: [bank, cash]) == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "尾号1234和尾号9999消费35元", accounts: [bank, cash]) == 0)
        var multiCard = cash
        multiCard.cards = [AccountCard(id: "test-card", name: "附属卡", maskedAccountNumber: "****5678")]
        precondition(TextBookkeepingParser.matchAccount(in: "尾号5678消费35元", accounts: [multiCard]) == cash.id)
        let scoped = TextBookkeepingParser.parse("午餐花了35元", accounts: [bank, cash], initialAccountID: cash.id, now: now, calendar: calendar)
        precondition(scoped.accountID == cash.id)
        let conflict = TextBookkeepingParser.parse("尾号9999消费35元", accounts: [bank, cash], initialAccountID: cash.id, now: now, calendar: calendar)
        precondition(conflict.accountID == 0)
        let disabled = account(5, "停用账户", selectable: false)
        let disabledDraft = TextBookkeepingParser.parse("停用账户消费35元", accounts: [bank, disabled], initialAccountID: bank.id, now: now, calendar: calendar)
        precondition(disabledDraft.accountID == 0)
        precondition(TextBookkeepingParser.matchAccount(in: "停用账户消费35元", accounts: [disabled]) == 0)
        let transfer = TextBookkeepingParser.parse("从工资储蓄卡到现金钱包转账100元", accounts: [bank, cash], now: now, calendar: calendar)
        precondition(transfer.type == "transfer" && transfer.amount == "100.00" && transfer.accountID == bank.id && transfer.targetAccountID == cash.id)
        let unknownDirection = TextBookkeepingParser.parse("尾号1234转账100元", accounts: [bank, cash], now: now, calendar: calendar)
        precondition(unknownDirection.type == "transfer" && unknownDirection.accountID == 0 && unknownDirection.targetAccountID == 0)
        let incoming = TextBookkeepingParser.parse("尾号1234转入100元", accounts: [bank, cash], now: now, calendar: calendar)
        precondition(incoming.type == "transfer" && incoming.accountID == 0)
        let sender = TextBookkeepingParser.parse("收到工资储蓄卡转账100元", accounts: [bank, cash], now: now, calendar: calendar)
        precondition(sender.type == "transfer" && sender.accountID == 0 && sender.targetAccountID == 0)
        let alipay = account(6, "支付宝", tail: "5678")
        let merchant = TextBookkeepingParser.parse("使用银行卡支付35元，收款方：支付宝", accounts: [bank, alipay], now: now, calendar: calendar)
        precondition(merchant.accountID == 0 && merchant.counterparty == "支付宝", "收款商户不能成为本方支出账户")
        let payer = TextBookkeepingParser.parse("收入35元，付款方尾号1234", accounts: [bank, alipay], now: now, calendar: calendar)
        precondition(payer.accountID == 0, "付款人的卡尾号不能成为本方收入账户")
        let ownWithMerchant = TextBookkeepingParser.parse("尾号1234支付35元，收款方：支付宝", accounts: [bank, alipay], now: now, calendar: calendar)
        precondition(ownWithMerchant.accountID == bank.id, "排除对手方后仍能匹配本方明确尾号")
        let directedExpense = TextBookkeepingParser.parse("工资储蓄卡向支付宝支付35元", accounts: [bank, alipay], now: now, calendar: calendar)
        precondition(directedExpense.accountID == bank.id, "支出方向中的收款方不能干扰本方账户")
        let incomingWithPayer = TextBookkeepingParser.parse("尾号5678收入35元，付款方：工资储蓄卡", accounts: [bank, alipay], now: now, calendar: calendar)
        precondition(incomingWithPayer.accountID == alipay.id, "收入仅匹配本方入账账户而非付款方")
    }

    /// 验证分类建议仅复用同类型唯一项；参数：categories 为固定虚构分类；返回值：无，失败中止；不创建或保存任何分类。
    static func categoryMatching(_ categories: [TransactionCategory]) {
        precondition(TextBookkeepingParser.suggestedCategory(in: "昨天午餐花了35元", type: "expense", categories: categories) == 1)
        precondition(TextBookkeepingParser.suggestedCategory(in: "工资收入8000元", type: "income", categories: categories) == 2)
        precondition(TextBookkeepingParser.suggestedCategory(in: "工资收入8000元", type: "expense", categories: categories) == 0)
        precondition(TextBookkeepingParser.suggestedCategory(in: "其他消费35元", type: "expense", categories: categories) == 0)
        let duplicate = categories + [TransactionCategory(id: 9, name: "餐饮", type: "expense", color: "#ff0000")]
        precondition(TextBookkeepingParser.suggestedCategory(in: "餐饮支出35元", type: "expense", categories: duplicate) == 0)
        precondition(TextBookkeepingParser.suggestedCategory(in: "午餐转账35元", type: "transfer", categories: categories) == 0)
    }

    /// 验证失败重试 ID 稳定及字段变更隔离；参数：无；返回值：无，JSON 编码失败抛错、断言失败中止；不调用网络或账本。
    static func submissionIdentity() throws {
        var submission = TextBookkeepingSubmission()
        let fields: [String: Any] = ["type": "expense", "amount": "35.00", "accountId": 1, "transactionDate": "2026-10-17", "transactionTime": "00:00", "counterparty": "", "description": ""]
        let first = try submission.body(for: fields)
        let retry = try submission.body(for: fields)
        precondition(first["requestId"] as? String == retry["requestId"] as? String)
        precondition(first["text"] == nil && first["rawText"] == nil && first["description"] as? String == "")
        var changed = fields; changed["amount"] = "36.00"
        let second = try submission.body(for: changed)
        precondition(first["requestId"] as? String != second["requestId"] as? String)
        let secondRetry = try submission.body(for: changed)
        precondition(second["requestId"] as? String == secondRetry["requestId"] as? String)
        let revertedRetry = try submission.body(for: fields)
        precondition(first["requestId"] as? String == revertedRetry["requestId"] as? String)
    }
}
