import Foundation

nonisolated struct Envelope<T: Decodable>: Decodable { let data: T }
nonisolated struct Profile: Codable, Identifiable {
    let id: Int
    var account: String
    var nickname: String
    var role: String
    var isAdmin: Bool { role == "admin" || role == "sys_admin" }
}
nonisolated struct Captcha: Decodable { let captcha_id: String; let image: String; let expires_at: Int }
nonisolated struct LoginToken: Decodable { let token: String }
nonisolated struct TaskList: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    var remark: String
    var color: String
    var icon: String
}
nonisolated struct AssistantTask: Codable, Identifiable, Hashable {
    var icon: String? = nil
    let id: Int
    var title: String
    var remark: String
    var listId: Int
    var parentId: Int?
    var taskType: String
    var priority: String
    var startDate: String
    var startTime: String
    var endDate: String
    var endTime: String
    var archived: Bool
    var sortOrder: Int
    var progressTotal: Double
    var progressCompleted: Double
    var progressStep: Double
    var progressUnit: String
}
/// 主任务图标单一目录记录；稳定key跨端保存，未知key只显示回退，不自动重写原值。
nonisolated struct TaskIconOption: Codable, Identifiable {
    let key: String
    let symbol: String
    let label: String
    var id: String { key }
}
nonisolated enum TaskIcons {
    // 与TaskIcons.json单一目录保持同序的完整内置回退；资源损坏或独立测试Bundle缺资源时不丢失选择能力。
    static let fallbackOptions = [
        TaskIconOption(key: "Checklist", symbol: "checklist", label: "任务"),
        TaskIconOption(key: "Layers", symbol: "square.stack.3d.up", label: "分层计划"),
        TaskIconOption(key: "Target", symbol: "target", label: "目标"),
        TaskIconOption(key: "Flag", symbol: "flag", label: "重点"),
        TaskIconOption(key: "Calendar", symbol: "calendar", label: "日程"),
        TaskIconOption(key: "Briefcase", symbol: "briefcase", label: "工作"),
        TaskIconOption(key: "Book", symbol: "book", label: "学习"),
        TaskIconOption(key: "Graduation", symbol: "graduationcap", label: "成长"),
        TaskIconOption(key: "Laptop", symbol: "laptopcomputer", label: "电脑"),
        TaskIconOption(key: "Brush", symbol: "paintbrush", label: "创作"),
        TaskIconOption(key: "Bulb", symbol: "lightbulb", label: "想法"),
        TaskIconOption(key: "Wrench", symbol: "wrench", label: "工具"),
        TaskIconOption(key: "Home", symbol: "house", label: "生活"),
        TaskIconOption(key: "Cart", symbol: "cart", label: "购物"),
        TaskIconOption(key: "Heart", symbol: "heart", label: "健康"),
        TaskIconOption(key: "Leaf", symbol: "leaf", label: "植物"),
        TaskIconOption(key: "Dining", symbol: "fork.knife", label: "饮食"),
        TaskIconOption(key: "Coffee", symbol: "cup.and.saucer", label: "休闲"),
        TaskIconOption(key: "Plane", symbol: "airplane", label: "旅行"),
        TaskIconOption(key: "Bike", symbol: "bicycle", label: "骑行"),
        TaskIconOption(key: "Music", symbol: "music.note", label: "音乐"),
        TaskIconOption(key: "Camera", symbol: "camera", label: "摄影"),
        TaskIconOption(key: "Gift", symbol: "gift", label: "礼物"),
        TaskIconOption(key: "Sparkles", symbol: "sparkles", label: "灵感"),
        TaskIconOption(key: "Rocket", symbol: "paperplane", label: "发布"),
        TaskIconOption(key: "Folder", symbol: "folder", label: "文件夹")
    ]
    /// 读取共享图标目录；参数：无；返回值：内置目录，资源异常回退文件夹；不联网不写入。
    static let options: [TaskIconOption] = {
        guard let url = Bundle.main.url(forResource: "TaskIcons", withExtension: "json"), let data = try? Data(contentsOf: url), let options = try? JSONDecoder().decode([TaskIconOption].self, from: data) else { return fallbackOptions }
        return options
    }()
    /// 查找已保存图标；参数：key为可选稳定键；返回值：已知SF Symbol或文件夹回退；不改变未知原始键。
    static func symbol(_ key: String?) -> String { options.first { $0.key == key }?.symbol ?? "folder" }
}
nonisolated struct TaskProgress {
    var total: Double
    var completed: Double
    var unit: String
    var fraction: Double { total > 0 ? min(1, max(0, completed / total)) : 0 }
}
nonisolated struct FinancialAccount: Codable, Identifiable {
    var cards: [AccountCard]? = nil
    var installmentPendingAmount: String? = nil
    var installmentPendingInterest: String? = nil
    var installmentInterestReserved: String? = nil
    var installmentCredit: String? = nil
    var loanPrincipal: String? = nil
    var loanAnnualRate: String? = nil
    var loanMethod: String? = nil
    var loanPeriods: Int? = nil
    var loanPaidPeriods: Int? = nil
    var loanFirstPaymentDate: String? = nil
    var loanLender: String? = nil
    var loanReceivingAccountId: Int? = nil
    var loanPlan: LoanPlanSummary? = nil
    var loanRevision: Int? = nil
    var loanPlanLocked: Bool? = nil
    var reminderDays: Int? = nil
    var reminderTime: String? = nil
    var creditLimit: String? = nil
    var billingDay: Int? = nil
    var repaymentDay: Int? = nil
    var billDayInclusive: Bool? = nil
    var selectable: Bool? = nil
    let id: Int
    var name: String
    var accountType: String
    var institution: String
    var maskedAccountNumber: String
    var balance: String
    var availableBalance: String
    var currency: String
    var includeInNetWorth: Bool
    var notes: String
}
/// 共用账单账户下的卡片；无独立额度或余额，本机保留完整输入，云端仅保留尾号。
nonisolated struct AccountCard: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var maskedAccountNumber = ""

    /// 校验并规范化卡片；参数：无；返回值：规范化卡片；名称、编号或卡号无效时抛错，不产生外部副作用。
    func normalized() throws -> AccountCard {
        var card = self
        card.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = maskedAccountNumber.filter { !$0.isWhitespace && $0 != "-" }
        guard id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
              !card.name.isEmpty, card.name.utf8.count <= 128,
              number.range(of: #"^([0-9]{4}|[0-9]{12,19}|\*{4}[0-9]{4})$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "AccountCard", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写卡片名称及有效卡号或后四位"])
        }
        // 完整号码必须保留在本机，遮罩仅在展示及同步上传时生成。
        card.maskedAccountNumber = number
        return card
    }
}

nonisolated struct FinanceTransaction: Codable, Identifiable {
    var screenshotJobID: String? = nil
    var screenshotIssue: String? = nil
    var installmentPeriods: Int? = nil
    var installmentName: String? = nil
    /// 支出优惠金额；amount 为扣除优惠后的实付金额。
    var discount: String? = nil
    /// 退款对应的原支出 ID；退款以负支出入账，旧记录为空。
    var refundParentId: Int? = nil
    var rebate: String? = nil
    var rebateAccountId: Int? = nil
    var rebatePending: Bool? = nil
    var rebateParentId: Int? = nil
    var fee: String? = nil
    var installmentParentId: Int? = nil
    var installmentPeriod: Int? = nil
    let id: Int
    let accountId: Int
    let targetAccountId: Int?
    let type: String
    let amount: String
    let categoryId: Int?
    let counterparty: String
    /// 交易当地时分；旧接口和未提供时间的历史记录保持为空。
    var transactionTime: String? = nil
    let transactionDate: String
    let description: String
    let status: String
    let source: String

    /// 展示实际交易日期与时分；参数：无；返回值：yyyy-MM-dd HH:mm，未知时间仅显示日期，不使用创建时间代替。
    var transactionDateTime: String {
        guard let transactionTime, !transactionTime.isEmpty else { return transactionDate }
        return transactionDate + " " + transactionTime
    }
}
nonisolated struct TransactionCategory: Codable, Identifiable { let id: Int; let name: String; let type: String; let color: String; var groupKey: String? = nil; var icon: String? = nil }
nonisolated struct FinanceMetric: Codable { let name: String; let amount: String }
nonisolated struct CashFlow: Codable { let month: String; let income: String; let expense: String; let net: String }
nonisolated struct FinanceOverview: Codable {
    let totalAssets: String
    let totalLiabilities: String
    let netWorth: String
    let monthIncome: String
    let monthExpense: String
    let monthBalance: String
    let savingsRate: String?
    let debtRatio: String?
    let accountCount: Int
    let assetStructure: [FinanceMetric]
    let cashFlow: [CashFlow]
    let expenseCategories: [FinanceMetric]
}
nonisolated struct Provider: Decodable, Identifiable { let id: String; let name: String; let base_url: String }
nonisolated struct AIConfig: Decodable, Identifiable {
    let id: Int
    let name: String
    let model_name: String
    let provider_name: String
    let is_selected: Bool
    var base_url: String = ""
    var owner_type: String = "system"
    var owner_id: Int? = nil
    var visibility: String = "private"
    var updated_at: String = ""
}
nonisolated struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    let role: String
    let content: String
    enum CodingKeys: String, CodingKey { case role, content }
}
nonisolated struct ChatAction: Decodable { let name: String; let success: Bool; let error: String? }
nonisolated struct ChatResult: Decodable { let reply: String; let actions: [ChatAction]; let error: String? }

nonisolated enum Values {
    /// 输出人民币展示文本；参数：raw 为服务端十进制字符串；返回值：本地化金额，格式无效时保留原文；无副作用。
    static func money(_ raw: String) -> String {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return raw }
        return value.formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")))
    }
    /// 校验精确金额；参数：raw 为不含空白的至多两位小数字符串，positive 指定必须大于零；返回值：是否合法；无副作用。
    static func validMoney(_ raw: String, positive: Bool = false) -> Bool {
        guard raw.range(of: #"^-?(0|[1-9][0-9]{0,12})(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw), abs(value) <= Decimal(1_000_000_000_000) else { return false }
        return !positive || value > 0
    }
    /// 判断未完成任务是否逾期；参数：task 为任务，all 为进度汇总节点，now 为可注入当前时刻；返回值：截止已过去且未归档未完成时 true；空截止时分按本地 23:59，非法日期不判逾期。
    static func taskIsOverdue(_ task: AssistantTask, all: [AssistantTask], now: Date = .now) -> Bool {
        guard !task.archived, !task.endDate.isEmpty, progress(task, all: all).fraction < 1 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        guard let deadline = formatter.date(from: task.endDate + " " + (task.endTime.isEmpty ? "23:59" : task.endTime)) else { return false }
        return now > deadline
    }
    /// 编码本地日历日期；参数：date 为日期；返回值：固定公历 yyyy-MM-dd，不使用 UTC 偏移转换；无副作用。
    static func day(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    /// 编码交易当地时分；参数：date 为用户选择的日期时间；返回值：24 小时制 HH:mm，与 day 使用同一本地时区，无副作用。
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    /// 解析 API 日期；参数：raw 为 yyyy-MM-dd；返回值：日期，空值或非法值回退到今天；无副作用。
    static func date(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw) ?? .now
    }
    /// 聚合任务子树（包括归档子任务）；参数：task 为当前节点，all 为全部任务，visited 用于检测环；返回值：叶节点进度汇总；无副作用。
    static func progress(_ task: AssistantTask, all: [AssistantTask], visited: Set<Int> = []) -> TaskProgress {
        let own = TaskProgress(total: task.progressTotal, completed: task.progressCompleted, unit: task.progressUnit)
        guard !visited.contains(task.id) else { return TaskProgress(total: 0, completed: 0, unit: "") }
        let children = all.filter { $0.parentId == task.id }
        if children.isEmpty { return task.taskType == "main" ? TaskProgress(total: 0, completed: 0, unit: "") : own }
        // 聚合回调输入下级节点、输出具体叶数量；空主节点与循环不贡献旧配置，归档叶仍参与汇总。
        let summaries = children.map { progress($0, all: all, visited: visited.union([task.id])) }.filter { $0.total > 0 }
        let unit = summaries.first?.unit ?? ""
        return TaskProgress(total: summaries.reduce(0) { $0 + ($1.total * 100).rounded() } / 100, completed: summaries.reduce(0) { $0 + ($1.completed * 100).rounded() } / 100, unit: !unit.isEmpty && summaries.allSatisfy { $0.unit == unit } ? unit : "")
    }
    /// 合并已确认的服务端任务；参数：saved为写成功实体，snapshot为写前本地树；返回值：新快照，跨清单时仅迁移根旧后代的listId并更新根实体；结果未知不得调用，无外部副作用。
    static func tasksAfterConfirmedWrite(_ saved: AssistantTask, snapshot: [AssistantTask]) -> [AssistantTask] {
        var result = snapshot
        if let original = snapshot.first(where: { $0.id == saved.id }), original.listId != saved.listId {
            var descendants: Set<Int> = [saved.id]
            var changed = true
            while changed {
                changed = false
                for node in snapshot { if let parent = node.parentId, descendants.contains(parent), descendants.insert(node.id).inserted { changed = true } }
            }
            // 仅补确认的服务端整树归属副作用，标题、进度、父关系和归档等字段保留原值，等待完整读取补充其他数据。
            for index in result.indices where descendants.contains(result[index].id) { result[index].listId = saved.listId }
        }
        if let index = result.firstIndex(where: { $0.id == saved.id }) { result[index] = saved } else { result.append(saved) }
        return result
    }
    /// 将可见排序合并为完整ID序列；参数：tasks为全缓存顺序，orderedVisibleIDs为本次同父可见排序且必须唯一存在；返回值：完整序列，仅替换这些节点所在位置，输入非法返回原顺序；无副作用。
    static func taskOrderPreservingHidden(_ tasks: [AssistantTask], orderedVisibleIDs: [Int]) -> [Int] {
        let selected = Set(orderedVisibleIDs)
        let allIDs = Set(tasks.map(\.id))
        guard selected.count == orderedVisibleIDs.count, selected.isSubset(of: allIDs) else { return tasks.map(\.id) }
        var iterator = orderedVisibleIDs.makeIterator()
        // 顺序回调输入全树节点、输出对应ID；隐藏节点占位不变，只按新的可见顺序替换选择槽。
        return tasks.map { selected.contains($0.id) ? iterator.next() ?? $0.id : $0.id }
    }
    /// 构建局部更新字典；参数：original 为编辑前白名单字段，edited 为编辑后同一白名单；返回值：仅变化字段，保留 false、0、空串、null；无副作用。
    static func patch(original: [String: Any], edited: [String: Any]) -> [String: Any] {
        edited.filter { key, value in
            guard let old = original[key] else { return true }
            return !NSDictionary(dictionary: [key: old]).isEqual(to: [key: value])
        }
    }
}

/// 后端统一计算的分期贷款摘要，不将预计本金当作实时账本余额。
nonisolated struct LoanPlanSummary: Codable {
    var paidPrincipal: String? = nil
    var paidInterest: String? = nil
    var paidTotal: String? = nil
    var remainingInterest: String? = nil
    var remainingTotal: String? = nil
    var totalPayment: String? = nil
    var revision: Int? = nil
    var paidPeriods: Int? = nil
    var lastPaymentPeriod: Int? = nil
    var schedule: [LoanPaymentSummary]? = nil
    var remainingPrincipal: String
    var totalInterest: String
    var next: LoanPaymentSummary?
}
nonisolated struct LoanPaymentSummary: Codable {
    var annualRate: String? = nil
    var customPayment: Bool? = nil
    var paymentOverridden: Bool? = nil
    var period: Int
    var date: String
    var principal: String
    var interest: String
    var payment: String
    var remaining: String
}

nonisolated struct FinancePreset: Decodable, Identifiable {
    let id: Int
    let name: String
    let transaction: PresetTransaction
    let frequency: String
    let nextDate: String
    let enabled: Bool
    let lastError: String
}
nonisolated struct PresetTransaction: Decodable {
    var discount: String? = nil
    let accountId: Int
    let targetAccountId: Int?
    let categoryId: Int?
    let type: String
    let amount: String
    let rebate: String?
    let rebateAccountId: Int?
    let rebatePending: Bool?
    let fee: String?
    let counterparty: String
    let description: String
}
