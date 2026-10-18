import Foundation

/// 只在内存中使用的候选字段；不携带原短信，不产生交易或持久化副作用。
nonisolated struct TextBookkeepingDraft {
    var type = ""
    var amount = ""
    var accountID = 0
    var targetAccountID = 0
    var categoryID = 0
    var day = ""
    var time = "00:00"
    var counterparty = ""
    var dateNeedsCorrection = false
    var notices: [String] = []
    var blockingReason: String?
}

/// 本机确定性解析器；仅使用用户主动提供的字符串及已有账户、分类，不访问网络或系统短信。
nonisolated enum TextBookkeepingParser {
    static let maximumLength = 4_000
    private static let number = #"[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?"#
    private static let action = "转账(?:支出|收入)?|转出|转入|汇出|汇入|工资(?:收入|到账)?|消费|支出|支付|付款|扣款|实付|花费|花了|花|收入|入账|存入|收到|收款|到账"

    /// 解析单笔候选；参数：text 为最多 4000 字符原文，accounts/categories 为当前空间真实资料，initialAccountID 仅可显式预选入口账户，now/calendar 用于确定本地相对日期；返回值：可供核对的草稿，歧义或不支持的文本带阻止原因；无副作用，不保存原文。
    static func parse(_ text: String, accounts: [FinancialAccount] = [], categories: [TransactionCategory] = [], initialAccountID: Int? = nil, now: Date = .now, calendar: Calendar = .current) -> TextBookkeepingDraft {
        var draft = TextBookkeepingDraft()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft.blockingReason = "请粘贴交易文本"; return draft
        }
        guard text.count <= maximumLength else {
            draft.blockingReason = "单次最多识别 4000 字符"; return draft
        }
        // 状态、币种及特殊账务先于金额判断；即便同时出现“消费”与数字，也不能误建普通流水。
        if contains(#"验证码|动态密码|校验码|账单|应还|最低还款|还款提醒|待还|到期还款|尚未|未完成|未成功|未支付|未付款|未扣款|未到账|未入账|未能|失败|余额不足|额度不足|待支付|待付款|待确认|待入账|等待支付|等待付款|处理中|申请|取消|关闭|预授权|冻结|预约|预计|将于|累计|合计|汇总|总计|共计|多笔|本月消费|本期消费|上月消费"#, in: text) {
            draft.blockingReason = "这不是已完成的单笔交易，请补充实际交易文本"; return draft
        }
        if contains(#"退款|退货|退回|冲正|撤销"#, in: text) {
            draft.blockingReason = "退款请从原流水办理，不能记为普通收入"; return draft
        }
        if contains(#"还款|还信用卡|偿还|还贷"#, in: text) {
            draft.blockingReason = "还款请使用转账或原还款入口，核对转出和转入账户"; return draft
        }
        if contains(#"(?i)USD|HKD|EUR|JPY|GBP|AUD|CAD|SGD|KRW|CHF|THB|TWD|MOP|NZD|INR|MYR|VND|PHP|IDR|RUB|美元|美金|港币|港元|欧元|日元|日币|英镑|澳元|加元|新加坡元|韩元|瑞郎|泰铢|台币|新台币|澳门元|纽元|新西兰元|卢布|卢比|林吉特|马币|越南盾|印尼盾|比索|外币|美分|[$€£₩₹₽₫₱฿₪₴₺]|円"#, in: text) {
            draft.blockingReason = "暂不支持外币文本，请手动核对币种记账"; return draft
        }
        // 金额必须紧随交易动作及有限连接词；不跨过日期、尾号、余额或任意商户名称搜索数字。
        let pattern = "(" + action + #")(?:成功|了|金额|为|共|[:：\s]|[（(]工资[）)])*(人民币|RMB|CNY|[￥¥])?\s*("# + number + #")(?:\s*(元|圆|人民币|RMB|CNY))?(?![0-9A-Za-z./:年月日万千百十亿角分笔次期天号%％-]|[,，][0-9]|\s*(?:元|圆|人民币|RMB|CNY|万|亿|角|分)|\s*[0-9]+\s*[角分])"#
        let amounts = matches(pattern, in: text)
        let moneyTokens = matches(#"(?:(?:人民币|RMB|CNY|[￥¥])\s*"# + number + #"(?:\s*元)?|"# + number + #"\s*(?:元|圆|人民币))(?![0-9.])"#, in: text)
        // 检查所有显式货币金额；只有余额/额度等非交易数字能排除，手续费、优惠或另一金额必须交回用户拆分。
        let extraMoney = moneyTokens.filter { token in
            if amounts.contains(where: { NSIntersectionRange($0.range, token.range).length > 0 }) { return false }
            let prefix = (text as NSString).substring(to: token.range.location)
            return !contains(#"(?:余额|结余|可用余额|可用额度|剩余额度|信用额度|账户余额)(?:为|是|[:：\s])*$"#, in: prefix)
        }
        if amounts.count > 1 || (!amounts.isEmpty && !extraMoney.isEmpty) || (amounts.isEmpty && extraMoney.count > 1) ||
            (!amounts.isEmpty && contains(#"(?:和|及|、|\+)\s*[￥¥]?\s*[0-9]+(?:\.[0-9]+)?\s*(?:元|圆)?"#, in: (text as NSString).substring(from: NSMaxRange(amounts[0].range)))) {
            draft.blockingReason = "存在多笔或冲突金额，请每次只保留一笔实际交易"; return draft
        }
        if let amount = amounts.first {
            draft.type = transactionType(capture(amount, 1, in: text))
            // 动作后的裸数字仍可能是编号或笔数；缺少币种和金额单位时留空，不把任意相邻数字当成金额。
            if !capture(amount, 2, in: text).isEmpty || !capture(amount, 4, in: text).isEmpty {
                draft.amount = canonicalAmount(capture(amount, 3, in: text)) ?? ""
            }
        } else {
            let kinds = Set(matches(action, in: text).map { transactionType(capture($0, 0, in: text)) })
            if kinds.count == 1 { draft.type = kinds.first ?? "" }
        }
        if draft.amount.isEmpty { draft.notices.append("未识别到有效交易金额，请补充") }
        if draft.type.isEmpty { draft.notices.append("请选择交易类型") }
        readDate(text, now: now, calendar: calendar, into: &draft)
        let available = accounts.filter { $0.selectable != false && $0.currency == "CNY" }
        if draft.type == "transfer" {
            // 转账按明确方向分别匹配；没有方向时不把收到款的账户猜成转出账户。
            let source = firstCapture(#"(?:从|由)([^，。；;\n]+?)(?:向|到|转账|转出|汇出)"#, in: text)
                ?? firstCapture(#"([^，。；;\n]+?)(?:转出|汇出)"#, in: text)
            let target = firstCapture(#"(?:(?<!收)到(?!账)|至|向)([^，。；;\n]+)"#, in: text)
            if let source { draft.accountID = matchAccount(in: source, accounts: accounts) }
            if let target { draft.targetAccountID = matchAccount(in: target, accounts: accounts) }
            if source == nil && !hasAccountEvidence(text, accounts: accounts) {
                draft.accountID = available.first(where: { $0.id == initialAccountID })?.id ?? 0
            }
            draft.notices.append("请核对转出和转入账户")
        } else {
            // 收款商户与付款人的名称/尾号属于对手方，不能用于预选本方扣款或入账账户。
            let ownAccountText = accountEvidenceText(text, type: draft.type)
            draft.accountID = matchAccount(in: ownAccountText, accounts: accounts)
            if draft.accountID == 0 && !hasAccountEvidence(ownAccountText, accounts: accounts) {
                draft.accountID = available.first(where: { $0.id == initialAccountID })?.id ?? 0
            }
        }
        if draft.accountID == 0 { draft.notices.append("请选择账户") }
        draft.categoryID = suggestedCategory(in: text, type: draft.type, categories: categories)
        // 只提取明确字段标签，不把短信全文、卡号、余额或验证码当作交易对象/备注。
        if let merchant = firstCapture(#"(?:商户|交易对象|收款方)[:：]\s*([^，,。；;\n]{1,64})"#, in: text),
           !contains(#"[0-9]{4}|余额|尾号|账户|账号|人民币|[￥¥]"#, in: merchant) {
            draft.counterparty = merchant.trimmingCharacters(in: .whitespaces)
        }
        return draft
    }

    /// 规范化正人民币金额；参数：raw 为数字及可选规范千分位、小数，不能含币种或空白；返回值：不超过账本 1 万亿元且至多两位小数的固定两位金额，非法为 nil；不四舍五入或截断。
    static func canonicalAmount(_ raw: String) -> String? {
        guard contains(#"^\+?(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#, in: raw) else { return nil }
        let clean = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "+", with: "")
        guard let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), value > 0, value <= Decimal(1_000_000_000_000) else { return nil }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: 2 - fraction.count)
    }

    /// 排除对手方字段中的账户证据；参数：text 为原文，type 为收支类型；返回值：仅供本方账户匹配的文本，方向不明时保守移除双方字段；不改变候选交易对象或原文。
    private static func accountEvidenceText(_ text: String, type: String) -> String {
        let counterparty = type == "income" ? "付款方|付款人|付款账户|付款账号|汇款人|汇款账户|来自" :
            type == "expense" ? "收款方|收款人|收款账户|收款账号|收款商户|付给|支付给|向|给" :
            "付款方|付款人|付款账户|付款账号|收款方|收款人|收款账户|收款账号|汇款人|来自|付给|支付给|向|给"
        let pattern = "(?:商户|商家|交易对象|对方(?:账户|账号)?|" + counterparty + #")[：:\s]*[^，,。；;\n]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    /// 唯一匹配文本明确的尾号或完整账户名；参数：text 为本方账户证据或明确方向片段（调用方先排除对手方字段），accounts 为当前空间账户；返回值：唯一可用人民币账户 ID，否则 0；未知、重复或互相冲突的证据不猜选。
    static func matchAccount(in text: String, accounts: [FinancialAccount]) -> Int {
        let available = accounts.filter { $0.selectable != false && $0.currency == "CNY" }
        let tails = tailNumbers(in: text)
        let names = accounts.filter { !$0.name.isEmpty && text.contains($0.name) }
        var evidence: [Int] = []
        for tail in tails {
            // 匹配回调接收账户、返回是否至少一张已有卡具有明确尾号；同账户多卡只算一次。
            let candidates = available.filter { account in
                let numbers = account.cards.map { $0.map(\.maskedAccountNumber) } ?? [account.maskedAccountNumber]
                return numbers.contains { $0.filter { !$0.isWhitespace && $0 != "-" }.hasSuffix(tail) }
            }
            guard candidates.count == 1 else { return 0 }
            evidence.append(candidates[0].id)
        }
        if !names.isEmpty {
            guard names.count == 1, available.contains(where: { $0.id == names[0].id }) else { return 0 }
            evidence.append(names[0].id)
        }
        // 识别到尾号提示但格式错误时也禁止退回名称或入口账户。
        if contains("尾号|尾数|末四位|后四位", in: text) && tails.isEmpty { return 0 }
        guard Set(evidence).count == 1 else { return 0 }
        return evidence.first ?? 0
    }

    /// 从已有同类型分类中提出唯一建议；参数：text 为用户原文，type 为 expense/income/transfer，categories 为真实分类；返回值：唯一匹配 ID 或 0，不生成分类，转账不建议分类。
    static func suggestedCategory(in text: String, type: String, categories: [TransactionCategory]) -> Int {
        guard ["expense", "income"].contains(type) else { return 0 }
        let available = categories.filter { !$0.deleted && $0.type == type }
        let explicit = available.filter { !$0.name.isEmpty && text.contains($0.name) }
        if !explicit.isEmpty { return explicit.count == 1 ? explicit[0].id : 0 }
        let names: [String]
        if type == "expense" && contains("早餐|午餐|晚餐|吃饭|外卖", in: text) { names = ["餐饮", "餐饮美食", "三餐"] }
        else if type == "income" && contains("工资|薪资|薪水", in: text) { names = ["工资", "薪资", "工资薪资"] }
        else { return 0 }
        let candidates = available.filter { names.contains($0.name) }
        return candidates.count == 1 ? candidates[0].id : 0
    }

    /// 严格生成本地公历时刻；参数：day 为 yyyy-MM-dd、time 为 HH:mm、timeZone 为用户当前时区；返回值：格式与日历均有效的日期或 nil，不修正非法日期。
    static func date(day: String, time: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let raw = day + " " + time
        guard let result = formatter.date(from: raw), formatter.string(from: result) == raw else { return nil }
        return result
    }

    /// 提取明确卡尾号；参数：text 为用户文本；返回值：去重后的四位尾号，任意日期、验证码和裸数字不参与；无副作用。
    private static func tailNumbers(in text: String) -> [String] {
        let pattern = #"(?:尾号|尾数|末四位|后四位)(?:为|是|[:：\s])*([0-9]{4})(?![0-9])|(?:卡|账户|账号)[（(]([0-9]{4})[）)]|[*＊]{2,}\s*([0-9]{4})(?![0-9])"#
        var result: [String] = []
        for match in matches(pattern, in: text) {
            for index in 1...3 {
                let tail = capture(match, index, in: text)
                if !tail.isEmpty && !result.contains(tail) { result.append(tail) }
            }
        }
        return result
    }

    /// 检查是否已给出账户证据；参数：text 为原文，accounts 为当前空间可用账户；返回值：有明确尾号提示或完整账户名时 true，供禁止冲突时回退预选；无副作用。
    private static func hasAccountEvidence(_ text: String, accounts: [FinancialAccount]) -> Bool {
        contains(#"尾号|尾数|末四位|后四位|[*＊]{2,}\s*[0-9]|(?:卡|账户|账号)[（(][0-9]"#, in: text) ||
            accounts.contains { !$0.name.isEmpty && text.contains($0.name) }
    }

    /// 将明确动作映射至账本类型；参数：action 为已识别动作；返回值：expense/income/transfer，无法映射为空；无副作用。
    private static func transactionType(_ action: String) -> String {
        if contains("转账|转出|转入|汇出|汇入", in: action) { return "transfer" }
        if contains("收入|工资|入账|存入|收到|收款|到账", in: action) { return "income" }
        return action.isEmpty ? "" : "expense"
    }

    /// 读取日期和时分并保留缺失/非法状态；参数：text 为原文，now/calendar 为可注入本地时间，draft 为需更新的候选；返回值：无，非法值要求用户重新设置，不自动替换为今天或当前分钟。
    private static func readDate(_ text: String, now: Date, calendar: Calendar, into draft: inout TextBookkeepingDraft) {
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = calendar.timeZone
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = gregorian; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let full = matches(#"(?<![0-9])([0-9]{4})[-/.年]([0-9]{1,2})[-/.月]([0-9]{1,2})日?(?![0-9])"#, in: text)
        var days = full.map { match in
            String(format: "%04d-%02d-%02d", Int(capture(match, 1, in: text)) ?? 0, Int(capture(match, 2, in: text)) ?? 0, Int(capture(match, 3, in: text)) ?? 0)
        }
        if full.isEmpty {
            let short = matches(#"(?<![0-9/-])([0-9]{1,2})(?:月|/|-)([0-9]{1,2})日?(?![0-9/-])"#, in: text)
            if !short.isEmpty {
                days = short.map { String(format: "%04d-%02d-%02d", gregorian.component(.year, from: now), Int(capture($0, 1, in: text)) ?? 0, Int(capture($0, 2, in: text)) ?? 0) }
                draft.notices.append("日期未含年份，暂用今年")
            }
        }
        let relatives = matches("大前天|前天|昨天|今天|明天|后天", in: text)
        for match in relatives {
            let word = capture(match, 0, in: text)
            let offset = ["大前天": -3, "前天": -2, "昨天": -1, "今天": 0, "明天": 1, "后天": 2][word] ?? 0
            if let day = gregorian.date(byAdding: .day, value: offset, to: now) { days.append(formatter.string(from: day)) }
        }
        if Set(days).count > 1 {
            draft.dateNeedsCorrection = true; draft.notices.append("存在多个日期，请重新设置")
        } else if let day = days.first {
            draft.day = day
        } else if contains(#"[0-9]{4}[-/.年]|[0-9]{1,2}月|(?<![0-9])[0-9]{1,2}(?:日|/|-)|日期[:：]|去年|明年|上周|下周|上个月|下个月|上月|下月|星期|周[一二三四五六日天]"#, in: text) {
            draft.dateNeedsCorrection = true; draft.notices.append("日期不完整，请重新设置")
        } else {
            draft.day = formatter.string(from: now); draft.notices.append("未提供日期，暂用今天")
        }
        let times = matches(#"(?<![0-9])([0-9]{1,2})[:：]([0-9]{1,2})(?:[:：]([0-9]{1,2}))?(?![0-9])"#, in: text)
        var values: [String] = []
        for match in times {
            let seconds = capture(match, 3, in: text)
            if !seconds.isEmpty && !(0...59).contains(Int(seconds) ?? -1) { draft.dateNeedsCorrection = true }
            var hour = Int(capture(match, 1, in: text)) ?? 99
            // 冒号时分同样尊重明确的上午/下午标记，避免“下午3:30”被误作凌晨。
            let prefix = (text as NSString).substring(to: match.range.location)
            let period = firstCapture(#"(凌晨|早上|上午|中午|下午|晚上)\s*$"#, in: prefix) ?? ""
            if !period.isEmpty && !(1...12).contains(hour) { draft.dateNeedsCorrection = true }
            if ["下午", "晚上", "中午"].contains(period) && hour < 12 { hour += 12 }
            if ["凌晨", "上午", "早上"].contains(period) && hour == 12 { hour = 0 }
            values.append(String(format: "%02d:%02d", hour, Int(capture(match, 2, in: text)) ?? 99))
        }
        let chineseTimes = matches(#"(凌晨|早上|上午|中午|下午|晚上)?\s*([0-9]{1,2})(?:点|时)(?:([0-9]{1,2})分?|(半))?"#, in: text)
        for match in chineseTimes {
            let period = capture(match, 1, in: text)
            var hour = Int(capture(match, 2, in: text)) ?? 99
            let minute = capture(match, 4, in: text) == "半" ? 30 : Int(capture(match, 3, in: text)) ?? 0
            if !period.isEmpty && !(1...12).contains(hour) { draft.dateNeedsCorrection = true }
            if ["下午", "晚上", "中午"].contains(period) && hour < 12 { hour += 12 }
            if ["凌晨", "上午", "早上"].contains(period) && hour == 12 { hour = 0 }
            values.append(String(format: "%02d:%02d", hour, minute))
        }
        if (times.isEmpty && contains(#"(?<![0-9])[0-9]{1,2}[:：]|(?:时间|时分)[:：]"#, in: text)) ||
            contains(#"[0-9]{1,2}[点时](?:[一二三四五六七八九十]+(?:刻|分))"#, in: text) {
            draft.dateNeedsCorrection = true
        }
        if Set(values).count > 1 { draft.dateNeedsCorrection = true }
        if let time = values.first { draft.time = time }
        else { draft.notices.append("未提供时分，暂用 00:00") }
        if date(day: draft.day, time: draft.time, timeZone: calendar.timeZone) == nil { draft.dateNeedsCorrection = true }
        if draft.dateNeedsCorrection { draft.notices.append("请设置有效日期和时间") }
    }

    /// 执行无状态正则匹配；参数：pattern 为内部固定正则，text 为用户文本；返回值：按原文顺序排列的匹配，无匹配或规则无效返回空；无副作用。
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// 判断内部规则是否命中；参数：pattern 为固定正则，text 为待查文本；返回值：至少一处命中为 true；无副作用。
    private static func contains(_ pattern: String, in text: String) -> Bool { !matches(pattern, in: text).isEmpty }

    /// 安全读取捕获组；参数：match 为文本内匹配、index 为捕获组序号、text 为原字符串；返回值：组字符串，组不存在时为空；无副作用。
    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    /// 读取首个捕获组；参数：pattern 为固定正则且至少包含一组、text 为用户文本；返回值：首组非空字符串或 nil；仅用于显式字段和方向，不推断缺失资料。
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let match = matches(pattern, in: text).first else { return nil }
        let value = capture(match, 1, in: text)
        return value.isEmpty ? nil : value
    }
}

/// 单个确认页面的幂等提交状态；只在内存保留白名单交易字段的指纹，不含原短信。
nonisolated struct TextBookkeepingSubmission {
    private(set) var requestID = UUID().uuidString
    private var requestIDs: [Data: String] = [:]

    /// 为白名单交易字段提供稳定请求 ID；参数：fields 为不含 requestId 的已确认 JSON 字段；返回值：加入 requestId 的请求体，相同字段失败重试沿用 ID，修改后再改回也复用原 ID；JSON 非法抛错，不写账本。
    mutating func body(for fields: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        if let existing = requestIDs[payload] { requestID = existing }
        else {
            if !requestIDs.isEmpty { requestID = UUID().uuidString }
            requestIDs[payload] = requestID
        }
        var body = fields; body["requestId"] = requestID
        return body
    }
}
