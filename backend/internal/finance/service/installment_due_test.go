// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"testing"
	"time"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
)

// installmentClock 固定到期判定时间；参数：s 为测试服务，day 为合法 UTC+8 日期；返回值：无，仅替换测试时钟，不改变数据库。
func installmentClock(s *Service, day string) {
	now, err := time.ParseInLocation("2006-01-02", day, time.FixedZone("UTC+8", 28800))
	if err != nil {
		panic(err)
	}
	// 时钟回调无参数；返回指定时间，模拟创建、读请求与后台执行的日期。
	s.now = func() time.Time { return now }
}

// TestInstallmentCreatePostsDue 验证截图中的第20期立即入账、未来四期不进入流水；参数：t 为测试上下文；返回值：无，覆盖两种本金计入模式和重试。
func TestInstallmentCreatePostsDue(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		installmentClock(s, "2026-09-28")
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "截图复现", "balance": "20000.00"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("due-create-example", a.ID, "expense", "9999.00")).(domain.Transaction)
		terms := domain.InstallmentTerms{Name: "OPPO FIND N5", Periods: 24, StartPeriod: 20, FirstDate: "2025-02-21", InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}
		plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
		if plan.Posted != 1 || plan.Rows[0].Period != 20 || plan.Rows[0].Date != "2026-09-21" || plan.Rows[0].Status != "posted" {
			t.Fatalf("创建后到期项未入账: %+v", plan)
		}
		for _, row := range plan.Rows[1:] {
			if row.Status != "pending" {
				t.Fatal("未来期次提前入账")
			}
		}
		replay := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
		if replay.Posted != 1 {
			t.Fatal("重试改变入账进度")
		}
		records, err := listTransactions(s.db, 1, Filter{AccountID: a.ID, Limit: 1})
		if err != nil || len(records) != 1 || records[0].InstallmentPeriod != 20 || records[0].InstallmentPeriods != 24 {
			t.Fatal("未来期次挤占第一页", records, err)
		}
		next, err := listTransactions(s.db, 1, Filter{AccountID: a.ID, Limit: 1, Offset: 1})
		if err != nil || len(next) != 0 {
			t.Fatal("未来分期仍在流水中")
		}
		pending, err := listTransactions(s.db, 1, Filter{AccountID: a.ID, Status: "pending"})
		if err != nil || len(pending) != 0 {
			t.Fatal("待确认筛选混入分期计划")
		}
		expected := domain.Money(2000000) - plan.Rows[0].Amount
		if mode == "upfront" {
			expected = 2000000
			for _, row := range plan.Rows {
				expected -= row.Principal
			}
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		var count int64
		if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.installment.post-due").Count(&count).Error; err != nil || count != 1 {
			t.Fatal("重复入账事件", count, err)
		}
	}
}

// TestInstallmentReadCatchesUp 验证无后台进程时各读取入口也会补记旧的过期分期；参数：t 为测试上下文；返回值：无；普通 AI 草稿仍保留待确认。
func TestInstallmentReadCatchesUp(t *testing.T) {
	for _, op := range []string{"finance.transaction.list", "finance.transaction.get", "finance.account.list", "finance.overview", "finance.installment.plan", "finance.installment.list", "finance.account.statement", "finance.account.statements"} {
		s := fixture(t)
		installmentClock(s, "2026-09-20")
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "读取补记", "balance": "1000.00", "billingDay": 20}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("due-read-test", a.ID, "expense", "300.00")).(domain.Transaction)
		plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "分期", Periods: 3, FirstDate: "2026-09-21", InterestMode: "spread", Rounding: "round", Remainder: "last"}).(domain.InstallmentPlan)
		draft, err := execute(s, 1, "finance.transaction.create", 0, transactionBody("due-ai-draft", a.ID, "expense", "10.00"), "ai")
		if err != nil {
			t.Fatal(err)
		}
		installmentClock(s, "2026-09-28")
		input := Input{ID: bill.ID, Filter: Filter{StartDate: "2026-08-01", EndDate: "2026-10-31"}}
		if op == "finance.transaction.get" {
			input.ID = plan.Rows[0].TransactionID
		}
		if op == "finance.account.statement" || op == "finance.account.statements" {
			input.ID = a.ID
		}
		for repeat := 0; repeat < 2; repeat++ {
			if _, err = s.Execute(context.Background(), capability.Actor{UserID: 1}, op, input, "http"); err != nil {
				t.Fatal(op, err)
			}
		}
		// 直接读取数据库验证，不调用其他可能补记的服务入口掩盖漏处理。
		var child domain.Transaction
		if err = s.db.First(&child, plan.Rows[0].TransactionID).Error; err != nil || child.Status != "posted" || child.TransactionDate != "2026-09-21" {
			t.Fatal(op, "未补记", child, err)
		}
		if err = s.db.First(&a, a.ID).Error; err != nil || a.Balance != 90000 {
			t.Fatal(op, "余额错误", a.Balance, err)
		}
		records, err := listTransactions(s.db, 1, Filter{Status: "pending"})
		if err != nil || len(records) != 1 || records[0].ID != draft.(domain.Transaction).ID {
			t.Fatal("普通草稿被自动入账或隐藏", records, err)
		}
	}
}
