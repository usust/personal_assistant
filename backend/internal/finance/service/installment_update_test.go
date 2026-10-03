// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"
	"time"

	domain "personal_assistant_server/internal/finance/model"
)

// TestInstallmentFullEdit 验证全表单修改、差额记账和重试；参数：t 为测试上下文；返回值：无，覆盖两种原欠款方式切换、历史期自动入账及未提交字段保留。
func TestInstallmentFullEdit(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "编辑账户", "balance": "1000.00"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("edit-full-plan", a.ID, "expense", "300.00")).(domain.Transaction)
		old := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2026-09-21", InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}).(domain.InstallmentPlan)
		// 时钟回调无参数，返回截图中的今天；使首期已到期、其余期次仍在未来。
		s.now = func() time.Time { return time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC) }
		must(t, s, "finance.installment.plan", bill.ID, nil)
		target := "upfront"
		if mode == "upfront" {
			target = "spread"
		}
		patch := map[string]any{"name": "新手机", "periods": 4, "interest": "4.00", "debtMode": target, "restoredCredit": "20.00", "interestCreditMode": "upfront", "rounding": "floor", "remainder": "first", "description": ""}
		plan := must(t, s, "finance.installment.update", bill.ID, patch).(domain.InstallmentPlan)
		if plan.FirstDate != "2026-09-21" || plan.Periods != 4 || plan.Rows[0].TransactionID != old.Rows[0].TransactionID || plan.Posted != 1 || plan.Total != 30400 || plan.RestoredCredit != 2000 {
			t.Fatal("整计划修改错误", plan)
		}
		expected := domain.Money(92400)
		if target == "upfront" {
			expected = 69900
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		must(t, s, "finance.installment.update", bill.ID, patch)
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		accounts := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if accounts[0].InstallmentPendingAmount != 22800 || accounts[0].InstallmentPendingInterest != 300 {
			t.Fatal("未更新待入账金额", accounts)
		}
		// 首期后移时撤销已入账金额，所有未到期账单仅保留计划内；重复更新不得重复调整余额。
		delayed := must(t, s, "finance.installment.update", bill.ID, map[string]any{"firstDate": "2026-10-21"}).(domain.InstallmentPlan)
		if delayed.Posted != 0 {
			t.Fatal("改期未撤销原入账", delayed)
		}
		expected = 100000
		if target == "upfront" {
			expected = 70000
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		must(t, s, "finance.installment.update", bill.ID, map[string]any{"firstDate": "2026-08-21", "startPeriod": 2, "interestMode": "first", "restoredCredit": "0.00"})
		expected = 92500
		if target == "upfront" {
			expected = 77500
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		must(t, s, "finance.installment.delete", bill.ID, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 100000})
	}
}

// TestInstallmentEditRefundAndDeletion 验证单期删除与退款不会被整计划编辑清除；参数：t 为测试上下文；返回值：无，非法修改退款金额或日期时整个请求回滚。
func TestInstallmentEditRefundAndDeletion(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "退款编辑", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("edit-refund-plan", a.ID, "expense", "300.00")).(domain.Transaction)
	// 时钟回调无参数，返回固定日期；首期可退款，后两期待入账。
	s.now = func() time.Time { return time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC) }
	old := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2026-09-21", InterestMode: "spread", Rounding: "round", Remainder: "last"}).(domain.InstallmentPlan)
	refund := must(t, s, "finance.transaction.refund", old.Rows[0].TransactionID, map[string]any{"requestId": "edit-refund-first", "amount": "80.00", "transactionDate": "2026-09-22"}).(domain.Transaction)
	must(t, s, "finance.transaction.delete", old.Rows[1].TransactionID, nil)
	plan := must(t, s, "finance.installment.update", bill.ID, map[string]any{"interest": "6.00"}).(domain.InstallmentPlan)
	if plan.Rows[1].Status != "deleted" || plan.Rows[0].TransactionID != old.Rows[0].TransactionID {
		t.Fatal("删除状态或退款关联丢失", plan)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 97800})
	actualRefund := must(t, s, "finance.transaction.get", refund.ID, nil).(domain.Transaction)
	if actualRefund.Status != "posted" || actualRefund.RefundParentID == nil || *actualRefund.RefundParentID != plan.Rows[0].TransactionID {
		t.Fatal("退款被改写", actualRefund)
	}
	for _, patch := range []map[string]any{{"periods": 4}, {"firstDate": "2026-10-21"}, {"startPeriod": 2}, {"periods": 0}, {"debtMode": nil}, {"accountId": a.ID}} {
		if _, err := execute(s, 1, "finance.installment.update", bill.ID, patch, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("未拒绝非法修改", patch, err)
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 97800})
	}
	must(t, s, "finance.installment.delete", bill.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 100000})
}

// TestInstallmentEditRangeAndRollback 验证期数减少、恢复以及写入失败原子回滚；参数：t 为测试上下文；返回值：无，确保旧期次可复用且不会生成重复流水。
func TestInstallmentEditRangeAndRollback(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "范围编辑", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("edit-range-plan", a.ID, "expense", "300.00")).(domain.Transaction)
	old := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2099-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: "upfront"}).(domain.InstallmentPlan)
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 2})
	expanded := must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 3}).(domain.InstallmentPlan)
	if expanded.Rows[2].Status != "pending" || expanded.Rows[2].TransactionID != old.Rows[2].TransactionID {
		t.Fatal("范围恢复产生重复或丢失期次", expanded)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 70000})
	if err := s.db.Exec("CREATE TRIGGER fail_edit BEFORE UPDATE OF amount ON finance_transactions_v2 WHEN NEW.installment_period = 2 BEGIN SELECT RAISE(ABORT, 'test failure'); END").Error; err != nil {
		t.Fatal(err)
	}
	if _, err := execute(s, 1, "finance.installment.update", bill.ID, map[string]any{"interest": "30.00", "debtMode": "spread"}, "http"); err == nil {
		t.Fatal("应当写入失败")
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 70000})
	actual := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	if actual.Interest != 0 || actual.DebtMode != "upfront" {
		t.Fatal("计划未回滚", actual)
	}
	first := must(t, s, "finance.transaction.get", old.Rows[0].TransactionID, nil).(domain.Transaction)
	if first.Amount != 10000 {
		t.Fatal("单期未回滚", first)
	}
	if err := s.db.Exec("DROP TRIGGER fail_edit").Error; err != nil {
		t.Fatal(err)
	}
	must(t, s, "finance.transaction.delete", old.Rows[2].TransactionID, nil)
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 2})
	restored := must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 3}).(domain.InstallmentPlan)
	if restored.Rows[2].Status != "deleted" {
		t.Fatal("缩短并恢复期数后复活了用户删除的期次", restored)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 80000})
	preview := must(t, s, "finance.installment.preview", bill.ID, domain.InstallmentTerms{Name: "试算编辑", Periods: 6, FirstDate: "2099-01-01", Interest: 600, InterestMode: "spread", Rounding: "round", Remainder: "last"}).(domain.InstallmentPlan)
	if preview.Periods != 6 || preview.Total != 30600 {
		t.Fatal("已保存计划不能试算新规则", preview)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 80000})
	unchanged := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	if unchanged.Periods != 3 || unchanged.Interest != 0 {
		t.Fatal("试算修改了已保存计划", unchanged)
	}
}
