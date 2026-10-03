// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestAccountCards 验证多卡脱敏持久化、局部修改和清空；参数：t 为测试上下文；返回值：无，仅使用临时数据库。
func TestAccountCards(t *testing.T) {
	s := fixture(t)
	cards := []map[string]any{{"id": "card-1", "name": "国内卡", "maskedAccountNumber": "6222 0000 0000 5510"}, {"id": "card-2", "name": "国际卡", "maskedAccountNumber": "8826"}}
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "招商信用账户", "accountType": "bank", "cards": cards, "creditLimit": "73000.00", "currentDebt": "5006.95"}).(domain.Account)
	if len(a.Cards) != 2 || a.Cards[0].MaskedAccountNumber != "**** 5510" || a.Cards[1].MaskedAccountNumber != "**** 8826" {
		t.Fatalf("卡片保存错误: %+v", a.Cards)
	}
	a = must(t, s, "finance.account.update", a.ID, map[string]any{"notes": "统一账单"}).(domain.Account)
	if len(a.Cards) != 2 || a.CreditLimit != domain.Money(7300000) || a.Balance != domain.Money(-500695) {
		t.Fatal("普通 PATCH 丢失卡片或改变共享额度")
	}
	for _, bad := range []any{nil, []map[string]any{{"id": "x", "name": "卡", "maskedAccountNumber": "12"}}, []map[string]any{{"id": "x", "name": "卡", "maskedAccountNumber": "1234", "balance": "1"}}, []map[string]any{{"id": "x", "name": "卡", "maskedAccountNumber": "1234"}, {"id": "x", "name": "卡2", "maskedAccountNumber": "5678"}}} {
		if _, err := execute(s, 1, "finance.account.update", a.ID, map[string]any{"cards": bad}, "http"); err == nil {
			t.Fatal("接受非法卡片")
		}
	}
	a = must(t, s, "finance.account.update", a.ID, map[string]any{"cards": []any{}}).(domain.Account)
	if len(a.Cards) != 0 || a.CreditLimit != domain.Money(7300000) || a.Balance != domain.Money(-500695) {
		t.Fatal("清空卡片改变余额或失败")
	}
}
