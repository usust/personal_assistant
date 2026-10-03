import Foundation

/// 账户流水的一张月份卡片；信用账户使用账期，无账单日的账户使用自然月。
nonisolated struct AccountTransactionPeriod: Identifiable {
    let id: String
    let title: String
    let start: String
    let end: String
    var rows: [FinanceTransaction]
}

/// 账户月份归类与现金流计算，日期固定按账本 UTC+8 自然日处理。
nonisolated enum AccountTransactionPeriods {
    /// 分组并排序账户流水；参数：rows 为已加载流水，billingDay 为 1…31 的账单日或 nil，inclusive 表示账单日交易计入本期；返回值：月份倒序、组内日期及 ID 倒序的账期，异常日期忽略，无副作用。
    static func groups(_ rows: [FinanceTransaction], billingDay: Int?, inclusive: Bool) -> [AccountTransactionPeriod] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28800)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var groups: [String: AccountTransactionPeriod] = [:]
        for row in rows where row.status != "installment" && row.status != "deleted" && !(row.installmentParentId != nil && row.status == "pending") {
            guard let date = formatter.date(from: row.transactionDate),
                  let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { continue }
            var labelMonth = month
            var start: Date
            var end: Date
            if let billingDay, (1...31).contains(billingDay) {
                // 每个月分别取账单日与月末的较小值，避免二月、31 日和跨年产生漂移。
                var closing = closingDate(month: month, day: billingDay, calendar: calendar)
                let lastIncluded = inclusive ? closing : calendar.date(byAdding: .day, value: -1, to: closing)!
                if date > lastIncluded {
                    labelMonth = calendar.date(byAdding: .month, value: 1, to: month)!
                    closing = closingDate(month: labelMonth, day: billingDay, calendar: calendar)
                }
                let previousMonth = calendar.date(byAdding: .month, value: -1, to: labelMonth)!
                let previousClosing = closingDate(month: previousMonth, day: billingDay, calendar: calendar)
                start = inclusive ? calendar.date(byAdding: .day, value: 1, to: previousClosing)! : previousClosing
                end = inclusive ? closing : calendar.date(byAdding: .day, value: -1, to: closing)!
            } else {
                start = month
                end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: month)!)!
            }
            let id = String(formatter.string(from: labelMonth).prefix(7))
            if groups[id] == nil {
                groups[id] = AccountTransactionPeriod(id: id, title: "\(calendar.component(.year, from: labelMonth))年\(calendar.component(.month, from: labelMonth))月", start: formatter.string(from: start), end: formatter.string(from: end), rows: [])
            }
            groups[id]?.rows.append(row)
        }
        // 映射闭包接收月份 ID，返回流水已排序的卡片；流水比较闭包按日期、ID 倒序。
        return groups.keys.sorted(by: >).map { key in
            var group = groups[key]!
            group.rows.sort { $0.transactionDate == $1.transactionDate ? $0.id > $1.id : $0.transactionDate > $1.transactionDate }
            return group
        }
    }

    /// 获取指定月份的账单日；参数：month 为该月第一天，day 为 1…31，calendar 为账本日历；返回值：短月截到月末的日期，无副作用。
    private static func closingDate(month: Date, day: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: min(day, calendar.range(of: .day, in: .month, for: month)!.count) - 1, to: month)!
    }

    /// 汇总已入账资金流；参数：rows 为待汇总流水，accountID 为固定账户，nil 表示全局；返回值：账户流出流入或全局净支出收入，全局排除内部转账本金但计入手续费，退款抵减支出；不含未入账或作废记录。
    static func flow(_ rows: [FinanceTransaction], accountID: Int?) -> (outflow: Decimal, inflow: Decimal) {
        var outflow = Decimal.zero, inflow = Decimal.zero
        for row in rows where row.status == "posted" {
            let amount = Decimal(string: row.amount) ?? 0
            guard let accountID else {
                // 全局收支不把自己账户间的转账计为收入或支出；退款沿用负支出统计。
                if row.type == "income" { inflow += amount }
                if row.type == "expense" { outflow += amount }
                outflow += Decimal(string: row.fee ?? "0") ?? 0
                continue
            }
            if row.accountId == accountID {
                let delta = (row.type == "income" ? amount : -amount) - (Decimal(string: row.fee ?? "0") ?? 0)
                if delta >= 0 { inflow += delta } else { outflow -= delta }
            }
            if row.targetAccountId == accountID { inflow += amount }
        }
        return (outflow, inflow)
    }
}

/// 财务首页使用的自然月份，日期与后台统一为 UTC+8。
nonisolated struct FinanceMonth: Hashable, Identifiable {
    let year: Int
    let month: Int
    var id: String { String(format: "%04d-%02d", year, month) }
    var title: String { "\(year)年\(month)月" }
    var start: String { id + "-01" }
    /// 获取月末；参数：无；返回值：包含当天的 yyyy-MM-dd，正确处理闰年与大小月。
    var end: String {
        let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let days = Self.calendar.range(of: .day, in: .month, for: date)!.count
        return id + String(format: "-%02d", days)
    }
    /// 生成统一日期日历；参数：无；返回值：UTC+8 公历，不依赖设备所在时区。
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 28800)!
        return value
    }
    /// 从时间取得自然月；参数：date 默认为当前时间；返回值：UTC+8 年月。
    static func current(_ date: Date = .now) -> FinanceMonth {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return FinanceMonth(year: parts.year!, month: parts.month!)
    }
    /// 按月移动；参数：offset 为正负月份数；返回值：范围内的新月份，超出 1900–9999 时保留原值。
    func shifted(_ offset: Int) -> FinanceMonth {
        let index = year * 12 + month - 1 + offset
        guard (1900 * 12..<10000 * 12).contains(index) else { return self }
        return FinanceMonth(year: index / 12, month: index % 12 + 1)
    }
}

nonisolated struct FinanceMonthSummary: Decodable {
    let income: String
    let expense: String
    let balance: String
}
