// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestLoanDebtTotals 验证已还期数驱动本金、本息及总览，含已结清与不计入场景；参数：t 为测试上下文；返回值：无，仅写临时测试数据库。
func TestLoanDebtTotals(t *testing.T) {
	s := fixture(t)
	body := loanBody()
	body["loanPrincipal"], body["loanAnnualRate"], body["loanMethod"] = "650000.00", "3.2", "equal_principal"
	body["loanPeriods"], body["loanPaidPeriods"] = 360, 0
	a := must(t, s, "finance.account.create", 0, body).(domain.Account)
	// 从零期修改到已还 47 期，账本不补流水也必须更新展示与总欠款。
	updated := must(t, s, "finance.account.update", a.ID, map[string]any{"loanPaidPeriods": 47}).(domain.Account)
	plan := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	if plan.RemainingPrincipal != 56513868 || plan.PaidPrincipal != 8486132 {
		t.Fatalf("本金未随期数变化: %+v", plan)
	}
	if plan.RemainingTotal != plan.RemainingPrincipal+plan.RemainingInterest || plan.PaidTotal != plan.PaidPrincipal+plan.PaidInterest || plan.TotalPayment != plan.PaidTotal+plan.RemainingTotal {
		t.Fatal("本息合计不一致")
	}
	if updated.Balance != a.Balance {
		t.Fatal("展示修改不应伪造账本流水")
	}
	accounts := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
	if accounts[0].LoanPlan.RemainingTotal != plan.RemainingTotal || accounts[0].LoanPlan.Schedule != nil {
		t.Fatal("列表摘要丢失本息合计")
	}
	overview, err := overview(s.db, 1)
	if err != nil || overview.TotalLiabilities != plan.RemainingTotal || overview.NetWorth != -plan.RemainingTotal {
		t.Fatal("总览未按剩余本息统计", overview, err)
	}
	must(t, s, "finance.account.update", a.ID, map[string]any{"includeInNetWorth": false})
	excluded := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if excluded.TotalLiabilities != 0 {
		t.Fatal("不计入账户仍进入欠款汇总")
	}
	must(t, s, "finance.account.update", a.ID, map[string]any{"includeInNetWorth": true, "loanPaidPeriods": 360})
	closed := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	if closed.RemainingTotal != 0 || closed.RemainingPrincipal != 0 || closed.RemainingInterest != 0 || closed.PaidTotal != closed.TotalPayment {
		t.Fatal("已结清仍有欠款")
	}
	final := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if final.TotalLiabilities != 0 {
		t.Fatal("已结清账户仍按旧账本计算欠款")
	}
}
