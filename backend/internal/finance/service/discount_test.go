// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestExpenseDiscount 验证优惠按实付扣款、统计、退款上限及删除守恒；参数：t 为隔离测试；返回值：无，不接触真实账本。
func TestExpenseDiscount(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包", "balance": "100.00"}).(domain.Account)
	body := transactionBody("discount-expense-001", a.ID, "expense", "10.00")
	body["discount"] = "2.50"
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	replay := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if row.Amount != 750 || row.Discount != 250 || replay.ID != row.ID {
		t.Fatal("实付、优惠或幂等错误", row)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 9250})
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthExpense != 750 || summary.MonthIncome != 0 {
		t.Fatal("优惠不得重复计入收支", summary)
	}
	refund := map[string]any{"requestId": "discount-refund-001", "amount": "7.51", "transactionDate": row.TransactionDate}
	if _, err := execute(s, 1, "finance.transaction.refund", row.ID, refund, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("退款不能超过实付", err)
	}
	refund["amount"] = "7.50"
	must(t, s, "finance.transaction.refund", row.ID, refund)
	must(t, s, "finance.transaction.delete", row.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	for _, discount := range []string{"-1.00", "10.00", "10.01"} {
		body["requestId"] = "invalid-discount-001"
		body["discount"] = discount
		if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("应拒绝无效优惠", discount, err)
		}
	}
	body["type"] = "income"
	body["discount"] = "1.00"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("收入不可使用支出减免", err)
	}
}

// TestRemovedTags 验证标签不再参与新建或编辑；参数：t 为测试上下文；返回值：无，使用备注替代旧标签业务。
func TestRemovedTags(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包"}).(domain.Account)
	body := transactionBody("removed-tags-001", a.ID, "expense", "1.00")
	body["tags"] = "旧标签"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("新建不应再接受标签", err)
	}
	delete(body, "tags")
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if _, err := execute(s, 1, "finance.transaction.update", row.ID, map[string]any{"tags": "旧标签"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("编辑不应再接受标签", err)
	}
}
