// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// syncTestCommand 编码同步命令；参数：key 为稳定标识，op 为操作，id 为目标，body 为请求对象；返回值：命令，测试固定输入编码失败时 panic。
func syncTestCommand(key, op string, id uint64, body any) SyncCommand {
	raw, err := json.Marshal(body)
	if err != nil {
		panic(err)
	}
	return SyncCommand{OperationID: key, Operation: op, ID: id, Body: raw}
}

// TestSyncReceipts 验证响应丢失后的重放、开户去重、异内容冲突及用户隔离；参数：t 为测试上下文；返回值：无，不连接真实服务。
func TestSyncReceipts(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	command := syncTestCommand("offline-account-001", "finance.account.create", 0, map[string]any{"name": "本机现金", "accountType": "cash", "balance": "100.00"})
	first, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil || string(first) != string(second) {
		t.Fatalf("重放不稳定: %s %s %v", first, second, err)
	}
	var account domain.Account
	if err := json.Unmarshal(first, &account); err != nil {
		t.Fatal(err)
	}
	var count int64
	s.db.Model(&domain.Account{}).Where("owner_id = ?", 1).Count(&count)
	if count != 1 {
		t.Fatalf("重复开户: %d", count)
	}
	changed := command
	changed.Body = json.RawMessage(`{"name":"不同账户","accountType":"cash"}`)
	if _, err := s.SyncExecute(context.Background(), 1, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("未拒绝异内容: %v", err)
	}
	if _, err := s.SyncExecute(context.Background(), 2, command); err != nil {
		t.Fatal(err)
	}
	transaction := syncTestCommand("offline-expense-001", "finance.transaction.create", 0, transactionBody("offline-payment-001", account.ID, "expense", "20.00"))
	for i := 0; i < 3; i++ {
		if _, err := s.SyncExecute(context.Background(), 1, transaction); err != nil {
			t.Fatal(err)
		}
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 8000})
	denied := syncTestCommand("offline-cross-user", "finance.account.update", account.ID, map[string]any{"name": "越权"})
	if _, err := s.SyncExecute(context.Background(), 2, denied); !errors.Is(err, ErrNotFound) {
		t.Fatalf("未隔离身份: %v", err)
	}
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot["accounts"].([]domain.Account)) != 1 || len(snapshot["transactions"].([]domain.Transaction)) != 1 {
		t.Fatalf("快照不完整或混入其他用户: %+v", snapshot)
	}
}

// TestSyncRollbackAndCategoryMapping 验证业务失败不留下回执或余额变化，游客分类可自动映射已有目录；参数：t 为测试上下文；返回值：无。
func TestSyncRollbackAndCategoryMapping(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "accountType": "cash"}).(domain.Account)
	bad := syncTestCommand("offline-invalid-001", "finance.transaction.create", 0, transactionBody("offline-invalid-pay", account.ID, "expense", "-1.00"))
	if _, err := s.SyncExecute(context.Background(), 1, bad); err == nil {
		t.Fatal("非法金额通过")
	}
	var count int64
	s.db.Model(&domain.SyncReceipt{}).Count(&count)
	if count != 0 {
		t.Fatal("失败留下回执")
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 0})
	existing := must(t, s, "finance.category.create", 0, map[string]any{"name": "离线分类", "type": "expense"}).(domain.Category)
	command := syncTestCommand("offline-category-001", "finance.category.create", 0, map[string]any{"name": "离线分类", "type": "expense"})
	data, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	var category domain.Category
	if err := json.Unmarshal(data, &category); err != nil || category.ID != existing.ID {
		t.Fatalf("目录映射失败: %+v %v", category, err)
	}
	forbidden := syncTestCommand("offline-forbidden", "finance.overview", 0, map[string]any{})
	if _, err := s.SyncExecute(context.Background(), 1, forbidden); err == nil {
		t.Fatal("任意操作通过白名单")
	}
}

// TestSnapshotIncludesWebChangesAndTombstones 验证普通 Web 路径产生的资料变化、归档和删除会出现在一致性快照；参数：t 为测试上下文；返回值：无。
func TestSnapshotIncludesWebChangesAndTombstones(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "同名账户", "accountType": "cash", "balance": "100.00"}).(domain.Account)
	must(t, s, "finance.account.create", 0, map[string]any{"name": "同名账户", "accountType": "cash", "balance": "200.00"})
	row := must(t, s, "finance.transaction.create", 0, transactionBody("web-snapshot-payment", a.ID, "expense", "10.00")).(domain.Transaction)
	must(t, s, "finance.transaction.delete", row.ID, map[string]any{})
	must(t, s, "finance.account.update", a.ID, map[string]any{"notes": "Web 修改", "includeInNetWorth": false})
	must(t, s, "finance.account.archive", a.ID, map[string]any{})
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	accounts := snapshot["accounts"].([]domain.Account)
	if len(accounts) != 2 || !accounts[0].Archived || accounts[0].Notes != "Web 修改" || accounts[0].IncludeInNetWorth {
		t.Fatalf("Web 变化遗漏: %+v", accounts)
	}
	transactions := snapshot["transactions"].([]domain.Transaction)
	if len(transactions) != 1 || transactions[0].Status != "deleted" || accounts[0].Balance != 10000 {
		t.Fatalf("删除未同步或余额错误: %+v %+v", transactions, accounts)
	}
}
