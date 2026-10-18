import Foundation

/// 分类金额保持账本净额；仅有效正值参与占比，负值代表该分类退款抵扣后的净退款。
nonisolated struct FinanceAnalysisCategory: Identifiable {
    let id: Int
    let name: String
    let amount: Decimal?
    /// 正值分类之和中的比例，单位为百分数；负值、零值或分类金额不完整时为 nil。
    let share: Decimal?
}

/// 统一总览返回的月度净收支，不按已加载流水补算，也不把缺失月份补零。
nonisolated struct FinanceAnalysisMonth: Identifiable {
    let month: String
    let income: Decimal?
    let expense: Decimal?
    let balance: Decimal?
    /// 提供月份稳定标识；参数：无；返回值：原始 yyyy-MM 月份。
    var id: String { month }
}

/// 由真实汇总生成的确定性说明，不提供投资建议或未完成月份的异常比较。
nonisolated struct FinanceAnalysisInsight: Identifiable {
    let id: String
    let title: String
    let detail: String
}

/// 供 UI 使用的只读结果；金额和比率缺失均保持 nil，不等同于零。
nonisolated struct FinanceAnalysisReport {
    let income: Decimal?
    let expense: Decimal?
    let balance: Decimal?
    let savingsRate: Decimal?
    let expenseToIncome: Decimal?
    let assets: Decimal?
    let liabilities: Decimal?
    let netWorth: Decimal?
    let debtRatio: Decimal?
    let categories: [FinanceAnalysisCategory]
    let months: [FinanceAnalysisMonth]
    let insights: [FinanceAnalysisInsight]
}

/// 纯 Foundation 财务分析；只接受完整总览，禁止从分页流水推算全量指标。
nonisolated enum FinanceAnalysis {
    /// 严格解析统计字段；参数：raw 为不带币种或百分号的十进制字符串，可缺失；返回值：有效有限 Decimal，缺值、杂字及非数字返回 nil；无副作用。
    static func decimal(_ raw: String?) -> Decimal? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 40,
              text.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// 计算百分数；参数：numerator 为有符号分子，denominator 必须为正数，均可缺失；返回值：未截断、未限制到 100 的百分数，分母非正或运算无效为 nil；无副作用。
    static func percentage(_ numerator: Decimal?, of denominator: Decimal?) -> Decimal? {
        guard let numerator, let denominator, !numerator.isNaN, !denominator.isNaN, denominator > 0 else { return nil }
        let value = numerator / denominator * 100
        return value.isNaN ? nil : value
    }

    /// 格式化人民币金额；参数：value 为可缺失金额；返回值：保留符号和两位小数的人民币金额，未知显示“—”；无副作用。
    static func money(_ value: Decimal?) -> String {
        guard let value, !value.isNaN else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    /// 格式化已计算的百分数；参数：value 的单位是百分数而非 0 到 1 的比例；返回值：至多一位小数的百分比，未知显示“—”；无副作用。
    static func percent(_ value: Decimal?) -> String {
        guard let value, !value.isNaN else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        guard let text = formatter.string(from: NSDecimalNumber(decimal: value)) else { return "—" }
        return text + "%"
    }

    /// 生成财务分析；参数：overview 为 /finance/overview 的完整统计，可为 nil；返回值：可展示的净额、有效比例、最近至多六个有效月份和证据明确的洞察；无网络或账本写入。
    static func report(_ overview: FinanceOverview?) -> FinanceAnalysisReport {
        let income = decimal(overview?.monthIncome)
        let expense = decimal(overview?.monthExpense)
        let balance = decimal(overview?.monthBalance)
        let assets = decimal(overview?.totalAssets)
        let liabilities = decimal(overview?.totalLiabilities)
        let netWorth = decimal(overview?.netWorth)
        // 本机总览可能不提供可选比率：从完整总览金额计算，不把 nil 比率误读为零。
        // 净退款不是负的消费占比，也不据此宣称储蓄率超过 100%；负结余则保留真实负储蓄率。
        let ordinaryExpense = expense.map { $0 >= 0 } ?? false
        let savingsRate = ordinaryExpense ? percentage(balance, of: income) : nil
        let expenseToIncome = ordinaryExpense ? percentage(expense, of: income) : nil
        let debtRatio = liabilities.flatMap { $0 >= 0 ? percentage($0, of: assets) : nil }
        let categories = categoryBreakdown(overview?.expenseCategories ?? [])
        let months = recentMonths(overview?.cashFlow ?? [])
        let observations = insights(income: income, expense: expense, balance: balance, expenseRatio: expenseToIncome,
                                    assets: assets, liabilities: liabilities, debtRatio: debtRatio, categories: categories)
        return FinanceAnalysisReport(income: income, expense: expense, balance: balance, savingsRate: savingsRate,
                                     expenseToIncome: expenseToIncome, assets: assets, liabilities: liabilities,
                                     netWorth: netWorth, debtRatio: debtRatio, categories: categories, months: months, insights: observations)
    }

    /// 解析分类与占比；参数：metrics 为完整的当月分类净额，允许退款负值和缺失金额；返回值：保持原顺序及名称的分类，比例分母仅包含正值；任何金额缺失时不生成比例，避免伪造完整分布。
    static func categoryBreakdown(_ metrics: [FinanceMetric]) -> [FinanceAnalysisCategory] {
        // 映射回调接收分类、返回可缺失 Decimal；无效数据不能静默变成零。
        let amounts = metrics.map { decimal($0.amount) }
        let complete = amounts.allSatisfy { $0 != nil }
        let positiveTotal = amounts.compactMap { $0 }.filter { $0 > 0 }.reduce(Decimal.zero, +)
        // 枚举回调接收原索引及分类、返回稳定行；负值保留金额但绝不参与饼图或正值分母。
        return metrics.enumerated().map { index, metric in
            let amount = amounts[index]
            let share = complete && (amount.map { $0 > 0 } ?? false) ? percentage(amount, of: positiveTotal) : nil
            return FinanceAnalysisCategory(id: index, name: metric.name, amount: amount, share: share)
        }
    }

    /// 读取最近六个有效月份；参数：flows 为总览月度序列，可乱序或缺月；返回值：按年月升序排列、金额缺值保持 nil 的月度值；重复月份全部排除，避免猜测哪一条有效，不补零或外推。
    static func recentMonths(_ flows: [CashFlow]) -> [FinanceAnalysisMonth] {
        // 过滤回调接收月度记录、返回月份键是否有效；年份与月份均严格匹配原始接口格式。
        let valid = flows.filter { $0.month.range(of: #"^[0-9]{4}-(?:0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
        let grouped = Dictionary(grouping: valid, by: \.month)
        return grouped.keys.sorted().filter { grouped[$0]?.count == 1 }.suffix(6).compactMap { month in
            guard let point = grouped[month]?.first else { return nil }
            return FinanceAnalysisMonth(month: month, income: decimal(point.income), expense: decimal(point.expense), balance: decimal(point.net))
        }
    }

    /// 生成不依赖比较期的洞察；参数：income/expense/balance 为当月净收支，expenseRatio 为非退款月份的支出收入比，assets/liabilities/debtRatio 为当前资产负债，categories 为完整分类计算结果；返回值：可核对金额与比例的说明及结余建议，不评价同比、环比或投资回报。
    private static func insights(income: Decimal?, expense: Decimal?, balance: Decimal?, expenseRatio: Decimal?,
                                 assets: Decimal?, liabilities: Decimal?, debtRatio: Decimal?, categories: [FinanceAnalysisCategory]) -> [FinanceAnalysisInsight] {
        var result: [FinanceAnalysisInsight] = []
        if let income, let expense {
            if expense < 0 {
                result.append(.init(id: "cashflow", title: "本月为净退款", detail: "退款抵扣超过支出，净支出为 \(money(expense))；不评价支出占比或储蓄率。"))
            } else if income <= 0 {
                result.append(.init(id: "cashflow", title: "暂无正收入基数", detail: "本月收入为 \(money(income))，不计算支出收入比或储蓄率。先核对收入记录是否齐全。"))
            } else if let expenseRatio {
                result.append(.init(id: "cashflow", title: "支出占收入 \(percent(expenseRatio))", detail: "本月已记录收入 \(money(income))，净支出 \(money(expense))。"))
            }
        } else {
            result.append(.init(id: "cashflow", title: "收支数据不足", detail: "暂无完整的本月收支金额，暂不计算收入相关比例。"))
        }
        // 最大分类只比较正净额；分母不是可能被退款压低或转负的月净支出。
        if let largest = categories.filter({ ($0.amount ?? 0) > 0 }).max(by: { ($0.amount ?? 0) < ($1.amount ?? 0) }), let share = largest.share {
            let refundNote = categories.contains { ($0.amount ?? 0) < 0 } ? "退款负值未纳入分母。" : ""
            result.append(.init(id: "category", title: "最大正值支出分类：\(largest.name)", detail: "\(money(largest.amount))，占正值分类合计的 \(percent(share))。\(refundNote)可优先核对这一类的必要支出。"))
        }
        if let liabilities, liabilities >= 0 {
            if liabilities == 0 {
                result.append(.init(id: "debt", title: "计入净资产的账户暂无负债", detail: "当前总览负债为 \(money(liabilities))。"))
            } else if let debtRatio {
                result.append(.init(id: "debt", title: "资产负债率 \(percent(debtRatio))", detail: "当前负债 \(money(liabilities))，资产 \(money(assets))。安排收支时先预留已知还款资金。"))
            } else {
                result.append(.init(id: "debt", title: "有负债，暂无有效资产基数", detail: "当前负债 \(money(liabilities))；资产非正或缺失，不计算资产负债率。请核对账户余额和还款安排。"))
            }
        }
        if let income, let expense, let balance, income >= 0, expense >= 0 {
            if income == 0 && expense == 0 && balance == 0 {
                result.append(.init(id: "balance", title: "暂不评价结余", detail: "本月净收支均为零，请先核对记录是否齐全。"))
            } else if balance < 0 {
                result.append(.init(id: "balance", title: "本月暂为负结余", detail: "已记录结余 \(money(balance))。可先核对大额支出，并为剩余月份的必要开销预留资金。"))
            } else {
                result.append(.init(id: "balance", title: "按当前结余安排剩余开销", detail: "已记录结余 \(money(balance))。先预留本月尚未支付的必要开销和已知还款，不将暂时结余视为整月结果。"))
            }
        }
        return result
    }
}
