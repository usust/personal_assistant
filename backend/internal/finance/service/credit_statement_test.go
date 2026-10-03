// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"
	"time"

	domain "personal_assistant_server/internal/finance/model"
)

// TestCreditStatement 验证应还剔除未出账消费、还款退款分配和权限；参数：t 为测试上下文；返回值：无，只访问临时账本。
func TestCreditStatement(t *testing.T) {
	s := fixture(t)
	card := must(t, s, "finance.account.create", 0, map[string]any{"name": "信用卡", "balance": "-1000.00", "billingDay": 20}).(domain.Account)
	cash := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "balance": "2000.00"}).(domain.Account)
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.FixedZone("UTC+8", 28800))
	// 查询回调无参数；返回当前应还摘要，失败终止测试。
	read := func() domain.CreditStatement {
		t.Helper()
		value, err := creditStatement(s.db, 1, card.ID, now)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	body := transactionBody("unbilled-expense", card.ID, "expense", "100.00")
	body["transactionDate"] = "2026-09-21"
	expense := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	statement := read()
	if statement.Month != "2026-09" || statement.StartDate != "2026-08-21" || statement.EndDate != "2026-09-20" || statement.RemainingAmount != 100000 {
		t.Fatalf("账期或未出账扣除错误: %+v", statement)
	}
	body = transactionBody("statement-payment", cash.ID, "transfer", "300.00")
	body["targetAccountId"] = card.ID
	body["transactionDate"] = "2026-09-28"
	payment := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if read().RemainingAmount != 70000 {
		t.Fatal("还款未减少应还")
	}
	must(t, s, "finance.transaction.refund", expense.ID, map[string]any{"requestId": "statement-refund", "amount": "50.00", "transactionDate": "2026-09-28"})
	if read().RemainingAmount != 70000 {
		t.Fatal("未出账退款错误抵扣已出账金额")
	}
	must(t, s, "finance.transaction.delete", payment.ID, nil)
	if read().RemainingAmount != 100000 {
		t.Fatal("删除还款未恢复应还")
	}
	if _, err := creditStatement(s.db, 2, card.ID, now); !errors.Is(err, ErrNotFound) {
		t.Fatal("越权读取账单", err)
	}
	unconfigured, err := creditStatement(s.db, 1, cash.ID, now)
	if err != nil || unconfigured.Configured {
		t.Fatal("未配置账单日时虚构账单")
	}
	// 未完成的月底账期归上个月；短月按实际月末计算。
	card.BillingDay = 31
	if err := s.db.Model(&domain.Account{}).Where("id = ?", card.ID).Updates(map[string]any{"billing_day": 31}).Error; err != nil {
		t.Fatal(err)
	}
	leap, err := creditStatement(s.db, 1, card.ID, time.Date(2028, 3, 1, 0, 0, 0, 0, now.Location()))
	if err != nil || leap.Month != "2028-02" || leap.EndDate != "2028-02-29" || leap.StartDate != "2028-02-01" {
		t.Fatal("闰年账期错误", leap, err)
	}
}

// TestCreditStatementUpfrontInstallment 验证预记本金不作为已出账应还，单期入账后只按真实账期计入；参数：t 为测试上下文；返回值：无。
func TestCreditStatementUpfrontInstallment(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "分期信用卡", "balance": "-1000.00", "billingDay": 20}).(domain.Account)
	body := transactionBody("statement-installment", a.ID, "expense", "300.00")
	body["transactionDate"] = "2026-09-01"
	bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "手机", Periods: 3, FirstDate: "2026-09-10", Interest: 300, InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: "upfront"}).(domain.InstallmentPlan)
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	before, err := creditStatement(s.db, 1, a.ID, now)
	if err != nil || before.RemainingAmount != 100000 {
		t.Fatal("未来预记本金计入应还", before, err)
	}
	must(t, s, "finance.transaction.confirm", plan.Rows[0].TransactionID, nil)
	after, err := creditStatement(s.db, 1, a.ID, now)
	if err != nil || after.RemainingAmount != 110100 {
		t.Fatal("已出账期次未计入应还", after, err)
	}
}

// TestStatementAmounts 验证历史账单不随后续还款变化、未来未出账及跨月边界；参数：t 为测试上下文；返回值：无，仅访问临时数据库。
func TestStatementAmounts(t *testing.T) {
	s := fixture(t)
	card := must(t, s, "finance.account.create", 0, map[string]any{"name": "历史账单", "balance": "-1000.00", "billingDay": 20}).(domain.Account)
	cash := must(t, s, "finance.account.create", 0, map[string]any{"name": "还款账户", "balance": "2000.00"}).(domain.Account)
	body := transactionBody("history-expense", card.ID, "expense", "100.00")
	body["transactionDate"] = "2026-09-21"
	must(t, s, "finance.transaction.create", 0, body)
	body = transactionBody("history-payment", cash.ID, "transfer", "300.00")
	body["targetAccountId"] = card.ID
	body["transactionDate"] = "2026-09-28"
	must(t, s, "finance.transaction.create", 0, body)
	now := time.Date(2026, 9, 29, 0, 0, 0, 0, time.UTC)
	amounts, err := statementAmounts(s.db, 1, card.ID, Filter{StartDate: "2026-08-21", EndDate: "2026-10-20"}, now)
	if err != nil || len(amounts) != 1 || amounts["2026-09-20"] != 100000 {
		t.Fatal("历史账单受后续消费或还款影响", amounts, err)
	}
	if _, err := statementAmounts(s.db, 2, card.ID, Filter{StartDate: "2026-08-21", EndDate: "2026-10-20"}, now); !errors.Is(err, ErrNotFound) {
		t.Fatal("历史账单越权", err)
	}
	if err := s.db.Model(&domain.Account{}).Where("id = ?", card.ID).Updates(map[string]any{"billing_day": 1, "bill_day_inclusive": false}).Error; err != nil {
		t.Fatal(err)
	}
	amounts, err = statementAmounts(s.db, 1, card.ID, Filter{StartDate: "2026-09-01", EndDate: "2026-09-30"}, time.Date(2026, 10, 1, 0, 0, 0, 0, time.FixedZone("UTC+8", 28800)))
	if err != nil || amounts["2026-09-30"] != 80000 {
		t.Fatal("不含当日且账单日为1时漏掉月末", amounts, err)
	}
}
