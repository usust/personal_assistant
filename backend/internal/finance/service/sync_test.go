// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
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

// TestSyncCategoryPatch 验证分类更新通过同步白名单并复用权限、校验与幂等回执；参数：t 为测试上下文；返回值：无，失败无回执，重放不得覆盖后续修改或重复记录事件。
func TestSyncCategoryPatch(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	row := must(t, s, "finance.category.create", 0, map[string]any{"name": "离线原分类", "type": "expense", "groupKey": "food", "icon": "star", "color": "#654321"}).(domain.Category)
	must(t, s, "finance.category.create", 0, map[string]any{"name": "已存在分类", "type": "expense"})
	command := syncTestCommand("offline-category-patch-001", "finance.category.update", row.ID, map[string]any{"name": "离线新分类", "groupKey": "", "icon": "", "color": "#123ABC"})
	first, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	var got domain.Category
	if err := json.Unmarshal(first, &got); err != nil || got.ID != row.ID || got.Name != "离线新分类" || got.GroupKey != "" || got.Icon != "" || got.Color != "#123ABC" || got.Type != row.Type {
		t.Fatalf("同步分类更新结果错误: %+v %v", got, err)
	}
	later := must(t, s, "finance.category.update", row.ID, map[string]any{"color": "#ABCDEF"}).(domain.Category)
	// 同一正文换键序仍命中原回执，响应保持原样且不再次执行 PATCH。
	command.Body = json.RawMessage(`{"color":"#123ABC","icon":"","groupKey":"","name":"离线新分类"}`)
	replayed, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil || string(first) != string(replayed) {
		t.Fatalf("分类重放响应不稳定: %s %s %v", first, replayed, err)
	}
	changed := command
	changed.Body = json.RawMessage(`{"name":"不同正文"}`)
	if _, err := s.SyncExecute(context.Background(), 1, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("同键异内容未冲突: %v", err)
	}
	changed = command
	changed.ID++
	if _, err := s.SyncExecute(context.Background(), 1, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("同键不同目标未冲突: %v", err)
	}
	if _, err := s.SyncExecute(context.Background(), 2, command); !errors.Is(err, ErrNotFound) {
		t.Fatalf("分类同步未隔离归属: %v", err)
	}
	for _, tc := range []struct {
		key  string
		body map[string]any
		want error
	}{
		{"offline-category-bad-type", map[string]any{"name": "不得保存", "type": "income"}, ErrInvalid},
		{"offline-category-duplicate", map[string]any{"name": "已存在分类", "icon": "bag"}, ErrConflict},
		{"offline-category-bad-group", map[string]any{"groupKey": "salary"}, ErrInvalid},
	} {
		if _, err := s.SyncExecute(context.Background(), 1, syncTestCommand(tc.key, "finance.category.update", row.ID, tc.body)); !errors.Is(err, tc.want) {
			t.Fatalf("同步更新未复用业务校验 %s: %v", tc.key, err)
		}
	}
	var saved domain.Category
	if err := s.db.First(&saved, row.ID).Error; err != nil || saved != later {
		t.Fatalf("重放或失败请求覆盖了后续更改: %+v %v", saved, err)
	}
	var receipts, events int64
	if err := s.db.Model(&domain.SyncReceipt{}).Count(&receipts).Error; err != nil || receipts != 1 {
		t.Fatalf("重复或失败请求留下回执: %d %v", receipts, err)
	}
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.update").Count(&events).Error; err != nil || events != 2 {
		t.Fatalf("分类更新事件数量错误: %d %v", events, err)
	}
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	for _, category := range snapshot["categories"].([]domain.Category) {
		if category.ID == row.ID {
			if category != later {
				t.Fatalf("同步快照遗漏分类更新: %+v", category)
			}
			return
		}
	}
	t.Fatal("同步快照缺少更新后的分类")
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

// TestSyncCategoryDelete 验证删除白名单、归属、回执重放、独立重试及墓碑快照；参数：t 为临时数据库测试上下文；返回值：无，回执重放不重复审计，失败请求不保存回执。
func TestSyncCategoryDelete(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "同步待删除", "type": "expense", "icon": "star", "color": "#123456"}).(domain.Category)
	command := syncTestCommand("offline-category-delete-001", "finance.category.delete", category.ID, map[string]any{})
	first, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatalf("分类删除未通过同步白名单: %v", err)
	}
	var deleted domain.Category
	if err := json.Unmarshal(first, &deleted); err != nil || deleted.ID != category.ID || !deleted.Deleted || deleted.Name != category.Name || deleted.Type != category.Type || deleted.Icon != category.Icon || deleted.Color != category.Color {
		t.Fatalf("同步删除未返回完整墓碑: %s %v", first, err)
	}
	for repeat := 0; repeat < 2; repeat++ {
		replayed, err := s.SyncExecute(context.Background(), 1, command)
		if err != nil || string(replayed) != string(first) {
			t.Fatalf("删除回执重放不稳定: %s %s %v", first, replayed, err)
		}
	}
	var count int64
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.delete").Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("相同删除回执重复审计: %d %v", count, err)
	}
	// 不同同步键代表另一次成功请求，业务保持幂等，外层仍应独立记录回执和审计。
	retry := command
	retry.OperationID = "offline-category-delete-002"
	second, err := s.SyncExecute(context.Background(), 1, retry)
	if err != nil || string(second) != string(first) {
		t.Fatalf("新键重复删除不幂等: %s %s %v", first, second, err)
	}
	changed := command
	changed.ID++
	if _, err := s.SyncExecute(context.Background(), 1, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("同键改变删除目标未冲突: %v", err)
	}
	changed = command
	changed.Body = json.RawMessage(`{"different":true}`)
	if _, err := s.SyncExecute(context.Background(), 1, changed); !errors.Is(err, ErrConflict) {
		t.Fatalf("同键改变删除正文未冲突: %v", err)
	}
	if _, err := s.SyncExecute(context.Background(), 2, command); !errors.Is(err, ErrNotFound) {
		t.Fatalf("其他用户获得墓碑或复用了他人回执: %v", err)
	}
	missing := syncTestCommand("offline-category-delete-missing", "finance.category.delete", category.ID+100000, map[string]any{})
	if _, err := s.SyncExecute(context.Background(), 1, missing); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的分类删除未返回不存在: %v", err)
	}
	var receipts []domain.SyncReceipt
	if err := s.db.Order("owner_id, operation_id").Find(&receipts).Error; err != nil || len(receipts) != 2 {
		t.Fatalf("失败删除留下回执或重放生成重复回执: %+v %v", receipts, err)
	}
	for _, receipt := range receipts {
		if receipt.OwnerID != 1 || receipt.Result != string(first) {
			t.Fatalf("删除回执身份或响应错误: %+v", receipt)
		}
	}
	var events []domain.Event
	if err := s.db.Where("operation = ?", "finance.category.delete").Order("id").Find(&events).Error; err != nil || len(events) != 2 {
		t.Fatalf("同步删除审计数量错误: %+v %v", events, err)
	}
	for _, event := range events {
		if event.OwnerID != 1 || event.EntityID != category.ID || event.Source != "http" {
			t.Fatalf("同步删除审计目标错误: %+v", event)
		}
	}
	category.Deleted = true
	category.NameVersion = category.ID
	var saved domain.Category
	if err := s.db.First(&saved, category.ID).Error; err != nil || saved != category {
		t.Fatalf("重复同步删除改写分类资料: %+v %v", saved, err)
	}
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, row := range snapshot["categories"].([]domain.Category) {
		if row.ID == category.ID {
			found++
			if row != category {
				t.Fatalf("同步快照复活或覆盖墓碑: %+v", row)
			}
		}
	}
	if found != 1 {
		t.Fatalf("同步快照丢失或重复分类墓碑: %d", found)
	}
}

// TestSyncCategoryCreateAfterDelete 验证同步创建排除墓碑且回执始终保留原 ID；参数：t 为隔离数据库测试上下文；返回值：无，新操作仅合并活动分类，删除后新建独立分类，重放不改账本或重复审计。
func TestSyncCategoryCreateAfterDelete(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "游客墓碑分类", "type": "expense", "icon": "star"}).(domain.Category)
	deleted := must(t, s, "finance.category.delete", category.ID, nil).(domain.Category)
	command := syncTestCommand("offline-category-tombstone-create", "finance.category.create", 0, map[string]any{"name": "  游客墓碑分类  ", "type": "expense", "icon": "bag"})
	first, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	var rebuilt domain.Category
	if err := json.Unmarshal(first, &rebuilt); err != nil || rebuilt.ID == 0 || rebuilt.ID == category.ID || rebuilt.Deleted || rebuilt.Icon != "bag" {
		t.Fatalf("同步新操作合并了墓碑: %s %v", first, err)
	}
	if strings.Contains(string(first), "nameVersion") || strings.Contains(string(first), "name_version") || strings.Contains(string(first), "NameVersion") {
		t.Fatalf("同步泄漏内部名称版本: %s", first)
	}
	for repeat := 0; repeat < 2; repeat++ {
		replayed, err := s.SyncExecute(context.Background(), 1, command)
		if err != nil || string(replayed) != string(first) {
			t.Fatalf("新建重放未保留同 ID: %s %s %v", first, replayed, err)
		}
	}
	// 新操作遇到活动同名项仍执行目录去重，不覆盖现有图标。
	mappedCommand := command
	mappedCommand.OperationID = "offline-category-active-map"
	mappedCommand.Body = json.RawMessage(`{"name":"游客墓碑分类","type":"expense","icon":"leaf"}`)
	data, err := s.SyncExecute(context.Background(), 1, mappedCommand)
	if err != nil || string(data) != string(first) {
		t.Fatalf("新操作未仅复用活动分类: %s %v", data, err)
	}
	secondDeleted := must(t, s, "finance.category.delete", rebuilt.ID, nil).(domain.Category)
	thirdCommand := mappedCommand
	thirdCommand.OperationID = "offline-category-third-create"
	thirdData, err := s.SyncExecute(context.Background(), 1, thirdCommand)
	if err != nil {
		t.Fatal(err)
	}
	var third domain.Category
	if err := json.Unmarshal(thirdData, &third); err != nil || third.ID == 0 || third.ID == category.ID || third.ID == rebuilt.ID || third.Deleted || third.Icon != "leaf" {
		t.Fatalf("多代同步重建复用了旧墓碑: %s %v", thirdData, err)
	}
	// 原创建和映射回执必须保留第二代 ID，即使它已删除且第三代已存在。
	for _, original := range []SyncCommand{command, mappedCommand} {
		replayed, err := s.SyncExecute(context.Background(), 1, original)
		if err != nil || string(replayed) != string(first) {
			t.Fatalf("墓碑之后重放改变了原操作 ID: %s %v", replayed, err)
		}
	}
	if replayed, err := s.SyncExecute(context.Background(), 1, thirdCommand); err != nil || string(replayed) != string(thirdData) {
		t.Fatalf("第三代重放不稳定: %s %v", replayed, err)
	}
	for _, want := range []domain.Category{deleted, secondDeleted} {
		var saved domain.Category
		if err := s.db.First(&saved, want.ID).Error; err != nil || saved != want {
			t.Fatalf("同步重建覆盖墓碑资料: %+v %v", saved, err)
		}
	}
	var count int64
	if err := s.db.Model(&domain.SyncReceipt{}).Count(&count).Error; err != nil || count != 3 {
		t.Fatalf("重放重复保存回执: %d %v", count, err)
	}
	if err := s.db.Model(&domain.Category{}).Where("owner_id = ? AND name = ? AND type = ?", 1, category.Name, category.Type).Count(&count).Error; err != nil || count != 3 {
		t.Fatalf("同步未保留两代墓碑和活动项: %d %v", count, err)
	}
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.create").Count(&count).Error; err != nil || count != 3 {
		t.Fatalf("同步重放或活动映射留下创建审计: %d %v", count, err)
	}
}

// TestSyncCategoryTombstoneTransactionReferences 验证同步新流水拒绝墓碑但旧草稿可编辑和确认；参数：t 为测试上下文；返回值：无，失败不留回执，成功重放不重复入账。
func TestSyncCategoryTombstoneTransactionReferences(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "离线旧草稿账户", "balance": "100"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "离线旧草稿分类", "type": "expense"}).(domain.Category)
	body := transactionBody("sync-category-existing-draft", account.ID, "expense", "10")
	body["categoryId"] = category.ID
	out, err := execute(s, 1, "finance.transaction.create", 0, body, "ai")
	if err != nil {
		t.Fatal(err)
	}
	draft := out.(domain.Transaction)
	must(t, s, "finance.category.delete", category.ID, nil)
	body["requestId"] = "sync-category-denied-new"
	command := syncTestCommand("offline-tombstone-new-transaction", "finance.transaction.create", 0, body)
	if _, err := s.SyncExecute(context.Background(), 1, command); !errors.Is(err, ErrInvalid) {
		t.Fatalf("同步新交易引用墓碑: %v", err)
	}
	var count int64
	if err := s.db.Model(&domain.SyncReceipt{}).Count(&count).Error; err != nil || count != 0 {
		t.Fatalf("新交易校验失败留下回执: %d %v", count, err)
	}
	patch := syncTestCommand("offline-tombstone-old-edit", "finance.transaction.update", draft.ID, map[string]any{"categoryId": category.ID, "amount": "12", "description": "离线修改"})
	if _, err := s.SyncExecute(context.Background(), 1, patch); err != nil {
		t.Fatalf("同步旧草稿不能沿用原分类: %v", err)
	}
	confirm := syncTestCommand("offline-tombstone-old-confirm", "finance.transaction.confirm", draft.ID, map[string]any{})
	for repeat := 0; repeat < 2; repeat++ {
		data, err := s.SyncExecute(context.Background(), 1, confirm)
		if err != nil {
			t.Fatal(err)
		}
		var row domain.Transaction
		if err := json.Unmarshal(data, &row); err != nil || row.Status != "posted" || row.Amount != 1200 || row.CategoryID == nil || *row.CategoryID != category.ID || row.Description != "离线修改" {
			t.Fatalf("同步确认丢失原分类或编辑字段: %s %v", data, err)
		}
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 8800})
	if err := s.db.Model(&domain.Transaction{}).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("同步失败或重放产生额外流水: %d %v", count, err)
	}
	if err := s.db.Model(&domain.SyncReceipt{}).Count(&count).Error; err != nil || count != 2 {
		t.Fatalf("旧草稿同步回执数量错误: %d %v", count, err)
	}
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.transaction.confirm").Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("确认回执重放产生额外审计: %d %v", count, err)
	}
}
