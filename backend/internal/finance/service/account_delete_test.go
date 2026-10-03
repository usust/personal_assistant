// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"reflect"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestDeleteAccountPreservesReports 验证删除有余额账户后历史收支与快照不变；参数：t 为临时数据库测试上下文；返回值：无。
func TestDeleteAccountPreservesReports(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "工资卡", "balance": "100"}).(domain.Account)
	must(t, s, "finance.transaction.create", 0, transactionBody("archive-income", a.ID, "income", "50"))
	must(t, s, "finance.transaction.create", 0, transactionBody("archive-expense", a.ID, "expense", "20"))
	before := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	transactions := must(t, s, "finance.transaction.list", 0, nil).([]domain.Transaction)
	var snapshots []domain.Snapshot
	if err := s.db.Where("owner_id = ? AND account_id = ?", 1, a.ID).Order("id").Find(&snapshots).Error; err != nil {
		t.Fatal(err)
	}
	must(t, s, "finance.account.archive", a.ID, nil)
	after := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	// 删除只改变当前资产口径，历史收支报表仍应包含这些已入账记录。
	if before.NetWorth != 13000 || after.NetWorth != 0 || before.MonthIncome != after.MonthIncome || before.MonthExpense != after.MonthExpense || !reflect.DeepEqual(before.CashFlow, after.CashFlow) || !reflect.DeepEqual(before.ExpenseCategories, after.ExpenseCategories) {
		t.Fatalf("删除改变了历史统计：before=%+v after=%+v", before, after)
	}
	if rows := must(t, s, "finance.transaction.list", 0, nil).([]domain.Transaction); !reflect.DeepEqual(transactions, rows) {
		t.Fatal("历史流水发生变化", rows)
	}
	var saved []domain.Snapshot
	if err := s.db.Where("owner_id = ? AND account_id = ?", 1, a.ID).Order("id").Find(&saved).Error; err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(snapshots, saved) {
		t.Fatal("余额快照发生变化", saved)
	}
}

// TestDeleteAccountBalances 验证正、负、零余额账户可软删除；参数：t 为测试上下文；返回值：无；仅操作临时数据库。
func TestDeleteAccountBalances(t *testing.T) {
	for _, opening := range []string{"123.45", "-123.45", "0"} {
		s := fixture(t)
		a := must(t, s, "finance.account.create", 0, map[string]any{"name": "待删除", "balance": opening}).(domain.Account)
		for _, op := range []string{"finance.account.impact", "finance.account.archive"} {
			if _, err := execute(s, 2, op, a.ID, nil, "http"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("越权 %s: %v", op, err)
			}
		}
		impact := must(t, s, "finance.account.archive", a.ID, nil).(map[string]int64)
		if impact["snapshots"] != 1 || impact["transactions"] != 0 || impact["pending"] != 0 {
			t.Fatal(impact)
		}
		saved, err := account(s.db, 1, a.ID, false)
		if err != nil || !saved.Archived || saved.Balance != a.Balance {
			t.Fatal(saved, err)
		}
		rows := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
		if len(rows) != 0 {
			t.Fatal(rows)
		}
		summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
		if summary.NetWorth != 0 {
			t.Fatal(summary)
		}
		if _, err = execute(s, 1, "finance.transaction.create", 0, transactionBody("deleted-new", a.ID, "income", "1"), "http"); !errors.Is(err, ErrNotFound) {
			t.Fatal(err)
		}
	}
}

// TestDeleteAccountHistoryAndPending 验证转账历史保留、待确认阻止删除及冲销不恢复账户；参数：t 为测试上下文；返回值：无。
func TestDeleteAccountHistoryAndPending(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "付款", "balance": "100"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "收款"}).(domain.Account)
	body := transactionBody("delete-transfer", a.ID, "transfer", "20")
	body["targetAccountId"] = b.ID
	tr := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	body["requestId"] = "delete-pending"
	draft, err := execute(s, 1, "finance.transaction.create", 0, body, "ai")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []uint64{a.ID, b.ID} {
		impact := must(t, s, "finance.account.impact", id, nil).(map[string]int64)
		if impact["pending"] != 1 || impact["transactions"] != 2 {
			t.Fatal(impact)
		}
		if _, err = execute(s, 1, "finance.account.archive", id, nil, "http"); !errors.Is(err, ErrConflict) {
			t.Fatal(err)
		}
		saved, err := account(s.db, 1, id, true)
		if err != nil || saved.Archived {
			t.Fatal(saved, err)
		}
	}
	must(t, s, "finance.transaction.void", draft.(domain.Transaction).ID, nil)
	impact := must(t, s, "finance.account.archive", b.ID, nil).(map[string]int64)
	if impact["pending"] != 0 || impact["transactions"] != 2 || impact["snapshots"] != 2 {
		t.Fatal(impact)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 8000, b.ID: 2000})
	rows := must(t, s, "finance.transaction.list", 0, nil).([]domain.Transaction)
	if len(rows) != 2 {
		t.Fatal(rows)
	}
	must(t, s, "finance.transaction.void", tr.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000, b.ID: 0})
	saved, err := account(s.db, 1, b.ID, false)
	if err != nil || !saved.Archived {
		t.Fatal("冲销恢复了已删除账户", saved, err)
	}
}
