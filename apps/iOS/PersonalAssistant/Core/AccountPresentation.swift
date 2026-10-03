import Foundation

/// 账户页展示计算；金额使用 Decimal，分组与新增账户共用目录，不改变账本数据。
enum AccountPresentation {
    /// 解析用途分组；参数：account 为已有账户；返回值：共享目录分组 ID，未知账户回退资金组。
    static func section(_ account: FinancialAccount) -> String {
        let provider = AccountProvider.resolve(type: account.accountType, institution: account.institution)
        // 目录匹配回调接收产品类型，返回是否为当前产品；借出、借入等类型优先保留其业务分组。
        if let kind = AccountKindCatalog.bundled?.items.first(where: { $0.route.isEmpty && $0.provider.id == provider.id }) { return kind.section }
        if provider.isCredit { return "credit" }
        return account.accountType == "investment" ? "investment" : "funds"
    }

    /// 按转入账户用途命名转账；参数：target 为目标账户，删除或未知账户传 nil；返回值：充值、还款或转账；仅影响展示，不改变账本类型。
    static func transferTitle(target: FinancialAccount?) -> String {
        guard let target else { return "转账" }
        switch section(target) {
        case "prepaid": return "充值"
        case "credit", "payable": return "还款"
        default: return "转账"
        }
    }

    /// 汇总展示余额；参数：accounts 为待汇总账户，可含未计入净资产的账户；返回值：贷款剩余本息取负数，其余取账本余额，损坏金额按零忽略。
    static func total(_ accounts: [FinancialAccount]) -> Decimal {
        // 汇总回调以累计金额和账户为输入，返回加入当前展示余额后的精确金额。
        accounts.reduce(Decimal.zero) { $0 + balance($1) }
    }

    /// 计算列表及资产统计金额；参数：account 为账户；返回值：贷款取未还本息的负数，旧接口回退计划剩余本金，无计划账户取账本余额，无写入。
    static func balance(_ account: FinancialAccount) -> Decimal {
        if account.institution == "贷款", let plan = account.loanPlan {
            return -(Decimal(string: plan.remainingTotal ?? plan.remainingPrincipal) ?? 0)
        }
        return Decimal(string: account.balance) ?? 0
    }

    /// 计算贷款全期本息；参数：account 为贷款账户；返回值：权威总应还，旧接口回退合同本金加总利息，非贷款返回 nil。
    static func loanTotal(_ account: FinancialAccount) -> Decimal? {
        guard account.institution == "贷款", let plan = account.loanPlan else { return nil }
        if let total = plan.totalPayment { return Decimal(string: total) }
        return (Decimal(string: account.loanPrincipal ?? "0") ?? 0) + (Decimal(string: plan.totalInterest) ?? 0)
    }

    /// 格式化展示金额；参数：value 为精确元金额；返回值：人民币字符串，无副作用。
    static func money(_ value: Decimal) -> String { Values.money(NSDecimalNumber(decimal: value).stringValue) }

    /// 计算可用额度；参数：account 为信用账户；返回值：额度加账本余额及剩余分期专项恢复额，扣除预留的未入账利息，旧接口缺少额度字段时返回 nil，不截断超额负数。
    static func availableCredit(_ account: FinancialAccount) -> Decimal? {
        guard let raw = account.creditLimit, let limit = Decimal(string: raw), limit >= 0,
              let balance = Decimal(string: account.balance) else { return nil }
        return limit + balance + (Decimal(string: account.installmentCredit ?? "0") ?? 0) - (Decimal(string: account.installmentInterestReserved ?? "0") ?? 0)
    }

    /// 计算最近账期提示；参数：account 为账户，now 为参考时间，calendar 为当地日历；返回值：最近的还款或出账日提示，未设置时返回空字符串；同日优先还款，短月取月末。
    static func cycleHint(_ account: FinancialAccount, now: Date = .now, calendar: Calendar = .current) -> String {
        if account.institution == "贷款", let plan = account.loanPlan {
            guard let next = plan.next else { return "已还清" }
            // 日期转换回调接收年月日片段，返回可解析的整数；日期异常时保留原文。
            let parts = next.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let due = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: due).day else { return next.date }
            return days == 0 ? "今天还款" : days > 0 ? "\(days)天后还款" : "待还 \(next.date)"
        }
        let today = calendar.startOfDay(for: now)
        guard let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else { return "" }
        var next: (days: Int, action: String)?
        for (day, action) in [(account.repaymentDay ?? 0, "还款"), (account.billingDay ?? 0, "出账")] {
            guard (1...31).contains(day) else { continue }
            for offset in 0...1 {
                guard let start = calendar.date(byAdding: .month, value: offset, to: month),
                      let range = calendar.range(of: .day, in: .month, for: start),
                      let date = calendar.date(byAdding: .day, value: min(day, range.count) - 1, to: start), date >= today,
                      let days = calendar.dateComponents([.day], from: today, to: date).day else { continue }
                if next == nil || days < next!.days { next = (days, action) }
                break
            }
        }
        guard let next else { return "" }
        return next.days == 0 ? "今天\(next.action)" : "\(next.days)天后\(next.action)"
    }
}
