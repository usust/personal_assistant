// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"personal_assistant_server/internal/capability"

	domain "personal_assistant_server/internal/finance/model"
)

// TestCategoryPresentation 验证分类展示字段的持久化与旧客户端兼容；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestCategoryPresentation(t *testing.T) {
	s := fixture(t)
	row := must(t, s, "finance.category.create", 0, map[string]any{"name": "咖啡", "type": "expense", "groupKey": "food", "icon": "cup.and.saucer"}).(domain.Category)
	var saved domain.Category
	if err := s.db.First(&saved, row.ID).Error; err != nil {
		t.Fatal(err)
	}
	if saved.GroupKey != "food" || saved.Icon != "cup.and.saucer" || saved.OwnerID != 1 {
		t.Fatalf("分类展示字段未持久化: %+v", saved)
	}
	legacy := must(t, s, "finance.category.create", 0, map[string]any{"name": "旧客户端分类", "type": "income"}).(domain.Category)
	if legacy.GroupKey != "" || legacy.Icon != "" {
		t.Fatal("旧客户端默认值不兼容")
	}
	for _, body := range []map[string]any{
		{"name": "收入错配", "type": "income", "groupKey": "food"},
		{"name": "未知分组", "type": "expense", "groupKey": "unknown"},
		{"name": "非法图标", "type": "expense", "icon": "../../icon.svg"},
	} {
		if _, err := execute(s, 1, "finance.category.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatalf("应拒绝无效展示字段: %v", err)
		}
	}
}

// TestCategoryPatchFields 验证四个可编辑字段的所有独立及组合更新；参数：t 为测试上下文；返回值：无，检查返回值和数据库原值以防未提交字段被覆盖。
func TestCategoryPatchFields(t *testing.T) {
	keys := []string{"name", "groupKey", "icon", "color"}
	values := []string{"  更新后的咖啡  ", "shopping", "bag.fill", "#123ABC"}
	for mask := 1; mask < 1<<len(keys); mask++ {
		// 子测试回调覆盖一种提交组合；参数：t 为独立测试上下文；返回值：无，仅写临时数据库。
		t.Run(fmt.Sprintf("fields-%02d", mask), func(t *testing.T) {
			s := fixture(t)
			row := must(t, s, "finance.category.create", 0, map[string]any{"name": "原分类", "type": "expense", "groupKey": "food", "icon": "cup.and.saucer", "color": "#654321"}).(domain.Category)
			want := row
			body := map[string]any{}
			for i, key := range keys {
				if mask&(1<<i) == 0 {
					continue
				}
				body[key] = values[i]
				switch key {
				case "name":
					want.Name = strings.TrimSpace(values[i])
				case "groupKey":
					want.GroupKey = values[i]
				case "icon":
					want.Icon = values[i]
				case "color":
					want.Color = values[i]
				}
			}
			got := must(t, s, "finance.category.update", row.ID, body).(domain.Category)
			var saved domain.Category
			if err := s.db.First(&saved, row.ID).Error; err != nil {
				t.Fatal(err)
			}
			if got != want || saved != want {
				t.Fatalf("局部更新覆盖其他字段: 返回 %+v，存储 %+v，预期 %+v", got, saved, want)
			}
		})
	}
}

// TestCategoryPatchClearPresentation 验证空字符串可独立或同时清除分组与图标；参数：t 为测试上下文；返回值：无，空值必须落库且保留未提交字段。
func TestCategoryPatchClearPresentation(t *testing.T) {
	for mask := 1; mask < 4; mask++ {
		// 子测试回调覆盖一种清除组合；参数：t 为独立测试上下文；返回值：无，仅写临时数据库。
		t.Run(fmt.Sprintf("clear-%d", mask), func(t *testing.T) {
			s := fixture(t)
			row := must(t, s, "finance.category.create", 0, map[string]any{"name": "待清除", "type": "income", "groupKey": "salary", "icon": "star", "color": "#123456"}).(domain.Category)
			want := row
			body := map[string]any{}
			if mask&1 != 0 {
				body["groupKey"] = ""
				want.GroupKey = ""
			}
			if mask&2 != 0 {
				body["icon"] = ""
				want.Icon = ""
			}
			got := must(t, s, "finance.category.update", row.ID, body).(domain.Category)
			var saved domain.Category
			if err := s.db.First(&saved, row.ID).Error; err != nil || saved != want || got != want {
				t.Fatalf("清除未落库或覆盖其他字段: 返回 %+v，存储 %+v，错误 %v", got, saved, err)
			}
		})
	}
}

// TestCategoryPatchValidation 验证归属、白名单、展示字段及类型不可变约束；参数：t 为测试上下文；返回值：无，所有失败均不得改变分类或产生更新事件。
func TestCategoryPatchValidation(t *testing.T) {
	s := fixture(t)
	row := must(t, s, "finance.category.create", 0, map[string]any{"name": "原分类", "type": "expense", "groupKey": "food", "icon": "star", "color": "#123456"}).(domain.Category)
	cases := []struct {
		name   string
		body   string
		owner  uint64
		id     uint64
		source string
		want   error
	}{
		{"foreign", `{"name":"越权"}`, 2, row.ID, "http", ErrNotFound},
		{"missing", `{"name":"不存在"}`, 1, row.ID + 1000, "http", ErrNotFound},
		{"zero-id", `{"name":"无ID"}`, 1, 0, "http", ErrNotFound},
		{"ai", `{"name":"AI改名"}`, 1, row.ID, "ai", ErrInvalid},
		{"empty", `{}`, 1, row.ID, "http", ErrInvalid},
		{"null-body", `null`, 1, row.ID, "http", ErrInvalid},
		{"array", `[]`, 1, row.ID, "http", ErrInvalid},
		{"malformed", `{"name":`, 1, row.ID, "http", ErrInvalid},
		{"unknown", `{"name":"不得保存","ownerId":2}`, 1, row.ID, "http", ErrInvalid},
		{"column-name", `{"group_key":"food"}`, 1, row.ID, "http", ErrInvalid},
		{"default-flag", `{"isDefault":true}`, 1, row.ID, "http", ErrInvalid},
		{"name-empty", `{"name":"  "}`, 1, row.ID, "http", ErrInvalid},
		{"name-long", fmt.Sprintf(`{"name":%q}`, strings.Repeat("a", 65)), 1, row.ID, "http", ErrInvalid},
		{"name-null", `{"name":null}`, 1, row.ID, "http", ErrInvalid},
		{"group-null", `{"groupKey":null}`, 1, row.ID, "http", ErrInvalid},
		{"icon-null", `{"icon":null}`, 1, row.ID, "http", ErrInvalid},
		{"color-null", `{"color":null}`, 1, row.ID, "http", ErrInvalid},
		{"type-null", `{"type":null}`, 1, row.ID, "http", ErrInvalid},
		{"name-type", `{"name":1}`, 1, row.ID, "http", ErrInvalid},
		{"group-type", `{"groupKey":false}`, 1, row.ID, "http", ErrInvalid},
		{"icon-type", `{"icon":[]}`, 1, row.ID, "http", ErrInvalid},
		{"color-type", `{"color":123456}`, 1, row.ID, "http", ErrInvalid},
		{"type-change", `{"name":"不得保存","type":"income"}`, 1, row.ID, "http", ErrInvalid},
		{"type-empty", `{"type":""}`, 1, row.ID, "http", ErrInvalid},
		{"group-mismatch", `{"name":"不得保存","groupKey":"salary"}`, 1, row.ID, "http", ErrInvalid},
		{"group-unknown", `{"groupKey":"unknown"}`, 1, row.ID, "http", ErrInvalid},
		{"icon-invalid", `{"name":"不得保存","icon":"../icon"}`, 1, row.ID, "http", ErrInvalid},
		{"color-empty", `{"color":""}`, 1, row.ID, "http", ErrInvalid},
		{"color-invalid", `{"color":"#123"}`, 1, row.ID, "http", ErrInvalid},
	}
	for _, tc := range cases {
		// 子测试回调验证一个非法或越权请求；参数：t 为测试上下文；返回值：无，断言业务错误及数据库无副作用。
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.Execute(context.Background(), capability.Actor{UserID: tc.owner}, "finance.category.update", Input{ID: tc.id, Changes: json.RawMessage(tc.body)}, tc.source)
			if !errors.Is(err, tc.want) {
				t.Fatalf("预期 %v，实际 %v", tc.want, err)
			}
			var saved domain.Category
			if err := s.db.First(&saved, row.ID).Error; err != nil || saved != row {
				t.Fatalf("失败请求改动分类: %+v %v", saved, err)
			}
		})
	}
	var events int64
	if err := s.db.Model(&domain.Event{}).Where("operation = ?", "finance.category.update").Count(&events).Error; err != nil || events != 0 {
		t.Fatalf("失败请求留下更新事件: %d %v", events, err)
	}
}

// TestCategoryPatchNamesAndReferences 验证名称冲突范围及已有流水引用安全；参数：t 为测试上下文；返回值：无，分类 ID、收支类型、余额与历史流水必须保持不变。
func TestCategoryPatchNamesAndReferences(t *testing.T) {
	s := fixture(t)
	account := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "balance": "100"}).(domain.Account)
	row := must(t, s, "finance.category.create", 0, map[string]any{"name": "历史分类", "type": "expense", "groupKey": "food", "icon": "star"}).(domain.Category)
	must(t, s, "finance.category.create", 0, map[string]any{"name": "同类型重名", "type": "expense"})
	must(t, s, "finance.category.create", 0, map[string]any{"name": "跨类型同名", "type": "income"})
	if _, err := execute(s, 2, "finance.category.create", 0, map[string]any{"name": "跨用户同名", "type": "expense"}, "http"); err != nil {
		t.Fatal(err)
	}
	body := transactionBody("category-history-001", account.ID, "expense", "10")
	body["categoryId"] = row.ID
	transaction := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if _, err := execute(s, 1, "finance.category.update", row.ID, map[string]any{"name": "  同类型重名  ", "icon": "bag"}, "http"); !errors.Is(err, ErrConflict) {
		t.Fatalf("未拒绝同类型名称冲突: %v", err)
	}
	var saved domain.Category
	if err := s.db.First(&saved, row.ID).Error; err != nil || saved != row {
		t.Fatalf("名称冲突未原子回滚: %+v %v", saved, err)
	}
	for _, name := range []string{row.Name, "跨类型同名", "跨用户同名"} {
		got := must(t, s, "finance.category.update", row.ID, map[string]any{"name": name, "type": "expense"}).(domain.Category)
		if got.ID != row.ID || got.Type != row.Type || got.Name != name {
			t.Fatalf("合法改名未保留身份: %+v", got)
		}
	}
	// 同类型可重复提交但绝不写入不同类型，已有流水不因分类改名而迁移。
	must(t, s, "finance.category.update", row.ID, map[string]any{"type": "expense"})
	if _, err := execute(s, 1, "finance.category.update", row.ID, map[string]any{"type": "income"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("已关联分类竟允许更改收支类型: %v", err)
	}
	var after domain.Transaction
	if err := s.db.First(&after, transaction.ID).Error; err != nil || after.CategoryID == nil || *after.CategoryID != row.ID || after.Type != transaction.Type || after.Amount != transaction.Amount || after.AccountID != transaction.AccountID || after.Status != transaction.Status {
		t.Fatalf("修改分类破坏历史流水: %+v %v", after, err)
	}
	balances(t, s, map[uint64]domain.Money{account.ID: 9000})
	var event domain.Event
	if err := s.db.Where("operation = ? AND entity_id = ? AND owner_id = ?", "finance.category.update", row.ID, 1).First(&event).Error; err != nil || event.Source != "http" {
		t.Fatalf("未记录分类变更事件: %+v %v", event, err)
	}
}

// TestCategoryPatchCaseInsensitiveName 验证大小写不敏感排序规则下只与其他分类冲突；参数：t 为测试上下文；返回值：无，使用临时 SQLite 表模拟常见 MySQL 排序行为，不访问真实数据库。
func TestCategoryPatchCaseInsensitiveName(t *testing.T) {
	s := fixture(t)
	// 临时分类表为名称设置 NOCASE，使仅改大小写的查询也命中自身。
	if err := s.db.Migrator().DropTable(&domain.Category{}); err != nil {
		t.Fatal(err)
	}
	if err := s.db.Exec(`CREATE TABLE finance_categories_v2 (
		id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, name TEXT COLLATE NOCASE,
		type TEXT, group_key TEXT, icon TEXT, color TEXT, is_default NUMERIC,
		UNIQUE(owner_id, name, type)
	)`).Error; err != nil {
		t.Fatal(err)
	}
	row := must(t, s, "finance.category.create", 0, map[string]any{"name": "Coffee", "type": "expense"}).(domain.Category)
	got := must(t, s, "finance.category.update", row.ID, map[string]any{"name": "coffee"}).(domain.Category)
	if got.ID != row.ID || got.Name != "coffee" {
		t.Fatalf("仅更改大小写与自身冲突: %+v", got)
	}
	other := must(t, s, "finance.category.create", 0, map[string]any{"name": "Tea", "type": "expense"}).(domain.Category)
	if _, err := execute(s, 1, "finance.category.update", other.ID, map[string]any{"name": "COFFEE"}, "http"); !errors.Is(err, ErrConflict) {
		t.Fatalf("大小写变体绕过其他分类重名检查: %v", err)
	}
}

// TestExpandedCategoryPresentation 验证新增分组可以保存且不能用于收入；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestExpandedCategoryPresentation(t *testing.T) {
	s := fixture(t)
	for _, group := range []string{"clothing", "daily", "digital", "beauty", "software", "communication", "car", "sports", "travel", "office", "kids", "insurance"} {
		row := must(t, s, "finance.category.create", 0, map[string]any{"name": group, "type": "expense", "groupKey": group, "icon": "star"}).(domain.Category)
		var saved domain.Category
		if err := s.db.First(&saved, row.ID).Error; err != nil || saved.GroupKey != group {
			t.Fatalf("新增分组未正确保存 %s: %v", group, err)
		}
		if err := validateCategoryPresentation("income", group, "star"); !errors.Is(err, ErrInvalid) {
			t.Fatalf("收入不应允许支出分组 %s: %v", group, err)
		}
	}
}

// TestBuiltinCategories 验证新用户默认可用、老用户补齐和重复读取；参数：t 为测试上下文；返回值：无，失败终止测试，不访问真实用户数据。
func TestBuiltinCategories(t *testing.T) {
	s := fixture(t)
	// 已有同名自定义分类沿用原 ID 和展示字段，保留历史流水引用。
	custom := must(t, s, "finance.category.create", 0, map[string]any{"name": "门诊", "type": "expense", "groupKey": "health", "icon": "star", "color": "#123456"}).(domain.Category)
	rows := must(t, s, "finance.category.list", 0, nil).([]domain.Category)
	if len(rows) != len(builtinCategories) {
		t.Fatalf("默认分类未完整补齐: %d", len(rows))
	}
	ids := map[string]uint64{}
	for _, row := range rows {
		key := row.Type + "|" + row.Name
		if ids[key] != 0 {
			t.Fatalf("重复分类: %s", key)
		}
		ids[key] = row.ID
		if row.Name == "门诊" && (row.ID != custom.ID || row.Icon != "star" || row.Color != "#123456" || row.IsDefault) {
			t.Fatalf("覆盖已有分类: %+v", row)
		}
		if err := validateCategoryPresentation(row.Type, row.GroupKey, row.Icon); err != nil {
			t.Fatal(err)
		}
	}
	if ids["expense|药品"] == 0 || ids["income|年终奖"] == 0 {
		t.Fatal("内置子分类不可用")
	}
	second := must(t, s, "finance.category.list", 0, nil).([]domain.Category)
	if len(second) != len(rows) {
		t.Fatal("重复读取产生新分类")
	}
	for _, row := range second {
		if ids[row.Type+"|"+row.Name] != row.ID {
			t.Fatal("重复读取更换分类 ID")
		}
	}
	other, err := execute(s, 2, "finance.category.list", 0, nil, "http")
	if err != nil {
		t.Fatal(err)
	}
	fresh := other.([]domain.Category)
	if len(fresh) != len(builtinCategories) {
		t.Fatal("未开户用户缺少默认分类")
	}
	for _, row := range fresh {
		if row.OwnerID != 2 || !row.IsDefault || ids[row.Type+"|"+row.Name] == row.ID {
			t.Fatal("用户默认分类未隔离")
		}
	}
}
