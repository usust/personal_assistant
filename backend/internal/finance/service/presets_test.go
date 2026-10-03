// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestTransferFeeLifecycle 验证转账手续费与余额、统计及冲销；参数 t 为测试上下文；返回值无。
func TestTransferFeeLifecycle(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "转出", "balance": "100.00"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "转入"}).(domain.Account)
	body := transactionBody("transfer-fee-key", a.ID, "transfer", "25.00")
	body["targetAccountId"] = b.ID
	body["fee"] = "1.50"
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	must(t, s, "finance.transaction.create", 0, body)
	balances(t, s, map[uint64]domain.Money{a.ID: 7350, b.ID: 2500})
	raw, _ := json.Marshal(must(t, s, "finance.overview", 0, nil))
	var summary struct{ MonthExpense domain.Money }
	if err := json.Unmarshal(raw, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.MonthExpense != 150 {
		t.Fatalf("fee expense: %s", raw)
	}
	must(t, s, "finance.transaction.void", row.ID, nil)
	must(t, s, "finance.transaction.void", row.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000, b.ID: 0})
	body["requestId"] = "negative-fee-key"
	body["fee"] = "-0.01"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("negative fee: %v", err)
	}
	body["fee"] = "1.00"
	body["type"] = "expense"
	delete(body, "targetAccountId")
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("expense fee: %v", err)
	}
}

// TestRecurringLifecycle 验证补齐、暂停、结束、幂等、权限及删除；参数 t 为测试上下文；返回值无。
func TestRecurringLifecycle(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "balance": "100.00"}).(domain.Account)
	body := map[string]any{"key": "recurring-create-key", "name": "月底账单", "transaction": transactionBody("ignored-key", a.ID, "expense", "5.00"), "frequency": "monthly", "startDate": "2024-01-31", "endDate": "2024-03-31"}
	row := must(t, s, "finance.preset.create", 0, body).(domain.Preset)
	if row.ID == 0 {
		t.Fatal("missing preset id")
	}
	replay := must(t, s, "finance.preset.create", 0, body).(domain.Preset)
	if replay.ID != row.ID {
		t.Fatal("duplicate preset")
	}
	if _, err := execute(s, 2, "finance.preset.update", row.ID, map[string]any{"enabled": false}, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("isolation: %v", err)
	}
	must(t, s, "finance.preset.update", row.ID, map[string]any{"enabled": false})
	must(t, s, "finance.recurring.materialize", 0, nil)
	var count int64
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 0 {
		t.Fatal("paused generated")
	}
	must(t, s, "finance.preset.update", row.ID, map[string]any{"enabled": true})
	must(t, s, "finance.recurring.materialize", 0, nil)
	must(t, s, "finance.recurring.materialize", 0, nil)
	var rows []domain.Transaction
	s.db.Order("transaction_date").Find(&rows)
	if len(rows) != 3 || rows[1].TransactionDate != "2024-02-29" || rows[2].TransactionDate != "2024-03-31" {
		t.Fatalf("dates: %+v", rows)
	}
	for _, item := range rows {
		if item.Status != "pending" || item.Source != "recurring" {
			t.Fatal("not a recurring draft")
		}
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	must(t, s, "finance.transaction.confirm", rows[0].ID, nil)
	must(t, s, "finance.transaction.confirm", rows[0].ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 9500})
	must(t, s, "finance.preset.delete", row.ID, nil)
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 3 {
		t.Fatal("deleted history")
	}
	if nextOccurrence("2025-02-28", "2024-02-29", "yearly") != "2026-02-28" || nextOccurrence("2027-02-28", "2024-02-29", "yearly") != "2028-02-29" {
		t.Fatal("leap year anchor")
	}
}

// TestFeeRollbackAndPresetIsolation 验证手续费溢出全部回滚，以及模板关联权限；参数 t 为测试上下文；返回值无。
func TestFeeRollbackAndPresetIsolation(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "极限账户", "balance": "-1000000000000.00"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "目标"}).(domain.Account)
	body := transactionBody("overflow-fee-key", a.ID, "transfer", "1.00")
	body["targetAccountId"] = b.ID
	body["fee"] = "0.01"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("overflow: %v", err)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: -maxMoney, b.ID: 0})
	var count int64
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 0 {
		t.Fatal("partial transaction")
	}
	preset := map[string]any{"key": "template-isolation", "name": "模板", "transaction": transactionBody("template-key", b.ID, "income", "2.00")}
	if _, err := execute(s, 2, "finance.preset.create", 0, preset, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign account: %v", err)
	}
	row := must(t, s, "finance.preset.create", 0, preset).(domain.Preset)
	must(t, s, "finance.preset.update", row.ID, map[string]any{"name": "新名称", "enabled": false})
	result := must(t, s, "finance.preset.list", 0, nil).([]domain.Preset)
	if len(result) != 1 || result[0].Enabled || result[0].Name != "新名称" || result[0].Transaction.Amount != 200 {
		t.Fatal("PATCH changed unrelated fields")
	}
	if _, err := execute(s, 1, "finance.preset.list", 0, nil, "ai"); !errors.Is(err, ErrInvalid) {
		t.Fatal("AI preset access")
	}
	must(t, s, "finance.recurring.materialize", 0, nil)
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 0 {
		t.Fatal("template generated a transaction")
	}
}

// TestPresetTransactionUpdate 验证模板内容更新与零值清除；参数：t 为测试上下文；返回值：无；验证不创建流水且拒绝越权。
func TestPresetTransactionUpdate(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "模板账户"}).(domain.Account)
	original := transactionBody("preset-edit-original", a.ID, "expense", "10.00")
	original["description"] = "旧备注"
	original["discount"] = "1.00"
	row := must(t, s, "finance.preset.create", 0, map[string]any{"key": "preset-edit", "name": "原模板", "transaction": original}).(domain.Preset)
	changed := transactionBody("preset-edit-change", a.ID, "expense", "8.00")
	changed["description"] = ""
	changed["discount"] = "0.00"
	updated := must(t, s, "finance.preset.update", row.ID, map[string]any{"transaction": changed}).(domain.Preset)
	if updated.Name != row.Name || updated.Transaction.Amount != 800 || updated.Transaction.Description != "" || updated.Transaction.Discount != 0 {
		t.Fatalf("unexpected update: %+v", updated)
	}
	if _, err := execute(s, 2, "finance.preset.update", row.ID, map[string]any{"transaction": changed}, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign update: %v", err)
	}
	var count int64
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 0 {
		t.Fatal("editing preset created transactions")
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 0})
}
