// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"regexp"
)

// 预编译业务字段校验规则。
var categoryIconPattern = regexp.MustCompile(`^[a-z][a-z0-9.]{0,63}$`)

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
