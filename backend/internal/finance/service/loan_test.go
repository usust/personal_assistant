// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// loanFixture 构造固定贷款条款；参数：无；返回值：用于零利率、日期与本金守恒测试的完整条款。
func loanFixture() domain.LoanTerms {
	return domain.LoanTerms{LoanPrincipal: 100000, LoanAnnualRate: "12", LoanMethod: "annuity", LoanPeriods: 12, LoanPaidPeriods: 0, LoanFirstPaymentDate: "2028-01-31"}
}

// TestLoanSchedules 验证三种方法本金守恒、尾差、零利率及月末锚点；参数：t 为测试上下文；返回值：无，无数据库副作用。
func TestLoanSchedules(t *testing.T) {
	for _, method := range []string{"annuity", "equal_principal", "interest_only"} {
		for _, rate := range []string{"0", "12", "0.1234"} {
			terms := loanFixture()
			terms.LoanMethod = method
			terms.LoanAnnualRate = rate
			plan, e := buildLoanPlan(terms)
			if e != nil {
				t.Fatal(e)
			}
			var principal, interest domain.Money
			for _, row := range plan.Schedule {
				principal += row.Principal
				interest += row.Interest
				if row.Payment != row.Principal+row.Interest || row.Remaining < 0 {
					t.Fatalf("非法期次：%+v", row)
				}
			}
			if principal != terms.LoanPrincipal || interest != plan.TotalInterest || plan.Schedule[11].Remaining != 0 {
				t.Fatalf("本金不守恒：%s %s %+v", method, rate, plan)
			}
			if rate == "0" && interest != 0 {
				t.Fatal("零利率产生利息")
			}
			if plan.Schedule[1].Date != "2028-02-29" || plan.Schedule[2].Date != "2028-03-31" {
				t.Fatal("月末日期漂移")
			}
			terms.LoanPaidPeriods = 12
			closed, e := buildLoanPlan(terms)
			if e != nil || closed.Next != nil || closed.RemainingPrincipal != 0 {
				t.Fatal("已结清仍有下一期")
			}
		}
	}
	terms := loanFixture()
	terms.LoanMethod = "equal_principal"
	plan, _ := buildLoanPlan(terms)
	if plan.Schedule[0].Principal != 8333 || plan.Schedule[0].Interest != 1000 || plan.Schedule[0].Payment != 9333 {
		t.Fatalf("等额本金首期错误：%+v", plan.Schedule[0])
	}
	terms.LoanMethod = "interest_only"
	plan, _ = buildLoanPlan(terms)
	if plan.Schedule[0].Payment != 1000 || plan.Schedule[11].Payment != 101000 || plan.TotalInterest != 12000 {
		t.Fatal("先息后本错误")
	}
	terms.LoanMethod = "annuity"
	plan, _ = buildLoanPlan(terms)
	if plan.Schedule[0].Payment != 8885 {
		t.Fatalf("等额本息错误：%+v", plan.Schedule[0])
	}
}

// loanBody 构造账户接口资料；参数：无；返回值：独立字段映射；只用于临时数据库测试。
func loanBody() map[string]any {
	return map[string]any{"name": "测试贷款", "accountType": "other", "institution": "贷款", "loanPrincipal": "12000.00", "loanAnnualRate": "0", "loanMethod": "equal_principal", "loanPeriods": 12, "loanPaidPeriods": 3, "loanFirstPaymentDate": "2026-01-31"}
}

// TestLoanAccountPersistence 验证建账、部分更新、清空、历史余额和权限；参数：t 为测试上下文；返回值：无；仅写测试数据库。
func TestLoanAccountPersistence(t *testing.T) {
	s := fixture(t)
	receiving := must(t, s, "finance.account.create", 0, map[string]any{"name": "收款账户", "balance": "20.00"}).(domain.Account)
	body := loanBody()
	body["loanReceivingAccountId"] = receiving.ID
	row := must(t, s, "finance.account.create", 0, body).(domain.Account)
	if row.Balance != -900000 || row.LoanPlan == nil || row.LoanPlan.Next.Period != 4 {
		t.Fatalf("初始负债错误：%+v", row)
	}
	balances(t, s, map[uint64]domain.Money{row.ID: -900000, receiving.ID: 2000})
	// 已还期数与资料仍支持零值更新；原合同调息改用分期入口，不能重写历史计划。
	row = must(t, s, "finance.account.update", row.ID, map[string]any{"loanPaidPeriods": 0, "loanReceivingAccountId": 0, "loanLender": ""}).(domain.Account)
	if row.LoanPaidPeriods != 0 || row.LoanReceivingAccountID != 0 || row.Balance != -900000 || row.LoanPeriods != 12 {
		t.Fatalf("PATCH 丢失零值或覆盖余额：%+v", row)
	}
	row = must(t, s, "finance.account.update", row.ID, map[string]any{"currentDebt": "0.00"}).(domain.Account)
	if row.Balance != 0 {
		t.Fatal("不能清零实际欠款")
	}
	if _, e := execute(s, 1, "finance.account.update", row.ID, map[string]any{"loanPaidPeriods": 13, "name": "不应保存"}, "http"); e == nil {
		t.Fatal("越界期数通过")
	}
	persisted, e := account(s.db, 1, row.ID, true)
	if e != nil || persisted.Name != "测试贷款" || persisted.LoanPaidPeriods != 0 {
		t.Fatal("失败更新没有整体回滚")
	}
	foreign, e := execute(s, 2, "finance.account.create", 0, map[string]any{"name": "他人账户"}, "http")
	if e != nil {
		t.Fatal(e)
	}
	for _, bad := range []map[string]any{{"loanReceivingAccountId": foreign.(domain.Account).ID}, {"loanReceivingAccountId": row.ID}, {"loanAnnualRate": "100.0001"}, {"loanAnnualRate": "NaN"}, {"loanPeriods": 481}, {"loanFirstPaymentDate": "2026-02-30"}, {"currentDebt": "-1.00"}, {"loanPrincipal": nil}} {
		if _, e := execute(s, 1, "finance.account.update", row.ID, bad, "http"); e == nil {
			t.Fatalf("非法更新通过：%v", bad)
		}
	}
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthIncome != 0 || summary.MonthExpense != 0 {
		t.Fatal("贷款资料写入被计入收支")
	}
	// 历史贷款没有计划仍可只编辑备注；不能因新字段缺失而篡改余额。
	legacy := domain.Account{OwnerID: 1, Name: "旧贷款", Institution: "贷款", AccountType: "other", Currency: "CNY", Balance: -10000, ReminderDays: -1}
	if e = s.db.Create(&legacy).Error; e != nil {
		t.Fatal(e)
	}
	updated := must(t, s, "finance.account.update", legacy.ID, map[string]any{"notes": "保留旧欠款"}).(domain.Account)
	if updated.Balance != -10000 || updated.LoanPlan != nil {
		t.Fatal("旧数据不兼容")
	}
}

// TestLoanPreviewReadOnly 验证试算不创建账本或审计写事件；参数：t 为测试上下文；返回值：无；仅查询临时数据库。
func TestLoanPreviewReadOnly(t *testing.T) {
	s := fixture(t)
	terms := loanFixture()
	result := must(t, s, "finance.loan.preview", 0, terms).(*domain.LoanPlan)
	if len(result.Schedule) != 12 {
		t.Fatal("试算缺少期次")
	}
	var count int64
	s.db.Model(&domain.Account{}).Count(&count)
	if count != 0 {
		t.Fatal("试算创建账户")
	}
	s.db.Model(&domain.Event{}).Count(&count)
	if count != 0 {
		t.Fatal("试算创建写事件")
	}
}

// TestLoanLimits 验证最大期数、微小金额及跨年边界；参数：t 为测试上下文；返回值：无，无外部副作用。
func TestLoanLimits(t *testing.T) {
	terms := loanFixture()
	terms.LoanPrincipal = 1
	terms.LoanPeriods = 480
	terms.LoanAnnualRate = "0"
	terms.LoanFirstPaymentDate = "2026-12-31"
	plan, e := buildLoanPlan(terms)
	if e != nil {
		t.Fatal(e)
	}
	if len(plan.Schedule) != 480 || plan.Schedule[479].Principal != 1 || plan.Schedule[1].Date != "2027-01-31" || plan.Schedule[2].Date != "2027-02-28" {
		t.Fatal("微小金额尾差或最大期数日期错误")
	}
	terms.LoanPeriods = 1
	terms.LoanAnnualRate = "12"
	terms.LoanPrincipal = 100000
	plan, e = buildLoanPlan(terms)
	if e != nil || plan.Schedule[0].Principal != 100000 || plan.Schedule[0].Interest != 1000 {
		t.Fatal("单期贷款计算错误")
	}
}
