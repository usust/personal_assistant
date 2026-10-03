// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"reflect"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestCreditAccountLedger 验证 iOS 信用账户沿用通用账本后的负债、消费与还款；参数：t 为测试上下文；返回值：无；仅写临时 SQLite，失败终止测试。
func TestCreditAccountLedger(t *testing.T) {
	s := fixture(t)
	cash := must(t, s, "finance.account.create", 0, map[string]any{"name": "还款银行卡", "accountType": "bank", "balance": "1000.00"}).(domain.Account)
	card := must(t, s, "finance.account.create", 0, map[string]any{"name": "信用卡", "accountType": "bank", "institution": "南京银行（信用卡）", "balance": "-200.00"}).(domain.Account)
	platform := must(t, s, "finance.account.create", 0, map[string]any{"name": "花呗", "accountType": "other", "institution": "花呗", "balance": "-50.00"}).(domain.Account)
	initial := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if initial.TotalAssets != 100000 || initial.TotalLiabilities != 25000 || initial.NetWorth != 75000 {
		t.Fatalf("欠款统计错误：%+v", initial)
	}
	must(t, s, "finance.transaction.create", 0, transactionBody("credit-expense-001", card.ID, "expense", "30.00"))
	// 还款是资产账户转入负债账户，债务减少而总净资产不变，也不产生第二笔消费。
	repayment := transactionBody("credit-repay-001", cash.ID, "transfer", "100.00")
	repayment["targetAccountId"] = card.ID
	must(t, s, "finance.transaction.create", 0, repayment)
	balances(t, s, map[uint64]domain.Money{cash.ID: 90000, card.ID: -13000, platform.ID: -5000})
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthExpense != 3000 || summary.MonthIncome != 0 || summary.NetWorth != 72000 || summary.TotalLiabilities != 18000 {
		t.Fatalf("信用还款重复计支出或余额符号错误：%+v", summary)
	}
}

// TestSameBankCreatesSeparateAccounts 验证同一银行可创建多个独立账户；参数：t 为测试上下文；返回值：无；仅写临时数据库，防止目录选择被误当成更新已有账户。
func TestSameBankCreatesSeparateAccounts(t *testing.T) {
	s := fixture(t)
	body := map[string]any{"name": "南京银行", "accountType": "bank", "institution": "南京银行股份有限公司", "balance": "0.00", "currency": "CNY", "includeInNetWorth": true, "maskedAccountNumber": "", "notes": ""}
	first := must(t, s, "finance.account.create", 0, body).(domain.Account)
	second := must(t, s, "finance.account.create", 0, body).(domain.Account)
	if first.ID == 0 || second.ID == 0 || first.ID == second.ID {
		t.Fatalf("同一银行未生成独立账户：%d / %d", first.ID, second.ID)
	}
	balances(t, s, map[uint64]domain.Money{first.ID: 0, second.ID: 0})
}

// TestCreditSettingsPatch 验证信用设置、欠款转换及零值独立更新；参数：t 为测试上下文；返回值：无；临时数据库失败时终止测试。
func TestCreditSettingsPatch(t *testing.T) {
	s := fixture(t)
	card := must(t, s, "finance.account.create", 0, map[string]any{
		"name": "招商信用卡", "accountType": "bank", "institution": "招商银行（信用卡）",
		"currentDebt": "3240.38", "creditLimit": "73000.00", "billingDay": 20, "repaymentDay": 7,
		"billDayInclusive": true, "selectable": true, "reminderDays": 7, "reminderTime": "10:00",
	}).(domain.Account)
	if card.Balance != -324038 || card.CreditLimit != 7300000 || card.BillingDay != 20 || card.RepaymentDay != 7 || card.ReminderDays != 7 {
		t.Fatalf("信用字段未正确保存：%+v", card)
	}
	updated := must(t, s, "finance.account.update", card.ID, map[string]any{"creditLimit": "0.00", "billDayInclusive": false, "selectable": false, "reminderDays": 0}).(domain.Account)
	if updated.CreditLimit != 0 || updated.BillDayInclusive || updated.Selectable || updated.ReminderDays != 0 || updated.ReminderTime != "10:00" || updated.Balance != card.Balance || updated.BillingDay != 20 || updated.RepaymentDay != 7 {
		t.Fatalf("零值丢失或未提交字段被覆盖：%+v", updated)
	}
	// 校准债务不伪造收入；溢缴款通过负欠款转换为正资产余额，并保留快照。
	updated = must(t, s, "finance.account.update", card.ID, map[string]any{"currentDebt": "-10.25"}).(domain.Account)
	if updated.Balance != 1025 {
		t.Fatalf("溢缴款转换错误：%v", updated.Balance)
	}
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthIncome != 0 || summary.MonthExpense != 0 {
		t.Fatalf("校准错误计入收支：%+v", summary)
	}
	impact := must(t, s, "finance.account.impact", card.ID, nil).(map[string]int64)
	if impact["snapshots"] != 2 {
		t.Fatalf("缺少校准快照：%v", impact)
	}
	for _, body := range []map[string]any{
		{"creditLimit": "-1.00"}, {"billingDay": 32}, {"repaymentDay": -1}, {"reminderDays": 2}, {"reminderTime": "25:00"}, {"selectable": nil}, {"currentDebt": "1.00", "balance": "1.00"},
	} {
		if _, err := execute(s, 1, "finance.account.update", card.ID, body, "http"); err == nil {
			t.Fatalf("非法字段通过：%v", body)
		}
	}
	if _, err := execute(s, 2, "finance.account.update", card.ID, map[string]any{"currentDebt": "0.00"}, "http"); err == nil {
		t.Fatal("跨用户修改欠款成功")
	}
}

// TestCreditDebtWithPendingDraft 验证待确认草稿不阻止欠款校准，后续确认仍按原金额记账；参数：t 为测试上下文；返回值：无；仅操作临时数据库。
func TestCreditDebtWithPendingDraft(t *testing.T) {
	s := fixture(t)
	card := must(t, s, "finance.account.create", 0, map[string]any{"name": "信用卡", "currentDebt": "20.00"}).(domain.Account)
	result, err := execute(s, 1, "finance.transaction.create", 0, transactionBody("pending-credit-001", card.ID, "expense", "5.00"), "ai")
	if err != nil {
		t.Fatal(err)
	}
	draft := result.(domain.Transaction)
	must(t, s, "finance.account.update", card.ID, map[string]any{"currentDebt": "30.00"})
	must(t, s, "finance.account.update", card.ID, map[string]any{"billingDay": 12})
	balances(t, s, map[uint64]domain.Money{card.ID: -3000})
	saved := must(t, s, "finance.transaction.get", draft.ID, nil).(domain.Transaction)
	if saved.Status != "pending" || saved.Amount != draft.Amount {
		t.Fatalf("校准改动待确认流水：%+v", saved)
	}
	must(t, s, "finance.transaction.confirm", draft.ID, nil)
	balances(t, s, map[uint64]domain.Money{card.ID: -3500})
}

// TestCreditDebtWithInstallments 验证两种分期模式下欠款可独立修改和清零，计划、收支和未来入账保持正常；参数：t 为测试上下文；返回值：无；仅操作临时数据库。
func TestCreditDebtWithInstallments(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		s := fixture(t)
		installmentClock(s, "2026-09-28")
		card := must(t, s, "finance.account.create", 0, map[string]any{"name": "信用卡", "institution": "招商银行（信用卡）", "currentDebt": "20.00", "creditLimit": "73000.00"}).(domain.Account)
		bill := must(t, s, "finance.transaction.create", 0, transactionBody("credit-installment", card.ID, "expense", "300.00")).(domain.Transaction)
		plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "消费分期", Periods: 3, FirstDate: "2026-10-01", InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}).(domain.InstallmentPlan)
		before := must(t, s, "finance.overview", 0, nil).(domain.Overview)
		initialImpact := must(t, s, "finance.account.impact", card.ID, nil).(map[string]int64)
		for _, debt := range []string{"5555.00", "0.00"} {
			updated := must(t, s, "finance.account.update", card.ID, map[string]any{"currentDebt": debt}).(domain.Account)
			expected := domain.Money(-555500)
			if debt == "0.00" {
				expected = 0
			}
			if updated.Balance != expected || updated.CreditLimit != card.CreditLimit || updated.Institution != card.Institution {
				t.Fatalf("%s 校准错误：%+v", mode, updated)
			}
			saved := must(t, s, "finance.installment.plan", bill.ID, nil).(domain.InstallmentPlan)
			if !reflect.DeepEqual(saved, plan) {
				t.Fatalf("%s 校准改动分期计划：%+v", mode, saved)
			}
		}
		after := must(t, s, "finance.overview", 0, nil).(domain.Overview)
		if after.MonthIncome != before.MonthIncome || after.MonthExpense != before.MonthExpense {
			t.Fatalf("%s 校准错误计入收支", mode)
		}
		impact := must(t, s, "finance.account.impact", card.ID, nil).(map[string]int64)
		if impact["snapshots"] != initialImpact["snapshots"]+2 {
			t.Fatalf("缺少校准快照：%v", impact)
		}
		installmentClock(s, "2026-10-01")
		must(t, s, "finance.account.list", 0, nil)
		expected := domain.Money(-10000)
		if mode == "upfront" {
			expected = 0
		}
		balances(t, s, map[uint64]domain.Money{card.ID: expected})
	}
}
