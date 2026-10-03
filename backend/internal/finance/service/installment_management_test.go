// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
)

// TestInstallmentManagement 验证账户汇总、白名单修改、完结和整计划删除；参数：t 为测试上下文；返回值：无，覆盖两种欠款计入模式及重复请求。
func TestInstallmentManagement(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "管理测试", "balance": "1000.00"}).(domain.Account)
		other := must(t, s, "finance.account.create", 0, map[string]any{"name": "另一个账户"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("management-test", a.ID, "expense", "300.00")).(domain.Transaction)
		plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2099-01-01", Interest: 300, InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}).(domain.InstallmentPlan)
		// 查询回调参数为账户 ID；返回服务端摘要，错误使测试失败，使用真实授权入口校验账户过滤。
		list := func(account uint64) []domain.InstallmentSummary {
			t.Helper()
			value, err := s.Execute(context.Background(), capability.Actor{UserID: 1}, "finance.installment.list", Input{Filter: Filter{AccountID: account}}, "http")
			if err != nil {
				t.Fatal(err)
			}
			return value.([]domain.InstallmentSummary)
		}
		summaries := list(a.ID)
		if len(summaries) != 1 || summaries[0].PendingAmount != 30300 || summaries[0].PendingInterest != 300 || summaries[0].NextDate != "2099-01-01" || len(list(other.ID)) != 0 {
			t.Fatal("账户摘要或隔离错误", summaries)
		}
		accounts := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if accounts[0].InstallmentPendingAmount != 30300 || accounts[0].InstallmentPendingInterest != 300 {
			t.Fatal("账户未汇总全部待入账金额")
		}
		for _, op := range []string{"finance.installment.update", "finance.installment.finish", "finance.installment.delete"} {
			if _, err := execute(s, 2, op, bill.ID, map[string]any{"name": "越权"}, "http"); !errors.Is(err, ErrNotFound) {
				t.Fatal("越权", op, err)
			}
			if _, err := execute(s, 1, op, bill.ID, map[string]any{"name": "AI修改"}, "ai"); !errors.Is(err, ErrInvalid) {
				t.Fatal("AI越权", op, err)
			}
		}
		updated := must(t, s, "finance.installment.update", bill.ID, map[string]any{"name": "新名称", "description": "", "categoryId": nil}).(domain.InstallmentPlan)
		if updated.Name != "新名称" || updated.Periods != 3 || updated.Interest != 300 {
			t.Fatal("PATCH覆盖未提交字段")
		}
		child := must(t, s, "finance.transaction.get", plan.Rows[0].TransactionID, nil).(domain.Transaction)
		if child.Description != "" || child.CategoryID != nil || child.InstallmentName != "新名称" {
			t.Fatal("零值或名称未同步")
		}
		if _, err := execute(s, 1, "finance.installment.update", bill.ID, map[string]any{"unexpected": 8}, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("允许未校验字段")
		}
		must(t, s, "finance.transaction.delete", plan.Rows[0].TransactionID, nil)
		must(t, s, "finance.installment.finish", bill.ID, nil)
		must(t, s, "finance.installment.finish", bill.ID, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 79800, other.ID: 0})
		summaries = list(a.ID)
		if summaries[0].PendingAmount != 0 || summaries[0].PendingInterest != 0 || summaries[0].NextDate != "" || summaries[0].Plan.Posted != 2 {
			t.Fatal("完结汇总错误")
		}
		today := time.Now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
		if summaries[0].Plan.Rows[1].Date != today || summaries[0].Plan.Rows[0].Status != "deleted" {
			t.Fatal("完结日期或已删除状态错误")
		}
		must(t, s, "finance.installment.delete", bill.ID, nil)
		must(t, s, "finance.installment.delete", bill.ID, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 100000, other.ID: 0})
		if len(list(a.ID)) != 0 {
			t.Fatal("已删除计划仍可见")
		}
		accounts = must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if accounts[0].InstallmentPendingAmount != 0 || accounts[0].InstallmentPendingInterest != 0 {
			t.Fatal("已删除计划仍计入待入账")
		}
	}
}

// TestInstallmentFinishRollback 验证完结中途失败时所有日期、状态和余额原子回滚；参数：t 为测试上下文；返回值：无，仅使用 SQLite 临时数据库故障注入。
func TestInstallmentFinishRollback(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "回滚", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("rollback-plan", a.ID, "expense", "100.00")).(domain.Transaction)
	plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "回滚测试", Periods: 2, FirstDate: "2099-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last"}).(domain.InstallmentPlan)
	if err := s.db.Exec("CREATE TRIGGER fail_second BEFORE UPDATE OF status ON finance_transactions_v2 WHEN NEW.installment_period = 2 AND NEW.status = 'posted' BEGIN SELECT RAISE(ABORT, 'test failure'); END").Error; err != nil {
		t.Fatal(err)
	}
	if _, err := execute(s, 1, "finance.installment.finish", bill.ID, nil, "http"); err == nil {
		t.Fatal("预期完结失败")
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 100000})
	actual := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	for i, row := range actual.Rows {
		if row.Status != "pending" || row.Date != plan.Rows[i].Date {
			t.Fatal("失败留下部分入账", row)
		}
	}
}
