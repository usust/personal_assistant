// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// 预编译业务字段校验规则。
var categoryIconPattern = regexp.MustCompile(`^[a-z][a-z0-9.]{0,63}$`)

// updateCategory 更新个人分类资料；参数：db 为持有用户锁的事务，owner 为可信用户身份，in 含分类 ID 及部分字段对象；返回值：持久化后的分类或归属、校验、冲突、数据库错误；已删除分类拒绝编辑，失败由调用方回滚，收支类型和历史流水引用保持不变。
func (s *Service) updateCategory(db *gorm.DB, owner uint64, in Input) (domain.Category, error) {
	// 先限定归属，其他用户的分类与不存在的分类统一返回未找到。
	row, err := repository.ReadCategory(db, owner, in.ID)
	if err != nil {
		return row, missing(err)
	}
	// 墓碑保留历史名称与展示资料，不能通过编辑隐式恢复。
	if row.Deleted {
		return row, deletedCategoryConflict()
	}
	var body map[string]json.RawMessage
	if err := Decode(in.Changes, &body); err != nil {
		return row, err
	}
	if len(body) == 0 {
		return row, Invalid("至少提交一个字段")
	}
	fields := map[string]any{}
	group, icon := row.GroupKey, row.Icon
	for key, raw := range body {
		// 仅接受固定字段；type 只作兼容校验，不进入持久化更新集合。
		switch key {
		case "name", "groupKey", "icon", "color", "type":
		default:
			return row, Invalid("不允许更新分类字段: " + key)
		}
		var value string
		if string(raw) == "null" || json.Unmarshal(raw, &value) != nil {
			return row, Invalid("分类字段必须为字符串")
		}
		switch key {
		case "name":
			value = strings.TrimSpace(value)
			if !validText(value, 64, true) {
				return row, Invalid("分类名称无效")
			}
			// 仅与当前用户的同类型活动分类冲突；按 ID 排除自身，兼容数据库大小写不敏感的排序规则。
			if value != row.Name {
				var existing domain.Category
				err := repository.FindCategoryByName(db, owner, value, row.Type, &existing)
				if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
					return row, err
				}
				if err == nil && existing.ID != row.ID {
					return row, ErrConflict
				}
			}
			fields["name"] = value
		case "groupKey":
			group = value
			fields["group_key"] = value
		case "icon":
			icon = value
			fields["icon"] = value
		case "color":
			if !colorPattern.MatchString(value) {
				return row, Invalid("颜色必须为 #RRGGBB")
			}
			fields["color"] = value
		case "type":
			if value != row.Type {
				return row, Invalid("不能修改已有分类的收支类型")
			}
		}
	}
	// 合并未提交的展示字段后沿用创建校验；空分组和空图标允许显式清除。
	if err := validateCategoryPresentation(row.Type, group, icon); err != nil {
		return row, err
	}
	if len(fields) == 0 {
		return row, nil
	}
	// 所有校验完成后只写入白名单 map，避免零值丢失或覆盖未提交字段。
	if err := repository.UpdateCategory(db, owner, row.ID, fields); err != nil {
		return row, err
	}
	return repository.ReadCategory(db, owner, row.ID)
}

// validateCategoryPresentation 校验分类展示字段；参数：kind 为收支类型，group 为可省略的一级分类键，icon 为可省略的 SF Symbols 名称；返回值：校验错误或 nil，无副作用。
func validateCategoryPresentation(kind, group, icon string) error {
	// 分组按收支白名单校验，旧客户端省略时继续兼容原有分类。
	groups := map[string]string{
		"food": "expense", "transport": "expense", "shopping": "expense", "home": "expense",
		"utilities": "expense", "health": "expense", "leisure": "expense", "education": "expense",
		"social": "expense", "family": "expense", "pets": "expense", "other-expense": "expense",
		"clothing": "expense", "daily": "expense", "digital": "expense", "beauty": "expense",
		"software": "expense", "communication": "expense", "car": "expense", "sports": "expense",
		"travel": "expense", "office": "expense", "kids": "expense", "insurance": "expense",
		"salary": "income", "side-job": "income", "investment": "income", "gifts": "income", "other-income": "income",
	}
	if group != "" && (groups[group] == "" || groups[group] != kind) {
		// 拒绝本次操作：一级分类与收支类型不匹配。
		return Invalid("一级分类与收支类型不匹配")
	}
	// 检查字段是否符合约定格式。
	if icon != "" && !categoryIconPattern.MatchString(icon) {
		// 拒绝本次操作：分类图标无效。
		return Invalid("分类图标无效")
	}
	return nil
}
