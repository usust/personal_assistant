// 文件职责：验证分类软删除、墓碑同步及历史引用与新增引用的业务边界。
package service

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// TestCategoryDeleteOwnershipAndAudit 验证分类删除的归属、幂等、审计和历史数据保留；参数：t 为隔离数据库测试上下文；返回值：无，断言失败终止测试。
func TestCategoryDeleteOwnershipAndAudit(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "分类历史账户", "balance": "100"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "待删除分类", "type": "expense", "groupKey": "food", "icon": "star", "color": "#123456"}).(domain.Category)
	body := transactionBody("category-delete-history", account.ID, "expense", "10")
	body["categoryId"] = category.ID
	transaction := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	// 读取持久化后的基线，避免数据库时间精度及位置信息转换造成误报。
	if err := s.db.First(&transaction, transaction.ID).Error; err != nil {
		t.Fatal(err)
	}
	var before []domain.Snapshot
	if err := s.db.Order("id").Find(&before).Error; err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		owner  uint64
		id     uint64
		source string
		want   error
	}{
		{2, category.ID, "http", ErrNotFound},
		{1, category.ID + 100000, "http", ErrNotFound},
		{1, 0, "http", ErrNotFound},
		{1, category.ID, "ai", ErrInvalid},
	} {
		if _, err := execute(s, tc.owner, "finance.category.delete", tc.id, nil, tc.source); !errors.Is(err, tc.want) {
			t.Fatalf("非法删除 owner=%d id=%d source=%s: %v", tc.owner, tc.id, tc.source, err)
		}
	}
	var saved domain.Category
	if err := s.db.First(&saved, category.ID).Error; err != nil || saved != category {
		t.Fatalf("失败请求改动分类: %+v %v", saved, err)
	}
	var events int64
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.delete").Count(&events).Error; err != nil || events != 0 {
		t.Fatalf("失败删除留下审计: %d %v", events, err)
	}
	want := category
	want.Deleted = true
	want.NameVersion = want.ID
	for repeat := 0; repeat < 2; repeat++ {
		got := must(t, s, "finance.category.delete", category.ID, nil).(domain.Category)
		if got != want {
			t.Fatalf("删除或重复删除未返回原分类墓碑: %+v，预期 %+v", got, want)
		}
	}
	if _, err := execute(s, 2, "finance.category.delete", category.ID, nil, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("墓碑泄漏给其他用户: %v", err)
	}
	if err := s.db.First(&saved, category.ID).Error; err != nil || saved != want {
		t.Fatalf("分类被物理删除或资料被覆盖: %+v %v", saved, err)
	}
	// 普通成功调用由外层统一审计；重复删除仍记录请求，但不能重复改变业务数据。
	var audit []domain.Event
	if err := s.db.Where("operation = ?", "finance.category.delete").Order("id").Find(&audit).Error; err != nil || len(audit) != 2 {
		t.Fatalf("成功删除审计数量错误: %+v %v", audit, err)
	}
	for _, event := range audit {
		if event.OwnerID != 1 || event.EntityID != category.ID || event.Source != "http" {
			t.Fatalf("删除审计身份或目标错误: %+v", event)
		}
	}
	var after domain.Transaction
	if err := s.db.First(&after, transaction.ID).Error; err != nil || !reflect.DeepEqual(after, transaction) {
		t.Fatalf("删除分类改动了历史流水: %+v %v", after, err)
	}
	var snapshots []domain.Snapshot
	if err := s.db.Order("id").Find(&snapshots).Error; err != nil || !reflect.DeepEqual(before, snapshots) {
		t.Fatalf("删除分类改动余额快照: %+v %v", snapshots, err)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 9000})
	rows, err := repository.ReadCategories(s.db, 1)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, row := range rows {
		if row.ID == category.ID {
			found++
			if row != want {
				t.Fatalf("ReadCategories 改写分类墓碑: %+v", row)
			}
		}
	}
	if found != 1 {
		t.Fatalf("ReadCategories 丢失分类墓碑: %+v", rows)
	}
	foreign, err := repository.ReadCategories(s.db, 2)
	if err != nil || len(foreign) != 0 {
		t.Fatalf("分类读取跨用户泄漏: %+v %v", foreign, err)
	}
}

// TestCategoryDeleteAuditFailureRollsBack 验证审计失败时分类删除一起回滚；参数：t 为临时 SQLite 测试上下文；返回值：无，触发器只影响本测试数据库。
func TestCategoryDeleteAuditFailureRollsBack(t *testing.T) {
	s := fixture(t)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "审计失败分类", "type": "expense"}).(domain.Category)
	// 模拟审计存储失败，确保删除沿用外层事务，不能先提交墓碑。
	if err := s.db.Exec(`CREATE TRIGGER reject_category_delete_audit BEFORE INSERT ON finance_events_v2
		WHEN NEW.operation = 'finance.category.delete'
		BEGIN SELECT RAISE(ABORT, 'category delete audit unavailable'); END`).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := execute(s, 1, "finance.category.delete", category.ID, nil, "http"); err == nil || !strings.Contains(err.Error(), "category delete audit unavailable") {
		t.Fatalf("未得到预期的审计存储失败: %v", err)
	}
	var saved domain.Category
	if err := s.db.First(&saved, category.ID).Error; err != nil || saved != category {
		t.Fatalf("审计失败未回滚分类删除: %+v %v", saved, err)
	}
	var events int64
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.delete").Count(&events).Error; err != nil || events != 0 {
		t.Fatalf("失败事务留下删除事件: %d %v", events, err)
	}
}

// TestCategoryDeleteBuiltinDoesNotResurrect 验证内置分类和同名自定义分类墓碑不被目录补齐复活；参数：t 为隔离数据库测试上下文；返回值：无，重复列表和同步保留原墓碑，手动重建使用新 ID 且不影响其他用户。
func TestCategoryDeleteBuiltinDoesNotResurrect(t *testing.T) {
	s := fixture(t)
	custom := must(t, s, "finance.category.create", 0, map[string]any{"name": "门诊", "type": "expense", "groupKey": "health", "icon": "star"}).(domain.Category)
	// 同名自定义项在首次补齐前删除，覆盖 ensureCategories 忽略墓碑后重复插入的路径。
	must(t, s, "finance.category.delete", custom.ID, nil)
	rows := must(t, s, "finance.category.list", 0, nil).([]domain.Category)
	var builtin domain.Category
	for _, row := range rows {
		if row.Name == "药品" && row.Type == "expense" {
			builtin = row
		}
	}
	if builtin.ID == 0 || !builtin.IsDefault {
		t.Fatal("缺少内置药品分类")
	}
	must(t, s, "finance.category.delete", builtin.ID, nil)
	custom.Deleted, builtin.Deleted = true, true
	custom.NameVersion, builtin.NameVersion = custom.ID, builtin.ID
	for repeat := 0; repeat < 2; repeat++ {
		listed := must(t, s, "finance.category.list", 0, nil).([]domain.Category)
		snapshot, err := s.SyncSnapshot(context.Background(), 1)
		if err != nil {
			t.Fatal(err)
		}
		for _, categories := range [][]domain.Category{listed, snapshot["categories"].([]domain.Category)} {
			if len(categories) != len(builtinCategories) {
				t.Fatalf("目录补齐新增了墓碑替身: %d，预期 %d", len(categories), len(builtinCategories))
			}
			for _, want := range []domain.Category{custom, builtin} {
				matches := 0
				for _, row := range categories {
					if row.Name == want.Name && row.Type == want.Type {
						matches++
						if row != want {
							t.Fatalf("目录读取复活或替换墓碑: %+v，预期 %+v", row, want)
						}
					}
				}
				if matches != 1 {
					t.Fatalf("分类 %s 墓碑数量错误: %d", want.Name, matches)
				}
			}
		}
	}
	// 目录补齐不得自动复活，用户手动创建则必须得到新的活动分类。
	rebuilt := must(t, s, "finance.category.create", 0, map[string]any{"name": builtin.Name, "type": builtin.Type, "icon": "bag"}).(domain.Category)
	if rebuilt.ID == builtin.ID || rebuilt.Deleted || rebuilt.IsDefault || rebuilt.NameVersion != 0 {
		t.Fatalf("内置墓碑手动重建未生成独立活动分类: %+v", rebuilt)
	}
	listed := must(t, s, "finance.category.list", 0, nil).([]domain.Category)
	if len(listed) != len(builtinCategories)+1 {
		t.Fatalf("手动重建后目录被自动补齐或合并: %d", len(listed))
	}
	var saved domain.Category
	if err := s.db.First(&saved, builtin.ID).Error; err != nil || saved != builtin {
		t.Fatalf("手动重建覆盖内置墓碑: %+v %v", saved, err)
	}
	other, err := execute(s, 2, "finance.category.list", 0, nil, "http")
	if err != nil {
		t.Fatal(err)
	}
	matches := 0
	for _, row := range other.([]domain.Category) {
		if row.Name == builtin.Name && row.Type == builtin.Type {
			matches++
			if row.Deleted || row.OwnerID != 2 || row.ID == builtin.ID {
				t.Fatalf("删除污染其他用户内置目录: %+v", row)
			}
		}
	}
	if matches != 1 {
		t.Fatalf("其他用户缺少可用内置分类: %d", matches)
	}
}

// TestCategoryCreateAfterDeletePreservesHistory 验证同名多代重建、活动名称冲突及历史资料保留；参数：t 为隔离数据库测试上下文；返回值：无，每代新建使用新 ID，失败不改变账本或产生创建审计。
func TestCategoryCreateAfterDeletePreservesHistory(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "重建历史账户", "balance": "100"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "保留名称", "type": "expense", "icon": "star", "color": "#123456"}).(domain.Category)
	body := transactionBody("category-recreate-history", account.ID, "expense", "10")
	body["categoryId"] = category.ID
	transaction := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	// 读取持久化后的基线，避免数据库时间精度及位置信息转换造成误报。
	if err := s.db.First(&transaction, transaction.ID).Error; err != nil {
		t.Fatal(err)
	}
	var before []domain.Snapshot
	if err := s.db.Order("id").Find(&before).Error; err != nil {
		t.Fatal(err)
	}
	deleted := must(t, s, "finance.category.delete", category.ID, nil).(domain.Category)
	rebuilt := must(t, s, "finance.category.create", 0, map[string]any{"name": "  " + category.Name + "  ", "type": "expense", "icon": "bag", "color": "#654321"}).(domain.Category)
	if rebuilt.ID == 0 || rebuilt.ID == category.ID || rebuilt.Deleted || rebuilt.NameVersion != 0 || rebuilt.Name != category.Name || rebuilt.Icon != "bag" || rebuilt.Color != "#654321" {
		t.Fatalf("同名重建未创建独立活动分类: %+v", rebuilt)
	}
	for _, name := range []string{category.Name, "  " + category.Name + "  "} {
		if _, err := execute(s, 1, "finance.category.create", 0, map[string]any{"name": name, "type": "expense"}, "http"); !errors.Is(err, ErrConflict) {
			t.Fatalf("活动同名分类未冲突: %v", err)
		}
	}
	secondDeleted := must(t, s, "finance.category.delete", rebuilt.ID, nil).(domain.Category)
	third := must(t, s, "finance.category.create", 0, map[string]any{"name": category.Name, "type": "expense", "icon": "leaf"}).(domain.Category)
	if third.ID == 0 || third.ID == category.ID || third.ID == rebuilt.ID || third.Deleted || third.NameVersion != 0 {
		t.Fatalf("第二次同名重建复用旧身份: %+v", third)
	}
	// 重复删除旧代不能删除或重命名当前代，所有墓碑保留创建时的展示资料。
	for _, want := range []domain.Category{deleted, secondDeleted} {
		if want.NameVersion != want.ID || !want.Deleted {
			t.Fatalf("墓碑未释放活动名称: %+v", want)
		}
		got := must(t, s, "finance.category.delete", want.ID, nil).(domain.Category)
		var saved domain.Category
		if err := s.db.First(&saved, want.ID).Error; err != nil || saved != want || got != want {
			t.Fatalf("重建或重复删除覆盖旧墓碑: %+v %+v %v", got, saved, err)
		}
	}
	income := must(t, s, "finance.category.create", 0, map[string]any{"name": category.Name, "type": "income"}).(domain.Category)
	other, err := execute(s, 2, "finance.category.create", 0, map[string]any{"name": category.Name, "type": "expense"}, "http")
	if err != nil || income.ID == category.ID || income.Deleted {
		t.Fatalf("名称错误占用其他类型或用户: %+v %v", income, err)
	}
	if row := other.(domain.Category); row.ID == category.ID || row.OwnerID != 2 || row.Deleted {
		t.Fatalf("其他用户未得到独立分类: %+v", row)
	}
	var savedTransaction domain.Transaction
	if err := s.db.First(&savedTransaction, transaction.ID).Error; err != nil || !reflect.DeepEqual(savedTransaction, transaction) {
		t.Fatalf("重建迁移了历史流水分类: %+v %v", savedTransaction, err)
	}
	var after []domain.Snapshot
	if err := s.db.Order("id").Find(&after).Error; err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("重建改动余额快照: %+v %v", after, err)
	}
	var count int64
	if err := s.db.Model(&domain.Category{}).Where("owner_id = ? AND type = ? AND name = ?", 1, "expense", category.Name).Count(&count).Error; err != nil || count != 3 {
		t.Fatalf("未保留两代墓碑及当前活动分类: %d %v", count, err)
	}
	if err := repository.CountCategoryByName(s.db, 1, category.Name, category.Type, &count); err != nil || count != 1 {
		t.Fatalf("活动分类计数包含墓碑: %d %v", count, err)
	}
	if err := s.db.Model(&domain.Event{}).Where("owner_id = ? AND operation = ?", 1, "finance.category.create").Count(&count).Error; err != nil || count != 4 {
		t.Fatalf("失败重名请求留下创建事件: %d %v", count, err)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 9000})
}

// TestCategoryDeleteRepairsLegacyVersion 验证重复删除补齐旧墓碑的名称版本；参数：t 为隔离数据库测试上下文；返回值：无，资料不变且补齐后允许全新 ID 重建。
func TestCategoryDeleteRepairsLegacyVersion(t *testing.T) {
	s := fixture(t)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "旧墓碑", "type": "expense", "icon": "star"}).(domain.Category)
	// 模拟启动迁移前的旧删除记录，活动名称仍被版本 0 占用。
	if err := repository.UpdateCategory(s.db, 1, category.ID, map[string]any{"deleted": true}); err != nil {
		t.Fatal(err)
	}
	want := category
	want.Deleted, want.NameVersion = true, category.ID
	for repeat := 0; repeat < 2; repeat++ {
		got := must(t, s, "finance.category.delete", category.ID, nil).(domain.Category)
		if got != want {
			t.Fatalf("旧墓碑版本未幂等补齐: %+v", got)
		}
	}
	rebuilt := must(t, s, "finance.category.create", 0, map[string]any{"name": category.Name, "type": category.Type}).(domain.Category)
	if rebuilt.ID == category.ID || rebuilt.Deleted || rebuilt.NameVersion != 0 {
		t.Fatalf("旧墓碑版本补齐后仍不能独立重建: %+v", rebuilt)
	}
}

// TestCategoryDeletePreservesExistingTransactionActions 验证旧流水编辑、草稿确认和退款可沿用原墓碑分类；参数：t 为测试上下文；返回值：无，金额变化正确且引用和墓碑保持不变。
func TestCategoryDeletePreservesExistingTransactionActions(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "旧流水账户", "balance": "100"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "旧流水分类", "type": "expense"}).(domain.Category)
	body := transactionBody("category-old-posted", account.ID, "expense", "20")
	body["categoryId"] = category.ID
	posted := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	draftBody := transactionBody("category-old-draft", account.ID, "expense", "10")
	draftBody["categoryId"] = category.ID
	out, err := execute(s, 1, "finance.transaction.create", 0, draftBody, "ai")
	if err != nil {
		t.Fatal(err)
	}
	draft := out.(domain.Transaction)
	if draft.Status != "pending" {
		t.Fatalf("前置草稿已入账: %+v", draft)
	}
	deleted := must(t, s, "finance.category.delete", category.ID, nil).(domain.Category)
	// 分别覆盖未提交 categoryId 与显式沿用原 ID 的编辑路径，财务编辑仍须正常重算余额。
	updated := must(t, s, "finance.transaction.update", posted.ID, map[string]any{"description": "删除分类后修改备注"}).(domain.Transaction)
	if updated.CategoryID == nil || *updated.CategoryID != category.ID || updated.Description != "删除分类后修改备注" {
		t.Fatalf("备注编辑丢失原分类: %+v", updated)
	}
	updated = must(t, s, "finance.transaction.update", posted.ID, map[string]any{"categoryId": category.ID, "amount": "25"}).(domain.Transaction)
	if updated.CategoryID == nil || *updated.CategoryID != category.ID || updated.Amount != 2500 {
		t.Fatalf("财务编辑拒绝或丢失原墓碑分类: %+v", updated)
	}
	updatedDraft := must(t, s, "finance.transaction.update", draft.ID, map[string]any{"categoryId": category.ID, "amount": "12"}).(domain.Transaction)
	if updatedDraft.Status != "pending" || updatedDraft.Amount != 1200 || updatedDraft.CategoryID == nil || *updatedDraft.CategoryID != category.ID {
		t.Fatalf("草稿编辑错误: %+v", updatedDraft)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 7500})
	for repeat := 0; repeat < 2; repeat++ {
		confirmed := must(t, s, "finance.transaction.confirm", draft.ID, nil).(domain.Transaction)
		if confirmed.Status != "posted" || confirmed.CategoryID == nil || *confirmed.CategoryID != category.ID {
			t.Fatalf("原分类删除阻断草稿确认: %+v", confirmed)
		}
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 6300})
	refundBody := map[string]any{"requestId": "category-old-refund", "amount": "5", "transactionDate": posted.TransactionDate, "description": "历史分类退款"}
	refund := must(t, s, "finance.transaction.refund", posted.ID, refundBody).(domain.Transaction)
	replay := must(t, s, "finance.transaction.refund", posted.ID, refundBody).(domain.Transaction)
	if refund.ID != replay.ID || refund.CategoryID == nil || *refund.CategoryID != category.ID || refund.RefundParentID == nil || *refund.RefundParentID != posted.ID || refund.Amount != -500 || refund.Status != "posted" {
		t.Fatalf("退款未沿用墓碑分类或重复入账: %+v %+v", refund, replay)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 6800})
	var saved domain.Category
	if err := s.db.First(&saved, category.ID).Error; err != nil || saved != deleted {
		t.Fatalf("旧流水操作复活了分类: %+v %v", saved, err)
	}
}

// TestCategoryDeleteRejectsNewReferences 验证新流水、新模板、新转分期及改选其他墓碑被拒绝；参数：t 为隔离测试上下文；返回值：无，失败操作不改变账本、模板、快照或审计。
func TestCategoryDeleteRejectsNewReferences(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "禁止新引用账户", "balance": "100"}).(domain.Account)
	original := must(t, s, "finance.category.create", 0, map[string]any{"name": "原有分类", "type": "expense"}).(domain.Category)
	other := must(t, s, "finance.category.create", 0, map[string]any{"name": "其他墓碑", "type": "expense"}).(domain.Category)
	body := transactionBody("category-new-reference-old", account.ID, "expense", "20")
	body["categoryId"] = original.ID
	posted := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	preset := must(t, s, "finance.preset.create", 0, map[string]any{"key": "category-existing-template", "name": "旧模板", "transaction": body}).(domain.Preset)
	must(t, s, "finance.category.delete", original.ID, nil)
	must(t, s, "finance.category.delete", other.ID, nil)
	newBody := transactionBody("category-new-reference-denied", account.ID, "expense", "3")
	newBody["categoryId"] = original.ID
	var beforeTransactions []domain.Transaction
	var beforePresets []domain.Preset
	var beforeSnapshots []domain.Snapshot
	var beforeEvents []domain.Event
	if err := s.db.Order("id").Find(&beforeTransactions).Error; err != nil {
		t.Fatal(err)
	}
	if err := s.db.Order("id").Find(&beforePresets).Error; err != nil {
		t.Fatal(err)
	}
	if err := s.db.Order("id").Find(&beforeSnapshots).Error; err != nil {
		t.Fatal(err)
	}
	if err := s.db.Order("id").Find(&beforeEvents).Error; err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		op     string
		id     uint64
		body   any
		source string
	}{
		{"new-http-transaction", "finance.transaction.create", 0, newBody, "http"},
		{"new-ai-draft", "finance.transaction.create", 0, newBody, "ai"},
		{"select-other-tombstone", "finance.transaction.update", posted.ID, map[string]any{"categoryId": other.ID, "amount": "30"}, "http"},
		{"select-other-tombstone-metadata", "finance.transaction.update", posted.ID, map[string]any{"categoryId": other.ID, "description": "改选其他墓碑"}, "http"},
		{"new-template", "finance.preset.create", 0, map[string]any{"key": "category-new-template", "name": "新模板", "transaction": newBody}, "http"},
		{"new-recurring-template", "finance.preset.create", 0, map[string]any{"key": "category-new-recurring", "name": "新周期", "transaction": newBody, "frequency": "monthly", "startDate": "2099-01-01"}, "http"},
		{"template-select-tombstone", "finance.preset.update", preset.ID, map[string]any{"transaction": newBody}, "http"},
		{"new-installment", "finance.installment.create", posted.ID, domain.InstallmentTerms{Name: "禁止新转分期", Periods: 3, FirstDate: "2099-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last"}, "http"},
		{"installment-select-tombstone", "finance.installment.create", posted.ID, domain.InstallmentTerms{Name: "禁止分期改选墓碑", Periods: 3, FirstDate: "2099-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last", CategoryID: &other.ID}, "http"},
	} {
		// 子测试回调验证一种新增引用入口；参数：t 为测试上下文；返回值：无，必须返回 ErrInvalid。
		t.Run(tc.name, func(t *testing.T) {
			if _, err := execute(s, 1, tc.op, tc.id, tc.body, tc.source); !errors.Is(err, ErrInvalid) {
				t.Fatalf("墓碑被新增引用 %s: %v", tc.op, err)
			}
		})
	}
	var transactions []domain.Transaction
	var presets []domain.Preset
	var snapshots []domain.Snapshot
	var events []domain.Event
	if err := s.db.Order("id").Find(&transactions).Error; err != nil || !reflect.DeepEqual(beforeTransactions, transactions) {
		t.Fatalf("拒绝新引用后流水被改写或生成分期: %+v %v", transactions, err)
	}
	if err := s.db.Order("id").Find(&presets).Error; err != nil || !reflect.DeepEqual(beforePresets, presets) {
		t.Fatalf("拒绝新引用后模板发生变化: %+v %v", presets, err)
	}
	if err := s.db.Order("id").Find(&snapshots).Error; err != nil || !reflect.DeepEqual(beforeSnapshots, snapshots) {
		t.Fatalf("拒绝新引用后余额快照发生变化: %+v %v", snapshots, err)
	}
	if err := s.db.Order("id").Find(&events).Error; err != nil || !reflect.DeepEqual(beforeEvents, events) {
		t.Fatalf("失败新增引用留下审计: %+v %v", events, err)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 8000})
}

// TestCategoryDeleteExistingInstallmentStillPosts 验证既有分期在分类删除后仍按期入账且快照可读取；参数：t 为测试上下文；返回值：无，覆盖摊销与预记本金模式，重复快照不能重复扣款。
func TestCategoryDeleteExistingInstallmentStillPosts(t *testing.T) {
	for _, mode := range []string{"spread", "upfront"} {
		// 子测试回调覆盖一种本金模式；参数：t 为独立数据库测试上下文；返回值：无，显式推进服务时钟。
		t.Run(mode, func(t *testing.T) {
			s := fixture(t)
			installmentClock(s, "2026-09-20")
			account := must(t, s, "finance.account.create", 0, map[string]any{"name": "旧分期账户", "balance": "1000"}).(domain.Account)
			category := must(t, s, "finance.category.create", 0, map[string]any{"name": "旧分期分类", "type": "expense"}).(domain.Category)
			body := transactionBody("category-installment-existing", account.ID, "expense", "300")
			body["categoryId"], body["transactionDate"] = category.ID, "2026-09-20"
			bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
			plan := must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "既有分期", Periods: 3, FirstDate: "2026-09-21", InterestMode: "spread", Rounding: "round", Remainder: "last", DebtMode: mode}).(domain.InstallmentPlan)
			if len(plan.Rows) != 3 || plan.Posted != 0 {
				t.Fatalf("前置分期计划错误: %+v", plan)
			}
			must(t, s, "finance.category.delete", category.ID, nil)
			installmentClock(s, "2026-09-28")
			for repeat := 0; repeat < 2; repeat++ {
				snapshot, err := s.SyncSnapshot(context.Background(), 1)
				if err != nil {
					t.Fatalf("分类墓碑阻断分期补记或快照: %v", err)
				}
				found := 0
				for _, row := range snapshot["transactions"].([]domain.Transaction) {
					if row.InstallmentParentID == nil || *row.InstallmentParentID != bill.ID {
						continue
					}
					found++
					wantStatus := "pending"
					if row.ID == plan.Rows[0].TransactionID {
						wantStatus = "posted"
					}
					if row.Status != wantStatus || row.CategoryID == nil || *row.CategoryID != category.ID {
						t.Fatalf("旧分期未保留分类或入账状态错误: %+v", row)
					}
				}
				if found != 3 {
					t.Fatalf("快照丢失既有分期子流水: %d", found)
				}
			}
			wantBalance := domain.Money(90000)
			if mode == "upfront" {
				wantBalance = 70000
			}
			balances(t, s, map[uint64]domain.Money{account.ID: wantBalance})
			var events int64
			if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.installment.post-due").Count(&events).Error; err != nil || events != 1 {
				t.Fatalf("旧分类分期重复补记: %d %v", events, err)
			}
			var saved domain.Category
			if err := s.db.First(&saved, category.ID).Error; err != nil || !saved.Deleted {
				t.Fatalf("分期补记复活分类: %+v %v", saved, err)
			}
		})
	}
}

// TestCategoryDeleteInstallmentUpdateReferences 验证分期更新仅允许沿用原墓碑或改选有效分类；参数：t 为隔离测试上下文；返回值：无，失败不得改写主单及子单，未提交分类也可更新资料。
func TestCategoryDeleteInstallmentUpdateReferences(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "分期修改账户", "balance": "100"}).(domain.Account)
	original := must(t, s, "finance.category.create", 0, map[string]any{"name": "分期原分类", "type": "expense"}).(domain.Category)
	other := must(t, s, "finance.category.create", 0, map[string]any{"name": "分期其他墓碑", "type": "expense"}).(domain.Category)
	active := must(t, s, "finance.category.create", 0, map[string]any{"name": "分期可用分类", "type": "expense"}).(domain.Category)
	body := transactionBody("category-installment-update", account.ID, "expense", "30")
	body["categoryId"] = original.ID
	bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	must(t, s, "finance.installment.create", bill.ID, domain.InstallmentTerms{Name: "分期修改", Periods: 3, FirstDate: "2099-01-01", InterestMode: "spread", Rounding: "round", Remainder: "last"})
	must(t, s, "finance.category.delete", original.ID, nil)
	must(t, s, "finance.category.delete", other.ID, nil)
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"description": "原分类已删除"})
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"categoryId": original.ID})
	var before []domain.Transaction
	if err := s.db.Order("id").Find(&before).Error; err != nil {
		t.Fatal(err)
	}
	for _, row := range before {
		if row.CategoryID == nil || *row.CategoryID != original.ID || row.Description != "原分类已删除" {
			t.Fatalf("沿用原墓碑时主单或子单资料错误: %+v", row)
		}
	}
	if _, err := execute(s, 1, "finance.installment.update", bill.ID, map[string]any{"categoryId": other.ID, "name": "不得落库"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("分期改选其他墓碑未被拒绝: %v", err)
	}
	var after []domain.Transaction
	if err := s.db.Order("id").Find(&after).Error; err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("失败改选修改了主单或子单: %+v %v", after, err)
	}
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"categoryId": active.ID})
	if err := s.db.Order("id").Find(&after).Error; err != nil {
		t.Fatal(err)
	}
	for _, row := range after {
		if row.CategoryID == nil || *row.CategoryID != active.ID {
			t.Fatalf("分期不能改选有效分类: %+v", row)
		}
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 10000})
}

// TestCategoryDeleteRecurringStopsWithLastError 验证周期模板遇到分类墓碑停止生成并留下错误；参数：t 为测试上下文；返回值：无，快照仍成功且不推进周期、不产生流水或生成事件。
func TestCategoryDeleteRecurringStopsWithLastError(t *testing.T) {
	s := fixture(t)
	installmentClock(s, "2026-09-20")
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "周期账户", "balance": "100"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "周期旧分类", "type": "expense"}).(domain.Category)
	body := transactionBody("category-recurring-body", account.ID, "expense", "5")
	body["categoryId"] = category.ID
	preset := must(t, s, "finance.preset.create", 0, map[string]any{"key": "category-recurring-existing", "name": "已有周期", "transaction": body, "frequency": "daily", "startDate": "2026-09-21", "endDate": "2026-09-30"}).(domain.Preset)
	must(t, s, "finance.category.delete", category.ID, nil)
	installmentClock(s, "2026-09-28")
	for repeat := 0; repeat < 2; repeat++ {
		snapshot, err := s.SyncSnapshot(context.Background(), 1)
		if err != nil {
			t.Fatalf("周期分类不可用导致整个快照失败: %v", err)
		}
		rows := snapshot["presets"].([]domain.Preset)
		if len(rows) != 1 || rows[0].ID != preset.ID || rows[0].LastError == "" || !strings.Contains(rows[0].LastError, "分类") || rows[0].NextDate != preset.NextDate || !reflect.DeepEqual(rows[0].Transaction, preset.Transaction) {
			t.Fatalf("周期未保留错误、进度或原分类: %+v", rows)
		}
		if rows := snapshot["transactions"].([]domain.Transaction); len(rows) != 0 {
			t.Fatalf("墓碑周期仍生成草稿: %+v", rows)
		}
	}
	var events int64
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.recurring.generate").Count(&events).Error; err != nil || events != 0 {
		t.Fatalf("墓碑周期留下生成审计: %d %v", events, err)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 10000})
}

// TestCategoryDeleteRebateUsesNewCategory 验证自动还款优惠不重建墓碑，手动同名重建后使用新 ID；参数：t 为测试上下文；返回值：无，旧引用保留，新返现正常入账，重复创建不重复生成分类。
func TestCategoryDeleteRebateUsesNewCategory(t *testing.T) {
	s := fixture(t)
	from := must(t, s, "finance.account.create", 0, map[string]any{"name": "还款账户", "balance": "100"}).(domain.Account)
	to := must(t, s, "finance.account.create", 0, map[string]any{"name": "收款账户"}).(domain.Account)
	body := transactionBody("category-rebate-first", from.ID, "transfer", "10")
	body["targetAccountId"], body["rebate"] = to.ID, "1"
	first := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	oldChild := rebateChild(t, s, first.ID)
	if oldChild.CategoryID == nil {
		t.Fatal("前置返现未创建还款优惠分类")
	}
	category := must(t, s, "finance.category.delete", *oldChild.CategoryID, nil).(domain.Category)
	if category.Name != "还款优惠" || category.Type != "income" || !category.Deleted {
		t.Fatalf("前置分类错误: %+v", category)
	}
	body["requestId"] = "category-rebate-second"
	second := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	must(t, s, "finance.transaction.create", 0, body)
	child := rebateChild(t, s, second.ID)
	if child.CategoryID != nil || child.Status != "posted" || child.Amount != 100 || child.AccountID != from.ID {
		t.Fatalf("删除自动分类后返现应无分类正常入账: %+v", child)
	}
	var count int64
	if err := s.db.Model(&domain.Category{}).Where("owner_id = ? AND name = ? AND type = ?", 1, "还款优惠", "income").Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("自动返现不应重新生成已删除分类: %d %v", count, err)
	}
	rebuilt := must(t, s, "finance.category.create", 0, map[string]any{"name": "还款优惠", "type": "income"}).(domain.Category)
	body["requestId"] = "category-rebate-third"
	third := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	newChild := rebateChild(t, s, third.ID)
	if newChild.CategoryID == nil || *newChild.CategoryID != rebuilt.ID || rebuilt.ID == category.ID {
		t.Fatalf("手动重建后新返现应使用新分类: %+v", newChild)
	}
	if saved := rebateChild(t, s, first.ID); !reflect.DeepEqual(saved, oldChild) {
		t.Fatalf("新返现清除了旧返现分类: %+v", saved)
	}
	must(t, s, "finance.category.list", 0, nil)
	var rows []domain.Category
	if err := s.db.Where("owner_id = ? AND name = ? AND type = ?", 1, "还款优惠", "income").Order("id").Find(&rows).Error; err != nil || len(rows) != 2 || rows[0] != category {
		t.Fatalf("自动返现或目录补齐覆盖旧墓碑或生成重复分类: %+v %v", rows, err)
	}
	if rows[1] != rebuilt || rows[1].ID != *newChild.CategoryID || rows[1].Deleted || rows[1].NameVersion != 0 {
		t.Fatalf("新返现分类不是手动重建的活动项: %+v", rows[1])
	}
	balances(t, s, map[uint64]domain.Money{from.ID: 7300, to.ID: 3000})
}
