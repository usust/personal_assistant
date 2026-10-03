// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestTransactionEdit 验证部分财务修改、转账、零优惠、退款限制与失败回滚；参数：t 为隔离测试上下文；返回值：无，断言失败终止测试。
func TestTransactionEdit(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "accountType": "cash", "balance": "100"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行卡", "accountType": "bank", "balance": "100"}).(domain.Account)
	row := must(t, s, "finance.transaction.create", 0, transactionBody("edit-payment-001", a.ID, "expense", "20")).(domain.Transaction)
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"amount": "30", "discount": "5", "transactionTime": "12:34"}).(domain.Transaction)
	if row.Amount != 2500 || row.Discount != 500 || row.TransactionTime != "12:34" {
		t.Fatal(row)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"accountId": b.ID, "type": "transfer", "targetAccountId": a.ID, "discount": "0", "fee": "2", "rebate": "3", "rebateAccountId": b.ID}).(domain.Transaction)
	var accounts []domain.Account
	if err := s.db.Order("id").Find(&accounts).Error; err != nil {
		t.Fatal(err)
	}
	if accounts[0].Balance != 13000 || accounts[1].Balance != 7100 {
		t.Fatal(accounts)
	}
	// 重复同值修改不得累加扣款或生成第二笔优惠。
	must(t, s, "finance.transaction.update", row.ID, map[string]any{"fee": "2"})
	must(t, s, "finance.transaction.update", row.ID, map[string]any{"rebate": "0", "rebateAccountId": nil, "rebatePending": false})
	if err := s.db.Order("id").Find(&accounts).Error; err != nil {
		t.Fatal(err)
	}
	if accounts[1].Balance != 6800 {
		t.Fatal(accounts)
	}
	if _, err := execute(s, 1, "finance.transaction.update", row.ID, map[string]any{"targetAccountId": b.ID}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if err := s.db.Order("id").Find(&accounts).Error; err != nil {
		t.Fatal(err)
	}
	if accounts[0].Balance != 13000 || accounts[1].Balance != 6800 {
		t.Fatal("校验失败未回滚", accounts)
	}
	expense := must(t, s, "finance.transaction.create", 0, transactionBody("edit-refund-001", a.ID, "expense", "10")).(domain.Transaction)
	must(t, s, "finance.transaction.refund", expense.ID, map[string]any{"requestId": "edit-refund-child", "amount": "5", "transactionDate": expense.TransactionDate, "description": ""})
	if _, err := execute(s, 1, "finance.transaction.update", expense.ID, map[string]any{"amount": "4"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	must(t, s, "finance.transaction.update", expense.ID, map[string]any{"amount": "7"})
	if _, err := execute(s, 2, "finance.transaction.update", expense.ID, map[string]any{"amount": "8"}, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}
