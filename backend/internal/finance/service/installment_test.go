// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// TestConsumptionInstallment 验证试算、转换、隔离和幂等入账；参数：t 为测试上下文；返回值：无，仅使用临时数据库。
func TestConsumptionInstallment(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "消费账户", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("installment-test", a.ID, "expense", "100.00")).(domain.Transaction)
	terms := domain.InstallmentTerms{Name: "消费分期", Periods: 3, FirstDate: "2028-01-31", Interest: 101, InterestMode: "spread", Rounding: "round", Remainder: "last"}
	preview := must(t, s, "finance.installment.preview", bill.ID, terms).(domain.InstallmentPlan)
	if preview.Rows[1].Date != "2028-02-29" || preview.Rows[2].Date != "2028-03-31" || preview.Rows[2].Principal != 3334 || preview.Rows[2].Interest != 33 {
		t.Fatalf("日期或尾差错误: %+v", preview)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 90000})
	if _, err := execute(s, 2, "finance.installment.create", bill.ID, terms, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("越权: %v", err)
	}
	if _, err := execute(s, 1, "finance.installment.create", bill.ID, terms, "ai"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("AI 越权: %v", err)
	}
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	balances(t, s, map[uint64]domain.Money{a.ID: 100000})
	replay := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	if replay.Rows[0].TransactionID != plan.Rows[0].TransactionID {
		t.Fatal("重复拆分")
	}
	terms.Periods = 4
	if _, err := execute(s, 1, "finance.installment.create", bill.ID, terms, "http"); !errors.Is(err, ErrConflict) {
		t.Fatalf("重复转换未冲突: %v", err)
	}
	for _, row := range plan.Rows {
		must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
		must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 89899})
	saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	if saved.Posted != 3 {
		t.Fatal("入账进度错误")
	}
	for _, id := range []uint64{bill.ID, plan.Rows[0].TransactionID} {
		if _, err := execute(s, 1, "finance.transaction.void", id, nil, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatalf("允许破坏分期: %v", err)
		}
	}
}

// TestInstallmentRounding 验证零利息、不同舍入及精确合计；参数：t 为测试上下文；返回值：无，无数据库写入。
func TestInstallmentRounding(t *testing.T) {
	for _, rounding := range []string{"round", "floor"} {
		for _, remainder := range []string{"first", "last"} {
			for _, mode := range []string{"first", "spread"} {
				terms := domain.InstallmentTerms{Name: "测试", Periods: 12, FirstDate: "2026-09-28", Interest: 123, InterestMode: mode, Rounding: rounding, Remainder: remainder}
				plan, err := calculateInstallment(23760, terms)
				if err != nil {
					t.Fatal(err)
				}
				var principal, interest domain.Money
				for _, row := range plan.Rows {
					principal += row.Principal
					interest += row.Interest
				}
				if principal != 23760 || interest != 123 {
					t.Fatalf("合计不守恒: %+v", plan)
				}
				terms.Interest = 0
				if _, err = calculateInstallment(23760, terms); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	terms := domain.InstallmentTerms{Name: "测试", Periods: 360, FirstDate: "2026-09-28", InterestMode: "spread", Rounding: "round", Remainder: "last"}
	if _, err := calculateInstallment(1, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("允许零额或负数期次")
	}
	terms.Periods = 0
	if _, err := calculateInstallment(10000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("允许零期数")
	}
}

// TestInstallmentRollback 验证中途流水键冲突时恢复全部状态；参数：t 为测试上下文；返回值：无，仅使用临时数据库。
func TestInstallmentRollback(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "回滚账户", "balance": "100.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("rollback-bill", a.ID, "expense", "30.00")).(domain.Transaction)
	// 占用第二期期次键，确保第一期已写入后仍能完整回滚。
	must(t, s, "finance.transaction.create", 0, transactionBody(fmt.Sprintf("installment_%d_2", bill.ID), a.ID, "expense", "1.00"))
	terms := domain.InstallmentTerms{Name: "回滚", Periods: 3, FirstDate: "2026-09-28", InterestMode: "spread", Rounding: "round", Remainder: "first"}
	if _, err := execute(s, 1, "finance.installment.create", bill.ID, terms, "http"); err == nil {
		t.Fatal("应拒绝重复流水键")
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 6900})
	var stored domain.Transaction
	if err := s.db.First(&stored, bill.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Status != "posted" || stored.InstallmentJSON != "" {
		t.Fatal("主账单未回滚")
	}
	var count int64
	if err := s.db.Model(&domain.Transaction{}).Where("installment_parent_id = ?", bill.ID).Count(&count).Error; err != nil || count != 0 {
		t.Fatalf("残留分期: %d %v", count, err)
	}
}

// TestInstallmentMetadata 验证资料试算不写入、保存继承、显式清空及重试；参数：t 为测试上下文；返回值：无。
func TestInstallmentMetadata(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "分期账户", "balance": "1000.00"}).(domain.Account)
	c := must(t, s, "finance.category.create", 0, map[string]any{"name": "分期测试分类", "type": "expense"}).(domain.Category)
	for _, clear := range []bool{false, true} {
		body := transactionBody(fmt.Sprintf("metadata-%v", clear), a.ID, "expense", "100.00")
		body["categoryId"] = c.ID
		body["description"] = "原备注"
		bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
		categoryID, note := c.ID, "分期备注"
		if clear {
			categoryID = 0
			note = ""
		}
		terms := domain.InstallmentTerms{Name: "分期", Periods: 3, FirstDate: "2026-10-01", InterestMode: "spread", Rounding: "floor", Remainder: "last", CategoryID: &categoryID, Description: &note}
		must(t, s, "finance.installment.preview", bill.ID, terms)
		var original domain.Transaction
		if err := s.db.First(&original, bill.ID).Error; err != nil {
			t.Fatal(err)
		}
		if original.Description != "原备注" || original.CategoryID == nil {
			t.Fatal("试算修改了原流水")
		}
		plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
		replay := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
		if replay.Rows[0].TransactionID != plan.Rows[0].TransactionID {
			t.Fatal("重试重复分期")
		}
		if err := s.db.First(&original, bill.ID).Error; err != nil {
			t.Fatal(err)
		}
		if original.Description != note || (clear && original.CategoryID != nil) {
			t.Fatal("原流水资料未更新")
		}
		var child domain.Transaction
		if err := s.db.First(&child, plan.Rows[0].TransactionID).Error; err != nil {
			t.Fatal(err)
		}
		if clear && (child.CategoryID != nil || child.Description != "") {
			t.Fatal("清空分类未传递")
		}
		if !clear && (child.Description != note || child.CategoryID == nil || *child.CategoryID != c.ID) {
			t.Fatal("分期未继承资料")
		}
	}
}

// TestInstallmentPeriodLimit 验证消费分期 480 期边界及精确拆分；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestInstallmentPeriodLimit(t *testing.T) {
	terms := domain.InstallmentTerms{Name: "长期分期", Periods: 480, FirstDate: "2026-09-28", InterestMode: "spread", Rounding: "round", Remainder: "last"}
	plan, err := calculateInstallment(48000, terms)
	if err != nil || len(plan.Rows) != 480 {
		t.Fatalf("480 期应有效: %v", err)
	}
	var total domain.Money
	for _, row := range plan.Rows {
		total += row.Amount
	}
	if total != 48000 {
		t.Fatalf("拆分总额错误: %v", total)
	}
	for _, periods := range []int{0, 1, 481} {
		terms.Periods = periods
		if _, err := calculateInstallment(48000, terms); !errors.Is(err, ErrInvalid) {
			t.Fatalf("应拒绝 %d 期: %v", periods, err)
		}
	}
}

// TestInstallmentStartAndCredit 验证跳过期次、恢复额随本金抵扣及重试隔离；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestInstallmentStartAndCredit(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "专项额度账户", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("start-credit", a.ID, "expense", "400.00")).(domain.Transaction)
	terms := domain.InstallmentTerms{Name: "从第三期开始", Periods: 4, StartPeriod: 3, FirstDate: "2026-01-31", Interest: 400, InterestMode: "spread", Rounding: "round", Remainder: "last", RestoredCredit: 15000}
	preview := must(t, s, "finance.installment.preview", bill.ID, terms).(domain.InstallmentPlan)
	if len(preview.Rows) != 2 || preview.Rows[0].Period != 3 || preview.Rows[0].Date != "2026-03-31" || preview.Total != 20200 {
		t.Fatalf("起始范围错误: %+v", preview)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 60000})
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	must(t, s, "finance.installment.create", bill.ID, terms)
	balances(t, s, map[uint64]domain.Money{a.ID: 100000})
	var count int64
	if err := s.db.Model(&domain.Transaction{}).Where("installment_parent_id = ?", bill.ID).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatal("跳过期次不应生成流水")
	}
	// 检查回调参数 expected 为剩余专项恢复额；返回无，仅断言账户展示字段及授信不变。
	checkCredit := func(expected domain.Money) {
		rows := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		for _, row := range rows {
			if row.ID == a.ID {
				if row.InstallmentCredit != expected || row.CreditLimit != a.CreditLimit {
					t.Fatalf("恢复额或授信错误: %+v", row)
				}
				return
			}
		}
		t.Fatal("未返回目标账户")
	}
	checkCredit(15000)
	must(t, s, "finance.transaction.confirm", plan.Rows[0].TransactionID, nil)
	must(t, s, "finance.transaction.confirm", plan.Rows[0].TransactionID, nil)
	checkCredit(5000)
	balances(t, s, map[uint64]domain.Money{a.ID: 89900})
	must(t, s, "finance.transaction.confirm", plan.Rows[1].TransactionID, nil)
	checkCredit(0)
	balances(t, s, map[uint64]domain.Money{a.ID: 79800})
	saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	if saved.Posted != 2 || saved.StartPeriod != 3 || saved.RestoredCredit != 15000 {
		t.Fatal("规则或进度未保存")
	}
	other, err := execute(s, 2, "finance.account.list", 0, nil, "http")
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range other.([]domain.Account) {
		if row.InstallmentCredit != 0 {
			t.Fatal("恢复额跨用户泄漏")
		}
	}
	terms.StartPeriod = 5
	if _, err := calculateInstallment(40000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("越界起始期未拒绝")
	}
	terms.StartPeriod = 3
	terms.RestoredCredit = 20001
	if _, err := calculateInstallment(40000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("超出剩余本金的恢复额未拒绝")
	}
	terms.RestoredCredit = -1
	if _, err := calculateInstallment(40000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("负恢复额未拒绝")
	}
}

// TestInstallmentUpfrontDebt 验证一次性计入仅预记待生成本金、逐期不重复扣本金；参数：t 为测试上下文；返回值：无。
func TestInstallmentUpfrontDebt(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "一次性欠款", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("upfront-test", a.ID, "expense", "400.00")).(domain.Transaction)
	terms := domain.InstallmentTerms{Name: "一次性分期", Periods: 4, StartPeriod: 3, FirstDate: "2026-09-28", Interest: 400, InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: "upfront", RestoredCredit: 15000}
	must(t, s, "finance.installment.preview", bill.ID, terms)
	balances(t, s, map[uint64]domain.Money{a.ID: 60000})
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	balances(t, s, map[uint64]domain.Money{a.ID: 80000})
	must(t, s, "finance.installment.create", bill.ID, terms)
	balances(t, s, map[uint64]domain.Money{a.ID: 80000})
	for i, row := range plan.Rows {
		must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
		must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 80000 - domain.Money(i+1)*100})
	}
	var posted []domain.Transaction
	if err := s.db.Where("installment_parent_id = ? AND status = ?", bill.ID, "posted").Find(&posted).Error; err != nil {
		t.Fatal(err)
	}
	var expense domain.Money
	for _, row := range posted {
		expense += row.Amount
	}
	if expense != 20200 {
		t.Fatal("收支统计应保留本息全额")
	}
	rows := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
	for _, row := range rows {
		if row.ID == a.ID && row.InstallmentCredit != 0 {
			t.Fatal("恢复额未按本金抵扣")
		}
	}
	terms.DebtMode = "invalid"
	if _, err := calculateInstallment(40000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("非法欠款方式未拒绝")
	}
}

// TestInstallmentInterestCredit 验证利息预留与本金欠款方式、利息入账方式独立组合；参数：t 为测试上下文；返回值：无。
func TestInstallmentInterestCredit(t *testing.T) {
	for _, debtMode := range []string{"spread", "upfront"} {
		for _, interestMode := range []string{"spread", "first"} {
			for _, creditMode := range []string{"spread", "upfront"} {
				s := fixture(t)
				a := must(t, s, "finance.account.create", 0, map[string]any{"name": "利息额度测试", "balance": "1000.00"}).(domain.Account)
				bill := must(t, s, "finance.transaction.create", 0, transactionBody("interest-credit-test", a.ID, "expense", "400.00")).(domain.Transaction)
				terms := domain.InstallmentTerms{Name: "利息占用", Periods: 4, FirstDate: "2026-09-28", Interest: 400, InterestMode: interestMode, Rounding: "round", Remainder: "last", DebtMode: debtMode, InterestCreditMode: creditMode}
				plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
				balance := domain.Money(100000)
				if debtMode == "upfront" {
					balance -= 40000
				}
				remaining := domain.Money(400)
				// 检查回调无参数、无返回值；预留只改展示额度，原授信和账本余额遵循欠款模式。
				check := func() {
					balances(t, s, map[uint64]domain.Money{a.ID: balance})
					rows := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
					expected := domain.Money(0)
					if creditMode == "upfront" {
						expected = remaining
					}
					for _, row := range rows {
						if row.ID == a.ID && (row.InstallmentInterestReserved != expected || row.CreditLimit != a.CreditLimit) {
							t.Fatalf("组合 %s/%s/%s 预留错误: %+v", debtMode, interestMode, creditMode, row)
						}
					}
				}
				check()
				for _, row := range plan.Rows {
					must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
					must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
					remaining -= row.Interest
					balance -= row.Interest
					if debtMode == "spread" {
						balance -= row.Principal
					}
					check()
				}
			}
		}
	}
	terms := domain.InstallmentTerms{Name: "无效模式", Periods: 2, FirstDate: "2026-09-28", InterestMode: "spread", Rounding: "round", Remainder: "last", InterestCreditMode: "invalid"}
	if _, err := calculateInstallment(10000, terms); !errors.Is(err, ErrInvalid) {
		t.Fatal("非法占用模式未拒绝")
	}
}

// TestInstallmentListPresentation 验证主账单在分页前隐藏、子账单附带真实期数及计划名；参数：t 为测试上下文；返回值：无。
func TestInstallmentListPresentation(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "流水展示测试", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("list-installment", a.ID, "expense", "300.00")).(domain.Transaction)
	terms := domain.InstallmentTerms{Name: "手机分期", Periods: 3, FirstDate: bill.TransactionDate, InterestMode: "spread", Rounding: "round", Remainder: "last"}
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	for _, row := range plan.Rows {
		must(t, s, "finance.transaction.confirm", row.TransactionID, nil)
	}
	for offset := 0; offset < 3; offset++ {
		rows, err := listTransactions(s.db, 1, Filter{AccountID: a.ID, Limit: 1, Offset: offset})
		if err != nil || len(rows) != 1 {
			t.Fatalf("分页错误: %v", err)
		}
		row := rows[0]
		if row.ID == bill.ID || row.InstallmentPeriods != 3 || row.InstallmentName != "手机分期" || row.InstallmentPeriod != 3-offset {
			t.Fatalf("展示数据错误: %+v", row)
		}
	}
	rows, err := listTransactions(s.db, 1, Filter{AccountID: a.ID, Limit: 1, Offset: 3})
	if err != nil || len(rows) != 0 {
		t.Fatal("原账单不应出现在下一页")
	}
	if _, err := installment(s.db, 1, "finance.installment.plan", Input{ID: bill.ID}); err != nil {
		t.Fatal("隐藏不应删除原计划")
	}
}

// TestInstallmentAutomaticPosting 验证自然日边界、历史补记、普通草稿隔离与重复执行；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestInstallmentAutomaticPosting(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "自动入账", "balance": "1000.00"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("auto-posting", a.ID, "expense", "300.00")).(domain.Transaction)
		plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2026-01-31", Interest: 300, InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}).(domain.InstallmentPlan)
		draft, err := execute(s, 1, "finance.transaction.create", 0, transactionBody("ai-draft", a.ID, "expense", "10.00"), "ai")
		if err != nil {
			t.Fatal(err)
		}
		// 输入 UTC 时间并在事务中执行，验证 UTC+8 午夜才入账；返回值为数据库错误，失败回滚。
		run := func(instant string) {
			t.Helper()
			now, err := time.Parse(time.RFC3339, instant)
			if err != nil {
				t.Fatal(err)
			}
			// 事务回调参数为测试事务；返回值为入账错误，单线程测试不需额外用户锁。
			if err := s.db.Transaction(func(tx *gorm.DB) error { return s.postDueInstallments(tx, 1, now) }); err != nil {
				t.Fatal(err)
			}
		}
		run("2026-01-30T15:59:59Z")
		saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
		if saved.Posted != 0 {
			t.Fatal("提前入账")
		}
		run("2026-01-30T16:00:00Z")
		run("2026-01-30T16:00:00Z")
		expected := domain.Money(89900)
		if mode == "upfront" {
			expected = 69900
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		run("2026-02-28T16:00:00Z")
		saved = must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
		if saved.Posted != 2 || saved.Rows[2].Status != "pending" {
			t.Fatalf("未按日期补记: %+v", saved)
		}
		var untouched domain.Transaction
		if err := s.db.First(&untouched, draft.(domain.Transaction).ID).Error; err != nil || untouched.Status != "pending" {
			t.Fatal("误入账普通草稿", err)
		}
		run("2026-03-31T00:00:00Z")
		run("2026-03-31T00:00:00Z")
		balances(t, s, map[uint64]domain.Money{a.ID: 69700})
		var count int64
		s.db.Model(&domain.Event{}).Where("operation = ?", "finance.installment.post-due").Count(&count)
		if count != int64(len(plan.Rows)) {
			t.Fatal("重复入账事件", count)
		}
	}
}

// TestInstallmentWorkerWithoutPreset 验证没有周期模板也会在启动时自动补记分期；参数：t 为测试上下文；返回值：无，仅使用临时数据库。
func TestInstallmentWorkerWithoutPreset(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "后台分期", "balance": "1000.00"}).(domain.Account)
	bill := must(t, s, "finance.transaction.create", 0, transactionBody("worker-posting", a.ID, "expense", "100.00")).(domain.Transaction)
	must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "历史分期", Periods: 2, FirstDate: "2000-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last"})
	// 模拟后台启动时已超过分期日期；无参数，返回固定时间。
	s.now = func() time.Time { return time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC) }
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	// 错误回调接收后台错误，返回值无；测试记录任何非取消错误。
	s.RunRecurring(ctx, func(err error) {
		if ctx.Err() == nil {
			t.Error(err)
		}
	})
	saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
	if saved.Posted != 2 {
		t.Fatal("没有模板时未自动入账", saved.Posted)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 90000})
}

// TestInstallmentItemActions 验证单期删除、退款上限、归属隔离及后台不复活；参数：t 为测试上下文；返回值：无，覆盖两种本金计入模式。
func TestInstallmentItemActions(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "单期操作", "balance": "1000.00"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("item-actions", a.ID, "expense", "300.00")).(domain.Transaction)
		plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机分期", Periods: 3, FirstDate: "2000-01-01", Interest: 300, InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode, InterestCreditMode: "upfront", RestoredCredit: 30000}).(domain.InstallmentPlan)
		first, second, third := plan.Rows[0].TransactionID, plan.Rows[1].TransactionID, plan.Rows[2].TransactionID
		row := must(t, s, "finance.transaction.get", first, nil).(domain.Transaction)
		if row.InstallmentName != plan.Name || row.InstallmentPeriods != 3 {
			t.Fatal("详情缺少计划信息")
		}
		for _, op := range []string{"finance.transaction.get", "finance.transaction.delete", "finance.transaction.refund"} {
			if _, err := execute(s, 2, op, first, map[string]any{"requestId": "other-refund", "amount": "1.00", "transactionDate": "2000-04-01"}, "http"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("%s 越权: %v", op, err)
			}
		}
		if _, err := execute(s, 1, "finance.transaction.delete", bill.ID, nil, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("主账单允许删除", err)
		}
		if _, err := execute(s, 1, "finance.transaction.refund", first, map[string]any{"requestId": "pending-refund", "amount": "1.00", "transactionDate": "2000-04-01"}, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("未入账允许退款", err)
		}
		must(t, s, "finance.transaction.update", second, map[string]any{"description": "", "counterparty": "单期修改"})
		must(t, s, "finance.transaction.delete", first, nil)
		must(t, s, "finance.transaction.delete", first, nil)
		expected := domain.Money(100000)
		if mode == "upfront" {
			expected = 80000
		}
		balances(t, s, map[uint64]domain.Money{a.ID: expected})
		accounts := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if accounts[0].InstallmentInterestReserved != 200 || accounts[0].InstallmentCredit != 20000 {
			t.Fatalf("删除后额度错误: %+v", accounts[0])
		}
		// 推进测试时钟后执行自动入账；无参数，返回固定日期。
		s.now = func() time.Time { return time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC) }
		must(t, s, "finance.installment.post-due", 0, nil)
		must(t, s, "finance.installment.post-due", 0, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 79800})
		body := map[string]any{"requestId": "item-refund", "amount": "40.00", "transactionDate": "2000-04-01"}
		refund := must(t, s, "finance.transaction.refund", second, body).(domain.Transaction)
		must(t, s, "finance.transaction.refund", second, body)
		balances(t, s, map[uint64]domain.Money{a.ID: 83800})
		if _, err := execute(s, 1, "finance.transaction.refund", second, map[string]any{"requestId": "excess-refund", "amount": "61.01", "transactionDate": "2000-04-01"}, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("超额退款未拒绝", err)
		}
		must(t, s, "finance.transaction.delete", second, nil)
		must(t, s, "finance.transaction.delete", second, nil)
		must(t, s, "finance.transaction.delete", refund.ID, nil)
		must(t, s, "finance.installment.post-due", 0, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 89900})
		for _, id := range []uint64{first, second, refund.ID} {
			if _, err := execute(s, 1, "finance.transaction.get", id, nil, "http"); !errors.Is(err, ErrNotFound) {
				t.Fatal("已删除流水仍可读取", err)
			}
		}
		saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
		if saved.Posted != 1 || saved.Rows[0].Status != "deleted" || saved.Rows[1].Status != "deleted" || saved.Rows[2].Status != "posted" {
			t.Fatalf("其他期次或删除状态错误: %+v", saved)
		}
		must(t, s, "finance.transaction.refund", third, map[string]any{"requestId": "full-refund", "amount": "101.00", "transactionDate": "2000-04-01"})
		balances(t, s, map[uint64]domain.Money{a.ID: 100000})
		must(t, s, "finance.transaction.delete", third, nil)
		must(t, s, "finance.installment.post-due", 0, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 100000})
		accounts = must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if accounts[0].InstallmentInterestReserved != 0 || accounts[0].InstallmentCredit != 0 {
			t.Fatal("全部删除后仍占用额度")
		}
	}
}
