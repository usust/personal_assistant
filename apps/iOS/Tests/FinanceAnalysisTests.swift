import Foundation

/// 独立的纯 Foundation 财务分析测试；使用虚构汇总，不读取真实账本、不联网。
enum FinanceAnalysisTests {
    /// 构造虚构完整总览；参数：income/expense/balance 为当月净额，assets/liabilities/netWorth 为资产净额，categories/months 为完整分类及月度序列，savingsRate/debtRatio 为可缺失的接口原比率；返回值：用于验证计算口径的总览，无副作用。
    private static func overview(income: String = "1000.00", expense: String = "400.00", balance: String = "600.00",
                                 assets: String = "10000.00", liabilities: String = "2000.00", netWorth: String = "8000.00",
                                 categories: [FinanceMetric] = [], months: [CashFlow] = [],
                                 savingsRate: String? = nil, debtRatio: String? = nil) -> FinanceOverview {
        FinanceOverview(totalAssets: assets, totalLiabilities: liabilities, netWorth: netWorth,
                        monthIncome: income, monthExpense: expense, monthBalance: balance,
                        savingsRate: savingsRate, debtRatio: debtRatio, accountCount: 2,
                        assetStructure: [], cashFlow: months, expenseCategories: categories)
    }

    /// 执行全部边界测试；参数：无；返回值：无，失败以 precondition 中止进程，不使用可被优化移除的 assert；可由主测试程序直接调用。
    static func run() {
        ordinaryCashFlow()
        zeroAndNegativeIncome()
        refundCategories()
        missingData()
        assetDenominators()
        trendsAndParsing()
        print("Finance analysis tests passed")
    }

    /// 验证正收入、负结余和比例单位；参数：无；返回值：无，失败中止；本机可选比率缺失时按完整总览计算，不截断超过 100 或小于零的有效比例。
    private static func ordinaryCashFlow() {
        let report = FinanceAnalysis.report(overview(categories: [FinanceMetric(name: "餐饮", amount: "250"), FinanceMetric(name: "交通", amount: "150")]))
        precondition(report.income == 1000 && report.expense == 400 && report.balance == 600)
        precondition(report.savingsRate == 60 && report.expenseToIncome == 40 && report.debtRatio == 20)
        precondition(report.categories[0].share == Decimal(string: "62.5"))
        precondition(report.categories[1].share == Decimal(string: "37.5"))
        precondition(report.insights.contains { $0.id == "category" && $0.title.contains("餐饮") && $0.detail.contains("62.5%") })
        let deficit = FinanceAnalysis.report(overview(expense: "1500", balance: "-500"))
        precondition(deficit.savingsRate == -50 && deficit.expenseToIncome == 150)
        precondition(deficit.insights.contains { $0.id == "balance" && $0.title == "本月暂为负结余" })
        // 统计比率始终遵守正分母校验，不因为接口提供占位“0”而把未知基数变成有效比例。
        let optionalRates = FinanceAnalysis.report(overview(income: "0", expense: "100", balance: "-100", assets: "0", savingsRate: "0", debtRatio: "0"))
        precondition(optionalRates.savingsRate == nil && optionalRates.expenseToIncome == nil && optionalRates.debtRatio == nil)
        for insight in report.insights + deficit.insights {
            precondition(!insight.detail.contains("同比") && !insight.detail.contains("环比") && !insight.title.contains("异常"))
            precondition(!insight.detail.contains("投资") && !insight.detail.contains("收益率"))
        }
    }

    /// 验证零收入及负收入不产生除零或伪造比例；参数：无；返回值：无，失败中止，不把零净额认定为已完成整月或无任何流水。
    private static func zeroAndNegativeIncome() {
        let zeroIncome = FinanceAnalysis.report(overview(income: "0", expense: "200", balance: "-200"))
        precondition(zeroIncome.savingsRate == nil && zeroIncome.expenseToIncome == nil)
        precondition(zeroIncome.insights.contains { $0.title == "暂无正收入基数" })
        precondition(zeroIncome.insights.contains { $0.id == "balance" && $0.title == "本月暂为负结余" })
        let negativeIncome = FinanceAnalysis.report(overview(income: "-100", expense: "100", balance: "-200"))
        precondition(negativeIncome.savingsRate == nil && negativeIncome.expenseToIncome == nil)
        let emptyMonth = FinanceAnalysis.report(overview(income: "0", expense: "0", balance: "0", assets: "0", liabilities: "0", netWorth: "0"))
        precondition(emptyMonth.categories.isEmpty && emptyMonth.months.isEmpty)
        precondition(emptyMonth.savingsRate == nil && emptyMonth.expenseToIncome == nil)
        precondition(emptyMonth.insights.contains { $0.id == "balance" && $0.title == "暂不评价结余" })
        precondition(!emptyMonth.insights.contains { $0.title.contains("盈余") || $0.title.contains("正常") })
    }

    /// 验证分类净退款不会变成图表正值或百分比分母；参数：无；返回值：无，失败中止，零值、负值及未知值不伪造占比。
    private static func refundCategories() {
        let categories = [FinanceMetric(name: "餐饮", amount: "250"), FinanceMetric(name: "交通", amount: "150"),
                          FinanceMetric(name: "购物", amount: "-200"), FinanceMetric(name: "其他", amount: "0")]
        let report = FinanceAnalysis.report(overview(expense: "200", balance: "800", categories: categories))
        precondition(report.categories[0].share == Decimal(string: "62.5"), "退款不得将餐饮占比放大为 125%")
        precondition(report.categories[1].share == Decimal(string: "37.5"))
        precondition(report.categories[2].amount == -200 && report.categories[2].share == nil)
        precondition(report.categories[3].amount == 0 && report.categories[3].share == nil)
        precondition(report.insights.contains { $0.id == "category" && $0.detail.contains("退款负值未纳入分母") })

        let netRefund = FinanceAnalysis.report(overview(expense: "-200", balance: "1200", categories: [FinanceMetric(name: "餐饮", amount: "100"), FinanceMetric(name: "购物", amount: "-300")]))
        precondition(netRefund.expense == -200 && netRefund.balance == 1200)
        precondition(netRefund.savingsRate == nil && netRefund.expenseToIncome == nil)
        precondition(netRefund.categories[0].share == 100 && netRefund.categories[1].share == nil)
        precondition(netRefund.insights.contains { $0.title == "本月为净退款" })
        precondition(!netRefund.insights.contains { $0.id == "balance" }, "净退款结余不能被宣称为可储蓄收入")
        let refundOnly = FinanceAnalysis.report(overview(income: "0", expense: "-50", balance: "50", categories: [FinanceMetric(name: "购物", amount: "-50")]))
        precondition(refundOnly.categories.allSatisfy { $0.share == nil })
        precondition(!refundOnly.insights.contains { $0.id == "category" })
        precondition(refundOnly.insights.contains { $0.title == "本月为净退款" })
    }

    /// 验证缺失及无数据状态；参数：无；返回值：无，失败中止；缺值保留 nil，不以默认零推导结余或分布。
    private static func missingData() {
        let absent = FinanceAnalysis.report(nil)
        precondition(absent.income == nil && absent.expense == nil && absent.balance == nil)
        precondition(absent.assets == nil && absent.liabilities == nil && absent.netWorth == nil)
        precondition(absent.savingsRate == nil && absent.expenseToIncome == nil && absent.debtRatio == nil)
        precondition(absent.categories.isEmpty && absent.months.isEmpty)
        precondition(absent.insights.count == 1 && absent.insights[0].title == "收支数据不足")

        let missingIncome = FinanceAnalysis.report(overview(income: ""))
        precondition(missingIncome.income == nil && missingIncome.expenseToIncome == nil && missingIncome.savingsRate == nil)
        let missingBalance = FinanceAnalysis.report(overview(balance: ""))
        precondition(missingBalance.balance == nil && missingBalance.savingsRate == nil && missingBalance.expenseToIncome == 40)
        precondition(!missingBalance.insights.contains { $0.id == "balance" })
        let missingExpense = FinanceAnalysis.report(overview(expense: "NaN"))
        precondition(missingExpense.expense == nil && missingExpense.savingsRate == nil && missingExpense.expenseToIncome == nil)
        let brokenCategories = FinanceAnalysis.report(overview(categories: [FinanceMetric(name: "餐饮", amount: "100"), FinanceMetric(name: "交通", amount: "")]))
        precondition(brokenCategories.categories[0].amount == 100 && brokenCategories.categories[1].amount == nil)
        precondition(brokenCategories.categories.allSatisfy { $0.share == nil })
        precondition(!brokenCategories.insights.contains { $0.id == "category" })
        precondition(FinanceAnalysis.money(nil) == "—" && FinanceAnalysis.percent(nil) == "—")
    }

    /// 验证资产负债分母；参数：无；返回值：无，失败中止；零资产有负债时保留债务事实，不输出无穷或“0%”。
    private static func assetDenominators() {
        for assets in ["0", "-100", ""] {
            let report = FinanceAnalysis.report(overview(assets: assets, liabilities: "100"))
            precondition(report.debtRatio == nil)
            precondition(report.insights.contains { $0.title == "有负债，暂无有效资产基数" })
        }
        let noDebt = FinanceAnalysis.report(overview(liabilities: "0"))
        precondition(noDebt.debtRatio == 0)
        precondition(noDebt.insights.contains { $0.title == "计入净资产的账户暂无负债" })
        let heavyDebt = FinanceAnalysis.report(overview(assets: "100", liabilities: "200", netWorth: "-100"))
        precondition(heavyDebt.debtRatio == 200 && heavyDebt.netWorth == -100)
        let missingDebt = FinanceAnalysis.report(overview(liabilities: ""))
        precondition(missingDebt.debtRatio == nil && !missingDebt.insights.contains { $0.id == "debt" })
        let negativeDebt = FinanceAnalysis.report(overview(liabilities: "-10"))
        precondition(negativeDebt.debtRatio == nil && !negativeDebt.insights.contains { $0.id == "debt" })
    }

    /// 验证趋势完整性与严格解析；参数：无；返回值：无，失败中止；缺月不补零、负支出保留、重复月份不猜测，输出不依赖系统日期。
    private static func trendsAndParsing() {
        // 构造回调接收一至八月的整数、返回乱序输入用的虚构月度汇总；不请求 API。
        let eight = (1...8).reversed().map { month in CashFlow(month: String(format: "2026-%02d", month), income: "100", expense: "20", net: "80") }
        let months = FinanceAnalysis.recentMonths(eight)
        precondition(months.count == 6 && months.first?.month == "2026-03" && months.last?.month == "2026-08")
        let sparse = FinanceAnalysis.recentMonths([
            CashFlow(month: "2026-08", income: "100", expense: "-20", net: "120"),
            CashFlow(month: "2026-10", income: "0", expense: "", net: ""),
            CashFlow(month: "2026-13", income: "999", expense: "999", net: "0"),
            CashFlow(month: "2026-1", income: "999", expense: "999", net: "0")
        ])
        precondition(sparse.count == 2 && sparse.map(\.month) == ["2026-08", "2026-10"])
        precondition(sparse[0].expense == -20 && sparse[1].income == 0 && sparse[1].expense == nil && sparse[1].balance == nil)
        let duplicate = CashFlow(month: "2026-10", income: "1", expense: "1", net: "0")
        precondition(FinanceAnalysis.recentMonths([duplicate, duplicate]).isEmpty)
        for invalid in ["", " ", "NaN", "inf", "1e3", "12junk", "￥100", "10%", "1,000.00", ".5", "1."] {
            precondition(FinanceAnalysis.decimal(invalid) == nil, invalid)
        }
        precondition(FinanceAnalysis.decimal(" -12.50 ") == Decimal(string: "-12.50"))
        precondition(FinanceAnalysis.percentage(1, of: 0) == nil && FinanceAnalysis.percentage(1, of: -1) == nil)
        precondition(FinanceAnalysis.percentage(nil, of: 100) == nil)
        precondition(FinanceAnalysis.percent(0) == "0%")
        precondition(FinanceAnalysis.money(-20).contains("-"), "金额展示必须保留净退款符号")
    }
}

#if FINANCE_ANALYSIS_TEST_MAIN
@main
struct FinanceAnalysisStandaloneTests {
    /// 独立测试入口；参数：无；返回值：无，任一校验失败终止进程；以 -D FINANCE_ANALYSIS_TEST_MAIN 编译时启用，不与主代理的测试入口冲突。
    static func main() { FinanceAnalysisTests.run() }
}
#endif
