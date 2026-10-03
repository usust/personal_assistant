// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"reflect"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestSinglePeriodPaymentCorrection 验证三种还款方式的首期、中期和末期修正；参数：t 为测试上下文；返回值：无，不写库。
func TestSinglePeriodPaymentCorrection(t *testing.T) {
	for _, method := range []string{"annuity", "equal_principal", "interest_only"} {
		a := domain.Account{LoanTerms: loanFixture()}
		a.LoanMethod = method
		before, err := accountLoanPlan(a)
		if err != nil {
			t.Fatal(err)
		}
		original := append([]domain.LoanPayment{}, before.Schedule...)
		v := 0
		for _, period := range []int{1, 4, len(original)} {
			for _, amount := range []domain.Money{1, 123456} {
				in := domain.LoanAdjustmentInput{Revision: &v, Kind: "payment", Scope: "period", FromPeriod: period, Payment: &amount}
				after, err := adjustedLoanPlan(a, before, in)
				if err != nil {
					t.Fatal(method, period, err)
				}
				for i, row := range after.Schedule {
					expected := original[i]
					if i == period-1 {
						expected.Payment = amount
						expected.PaymentOverridden = amount != expected.Principal+expected.Interest
					}
					if row != expected {
						t.Fatal("只允许修改选中行的应还及修正标记", method, period, i+1)
					}
				}
				if !reflect.DeepEqual(before.Schedule, original) || after.TotalInterest != before.TotalInterest || after.RemainingPrincipal != before.RemainingPrincipal {
					t.Fatal("单期修正修改旧计划或摊销汇总")
				}
				// 恢复原应还时去掉修正标记，整份计划应与原计划逐项相同。
				base := original[period-1].Payment
				in.Payment = &base
				restored, err := adjustedLoanPlan(a, after, in)
				if err != nil || !reflect.DeepEqual(restored, before) {
					t.Fatal("恢复原金额不一致", err)
				}
				// 随后调息仍保留明确修正的本期应还，同时允许原本息随新利率重算。
				rated, err := adjustedLoanPlan(a, after, domain.LoanAdjustmentInput{Revision: &v, Kind: "rate", FromPeriod: 1, AnnualRate: "3"})
				if err != nil || rated.Schedule[period-1].Payment != amount || !rated.Schedule[period-1].PaymentOverridden {
					t.Fatal("调息丢失单期金额", err)
				}
			}
		}
	}
}

// TestSinglePeriodPaymentGuards 验证金额输入边界及范围必须明确；参数：t 为测试上下文；返回值：无，无外部副作用。
func TestSinglePeriodPaymentGuards(t *testing.T) {
	a := domain.Account{LoanTerms: loanFixture()}
	before, err := accountLoanPlan(a)
	if err != nil {
		t.Fatal(err)
	}
	v := 0
	zero, negative, excessive, positive := domain.Money(0), domain.Money(-1), maxMoney+1, domain.Money(100)
	for _, in := range []domain.LoanAdjustmentInput{
		{Kind: "payment", Scope: "period", Payment: &zero},
		{Kind: "payment", Scope: "period", Payment: &negative},
		{Kind: "payment", Scope: "period", Payment: &excessive},
		{Kind: "payment", Scope: "period"},
		{Kind: "payment", Payment: &positive},
		{Kind: "payment", Scope: "future", Payment: &positive},
		{Kind: "payment", Scope: "period", PaymentMode: "fixed", Payment: &positive},
		{Kind: "rate", Scope: "period", AnnualRate: "3"},
	} {
		in.Revision, in.FromPeriod = &v, 2
		if _, err := adjustedLoanPlan(a, before, in); err == nil {
			t.Fatal("接受非法金额或模糊范围", in)
		}
	}
}
