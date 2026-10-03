// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"

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
