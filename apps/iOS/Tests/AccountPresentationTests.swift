import Foundation

/// 账户页展示回归；仅使用内存账户和固定日历，不访问数据库或通知系统。
@MainActor enum AccountPresentationTests {
    /// 执行金额、目录分组、转账名称与账期边界验证；参数：无；返回值：无；失败终止测试。
    static func run() {
        var account = FinancialAccount(id: 1, name: "测试信用卡", accountType: "bank", institution: "招商银行（信用卡）", maskedAccountNumber: "", balance: "-3240.38", availableBalance: "-3240.38", currency: "CNY", includeInNetWorth: true, notes: "")
        account.creditLimit = "73000.00"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "69759.62"), "可用额度精确扣除欠款")
        account.creditLimit = "0.00"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "-3240.38"), "零额度仍展示实际可用额度")
        account.creditLimit = "73000.00"
        account.balance = "-73001.25"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "-1.25"), "超额信用消费保留负可用额度")
        account.balance = "10.25"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "73010.25"), "溢缴款计入可用额度")
        account.installmentCredit = "150.00"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "73160.25"), "专项恢复额只增加可用额度")
        CoreTests.check(account.balance == "10.25" && account.creditLimit == "73000.00", "专项恢复额不改余额和总授信")
        account.installmentInterestReserved = "20.00"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "73140.25"), "未入账利息预留扣减可用额度")
        account.installmentInterestReserved = "0.00"
        account.installmentCredit = "0.00"
        CoreTests.check(AccountPresentation.availableCredit(account) == Decimal(string: "73010.25"), "专项恢复额抵扣完回到原额度")
        CoreTests.check(AccountPresentation.section(account) == "credit", "银行卡信用标记进入信用组")
        CoreTests.check(AccountPresentation.transferTitle(target: account) == "还款", "信用卡转入显示还款")
        CoreTests.check(AccountPresentation.transferTitle(target: nil) == "转账", "目标账户缺失仍显示转账")
        // 每个目录项都经过真实解析，确保应收应付等产品不被泛化为信用或资金账户。
        for kind in AccountKindCatalog.bundled!.items where kind.route.isEmpty {
            account.accountType = kind.type; account.institution = kind.institution
            CoreTests.check(AccountPresentation.section(account) == kind.section, "资产分组保持目录用途：\(kind.name)")
            let title = kind.section == "prepaid" ? "充值" : ["credit", "payable"].contains(kind.section) ? "还款" : "转账"
            CoreTests.check(AccountPresentation.transferTitle(target: account) == title, "转账名称保持目标用途：\(kind.name)")
        }
        // 贷款以计划本息展示，已还期数无需依赖历史流水补录；本金与利息不得重复相加。
        account.institution = "贷款"; account.balance = "-650000.00"; account.loanPrincipal = "650000.00"
        account.loanPlan = LoanPlanSummary(remainingPrincipal: "565138.68", totalInterest: "300000.00", next: nil)
        account.loanPlan?.remainingTotal = "801743.41"; account.loanPlan?.totalPayment = "975130.51"
        CoreTests.check(AccountPresentation.balance(account) == Decimal(string: "-801743.41"), "贷款列表余额计入剩余利息")
        CoreTests.check(AccountPresentation.total([account]) == Decimal(string: "-801743.41"), "账户汇总与贷款列表同口径")
        CoreTests.check(AccountPresentation.loanTotal(account) == Decimal(string: "975130.51"), "总贷款采用全期本息")
        account.loanPlan?.remainingTotal = "0.00"
        CoreTests.check(AccountPresentation.balance(account) == 0, "结清后不再展示旧账本欠款")
        account.loanPlan = nil
        CoreTests.check(AccountPresentation.balance(account) == Decimal(string: "-650000.00"), "未设置计划的贷款保留账本欠款")
        account.institution = "招商银行（信用卡）"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        account.billingDay = 31; account.repaymentDay = 0
        let february = calendar.date(from: DateComponents(year: 2028, month: 2, day: 28))!
        CoreTests.check(AccountPresentation.cycleHint(account, now: february, calendar: calendar) == "1天后出账", "闰年月底账单日截到月末")
        account.billingDay = 20; account.repaymentDay = 7
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 28))!
        CoreTests.check(AccountPresentation.cycleHint(account, now: december, calendar: calendar) == "10天后还款", "最近还款日期跨年计算")
        let due = calendar.date(from: DateComponents(year: 2026, month: 12, day: 7, hour: 22))!
        account.billingDay = 7
        CoreTests.check(AccountPresentation.cycleHint(account, now: due, calendar: calendar) == "今天还款", "当天账期不跳过且还款优先")
        account.billingDay = 0; account.repaymentDay = 0
        CoreTests.check(AccountPresentation.cycleHint(account, now: due, calendar: calendar).isEmpty, "未设置账期不虚构日期")
    }
}
