// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	domain "personal_assistant_server/internal/finance/model"
)

// rebateChild 读取唯一关联优惠；参数 t 为测试上下文，s 为服务，id 为转账 ID；返回值为优惠流水，缺失或重复则终止测试。
func rebateChild(t *testing.T, s *Service, id uint64) domain.Transaction {
	t.Helper()
	var rows []domain.Transaction
	if err := s.db.Where("rebate_parent_id = ?", id).Find(&rows).Error; err != nil || len(rows) != 1 {
		t.Fatalf("rebate rows: %+v, %v", rows, err)
	}
	return rows[0]
}

// TestRebateLifecycle 验证原账户、转入账户和第三账户返现、手续费、统计及重复操作；参数 t 为测试上下文；返回值无。
func TestRebateLifecycle(t *testing.T) {
	for _, destination := range []string{"default", "target", "other"} {
		// 子测试参数 t 为隔离测试上下文；返回值无；逐种验证本金与返现独立入账。
		t.Run(destination, func(t *testing.T) {
			s := fixture(t)
			a := must(t, s, "finance.account.create", 0, map[string]any{"name": "转出", "balance": "2000.00"}).(domain.Account)
			b := must(t, s, "finance.account.create", 0, map[string]any{"name": "信用卡", "accountType": "bank", "institution": "南京银行（信用卡）", "balance": "-1000.00"}).(domain.Account)
			c := must(t, s, "finance.account.create", 0, map[string]any{"name": "返现账户"}).(domain.Account)
			body := transactionBody("rebate-test-key", a.ID, "transfer", "1000.00")
			body["targetAccountId"], body["fee"], body["rebate"] = b.ID, "2.00", "1.00"
			dest := a.ID
			if destination == "target" {
				dest = b.ID
				body["rebateAccountId"] = dest
			}
			if destination == "other" {
				dest = c.ID
				body["rebateAccountId"] = dest
			}
			row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
			must(t, s, "finance.transaction.create", 0, body)
			must(t, s, "finance.transaction.confirm", row.ID, nil)
			child := rebateChild(t, s, row.ID)
			if row.Amount != 100000 || child.Amount != 100 || child.AccountID != dest || child.Status != "posted" || child.Type != "income" {
				t.Fatalf("incorrect rebate: %+v", child)
			}
			want := map[uint64]domain.Money{a.ID: 99800, b.ID: 0, c.ID: 0}
			want[dest] += 100
			balances(t, s, want)
			raw, _ := json.Marshal(must(t, s, "finance.overview", 0, nil))
			var summary struct{ MonthIncome, MonthExpense domain.Money }
			if err := json.Unmarshal(raw, &summary); err != nil || summary.MonthIncome != 100 || summary.MonthExpense != 200 {
				t.Fatalf("summary: %s %v", raw, err)
			}
			if _, err := execute(s, 1, "finance.transaction.void", child.ID, nil, "http"); !errors.Is(err, ErrInvalid) {
				t.Fatalf("independent void: %v", err)
			}
			must(t, s, "finance.transaction.void", row.ID, nil)
			must(t, s, "finance.transaction.void", row.ID, nil)
			balances(t, s, map[uint64]domain.Money{a.ID: 200000, b.ID: -100000, c.ID: 0})
			if rebateChild(t, s, row.ID).Status != "voided" {
				t.Fatal("rebate not voided")
			}
		})
	}
}

// TestPendingRebate 验证待到账优惠只在确认后入账、跨日日期、权限及原交易作废；参数 t 为测试上下文；返回值无。
func TestPendingRebate(t *testing.T) {
	for _, confirm := range []bool{false, true} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行", "balance": "2000.00"}).(domain.Account)
		b := must(t, s, "finance.account.create", 0, map[string]any{"name": "卡"}).(domain.Account)
		body := transactionBody("pending-rebate-key", a.ID, "transfer", "1000.00")
		body["targetAccountId"], body["rebate"], body["rebatePending"], body["transactionDate"] = b.ID, "1.00", true, "2020-01-01"
		row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
		child := rebateChild(t, s, row.ID)
		if child.Status != "pending" {
			t.Fatal("rebate already posted")
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 100000, b.ID: 100000})
		if _, err := execute(s, 2, "finance.transaction.confirm", child.ID, nil, "http"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("foreign confirmation: %v", err)
		}
		if confirm {
			must(t, s, "finance.transaction.confirm", child.ID, nil)
			must(t, s, "finance.transaction.confirm", child.ID, nil)
			balances(t, s, map[uint64]domain.Money{a.ID: 100100, b.ID: 100000})
			if rebateChild(t, s, row.ID).TransactionDate != time.Now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02") {
				t.Fatal("incorrect receipt date")
			}
		}
		must(t, s, "finance.transaction.void", row.ID, nil)
		balances(t, s, map[uint64]domain.Money{a.ID: 200000, b.ID: 0})
		if _, err := execute(s, 1, "finance.transaction.confirm", child.ID, nil, "http"); !errors.Is(err, ErrConflict) {
			t.Fatalf("voided rebate confirmed: %v", err)
		}
	}
}

// TestRebateValidationAndRollback 验证非法输入、越权、金额溢出均不留下半笔交易；参数 t 为测试上下文；返回值无。
func TestRebateValidationAndRollback(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行", "balance": "2000.00"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "卡"}).(domain.Account)
	c := must(t, s, "finance.account.create", 0, map[string]any{"name": "上限", "balance": "1000000000000.00"}).(domain.Account)
	foreign, err := execute(s, 2, "finance.account.create", 0, map[string]any{"name": "其他用户"}, "http")
	if err != nil {
		t.Fatal(err)
	}
	for _, fields := range []map[string]any{
		{"rebate": "-0.01"}, {"rebate": "0", "rebatePending": true}, {"rebate": "1", "rebateAccountId": 0},
		{"rebate": "1", "type": "expense", "targetAccountId": nil},
		{"rebate": "1", "rebateAccountId": foreign.(domain.Account).ID}, {"rebate": "1", "rebateAccountId": c.ID},
	} {
		body := transactionBody("invalid-rebate-key", a.ID, "transfer", "1000.00")
		body["targetAccountId"] = b.ID
		for k, v := range fields {
			body[k] = v
		}
		if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); err == nil {
			t.Fatalf("accepted %+v", fields)
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 200000, b.ID: 0, c.ID: maxMoney})
		var count int64
		if err := s.db.Model(&domain.Transaction{}).Count(&count).Error; err != nil || count != 0 {
			t.Fatalf("partial ledger: %d %v", count, err)
		}
	}
}

// TestDraftAndRecurringRebate 验证 AI 与周期草稿在确认前不生成收入、确认及重试只生成一次；参数 t 为测试上下文；返回值无。
func TestDraftAndRecurringRebate(t *testing.T) {
	for _, source := range []string{"ai", "recurring"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行", "balance": "100.00"}).(domain.Account)
		b := must(t, s, "finance.account.create", 0, map[string]any{"name": "卡"}).(domain.Account)
		body := transactionBody("draft-rebate-key", a.ID, "transfer", "50.00")
		body["targetAccountId"], body["rebate"] = b.ID, "1.00"
		var row domain.Transaction
		if source == "recurring" {
			date := body["transactionDate"]
			must(t, s, "finance.preset.create", 0, map[string]any{"key": "rebate-preset-key", "name": "还款", "transaction": body, "frequency": "daily", "startDate": date, "endDate": date})
			must(t, s, "finance.recurring.materialize", 0, nil)
			must(t, s, "finance.recurring.materialize", 0, nil)
			if err := s.db.First(&row).Error; err != nil {
				t.Fatal(err)
			}
		} else {
			out, err := execute(s, 1, "finance.transaction.create", 0, body, source)
			if err != nil {
				t.Fatal(err)
			}
			row = out.(domain.Transaction)
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 10000, b.ID: 0})
		must(t, s, "finance.transaction.confirm", row.ID, nil)
		must(t, s, "finance.transaction.confirm", row.ID, nil)
		if rebateChild(t, s, row.ID).Status != "posted" {
			t.Fatal("rebate not posted")
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 5100, b.ID: 5000})
	}
}
