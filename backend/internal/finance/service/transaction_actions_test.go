// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestRefundAndDelete 验证部分退款、统计口径、幂等及级联删除；参数：t 为测试上下文；返回值：无，失败终止测试，无真实账本写入。
func TestRefundAndDelete(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包", "balance": "100.00"}).(domain.Account)
	original := must(t, s, "finance.transaction.create", 0, transactionBody("expense-refund-01", a.ID, "expense", "30.00")).(domain.Transaction)
	body := map[string]any{"requestId": "refund-request-01", "amount": "10.00", "transactionDate": original.TransactionDate, "description": "部分退款"}
	refund := must(t, s, "finance.transaction.refund", original.ID, body).(domain.Transaction)
	replay := must(t, s, "finance.transaction.refund", original.ID, body).(domain.Transaction)
	if refund.ID != replay.ID || refund.Amount != -1000 || refund.RefundParentID == nil || *refund.RefundParentID != original.ID {
		t.Fatal("退款关联或幂等错误")
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 8000})
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthExpense != 2000 || summary.MonthIncome != 0 {
		t.Fatal("退款必须冲减支出而非增加收入", summary)
	}
	body["requestId"] = "refund-request-02"
	body["amount"] = "20.01"
	if _, err := execute(s, 1, "finance.transaction.refund", original.ID, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("应拒绝超额退款", err)
	}
	if _, err := execute(s, 2, "finance.transaction.refund", original.ID, body, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatal("应隔离退款权限", err)
	}
	if _, err := execute(s, 1, "finance.transaction.refund", refund.ID, body, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("退款记录不可再次退款", err)
	}
	body["amount"] = "20.00"
	must(t, s, "finance.transaction.refund", original.ID, body)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	must(t, s, "finance.transaction.delete", original.ID, nil)
	must(t, s, "finance.transaction.delete", original.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	rows := must(t, s, "finance.transaction.list", 0, nil).([]domain.Transaction)
	if len(rows) != 0 {
		t.Fatal("删除原支出后应隐藏关联退款", rows)
	}
	if _, err := execute(s, 1, "finance.transaction.update", original.ID, map[string]any{"description": "x"}, "http"); !errors.Is(err, ErrConflict) {
		t.Fatal("已删除流水不应可编辑", err)
	}
	if _, err := execute(s, 1, "finance.transaction.confirm", original.ID, nil, "http"); !errors.Is(err, ErrConflict) {
		t.Fatal("已删除流水不应可重新入账", err)
	}
}

// TestDeleteRefundAndTransfer 验证退款撤销释放额度及转账优惠删除；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestDeleteRefundAndTransfer(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包", "balance": "100.00"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行"}).(domain.Account)
	expense := must(t, s, "finance.transaction.create", 0, transactionBody("expense-refund-11", a.ID, "expense", "30.00")).(domain.Transaction)
	body := map[string]any{"requestId": "refund-request-11", "amount": "30.00", "transactionDate": expense.TransactionDate}
	refund := must(t, s, "finance.transaction.refund", expense.ID, body).(domain.Transaction)
	must(t, s, "finance.transaction.delete", refund.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 7000})
	body["requestId"] = "refund-request-12"
	must(t, s, "finance.transaction.refund", expense.ID, body)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	must(t, s, "finance.transaction.void", expense.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	transferBody := transactionBody("transfer-delete-01", a.ID, "transfer", "20.00")
	transferBody["targetAccountId"] = b.ID
	transferBody["rebate"] = "1.00"
	transferBody["fee"] = "2.00"
	transfer := must(t, s, "finance.transaction.create", 0, transferBody).(domain.Transaction)
	balances(t, s, map[uint64]domain.Money{a.ID: 7900, b.ID: 2000})
	if _, err := execute(s, 2, "finance.transaction.delete", transfer.ID, nil, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatal("删除不应越权", err)
	}
	must(t, s, "finance.transaction.delete", transfer.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000, b.ID: 0})
	if _, err := execute(s, 1, "finance.transaction.delete", expense.ID, nil, "ai"); !errors.Is(err, ErrInvalid) {
		t.Fatal("AI 不得删除流水", err)
	}
}
