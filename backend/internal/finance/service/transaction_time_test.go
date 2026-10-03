// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestTransactionTime 验证时分存储、午夜、旧客户端兼容和非法输入；参数：t 为测试上下文；返回值：无，仅写入隔离测试数据库。
func TestTransactionTime(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包", "balance": "100.00"}).(domain.Account)
	body := transactionBody("time-expense-001", a.ID, "expense", "10.00")
	body["transactionTime"] = "00:00"
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	var stored domain.Transaction
	if err := s.db.First(&stored, row.ID).Error; err != nil || stored.TransactionTime != "00:00" {
		t.Fatal("午夜时间未持久化", stored, err)
	}
	replay := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if replay.ID != row.ID {
		t.Fatal("时间字段破坏幂等")
	}
	refund := must(t, s, "finance.transaction.refund", row.ID, map[string]any{"requestId": "time-refund-001", "amount": "1.00", "transactionDate": row.TransactionDate, "transactionTime": "18:42"}).(domain.Transaction)
	if refund.TransactionTime != "18:42" {
		t.Fatal("退款时间未保存")
	}
	old := must(t, s, "finance.transaction.create", 0, transactionBody("time-legacy-001", a.ID, "expense", "1.00")).(domain.Transaction)
	if old.TransactionTime != "" {
		t.Fatal("缺失时间不得伪造")
	}
	for _, value := range []string{"24:00", "12:60", "9:30", "12:30:00", "invalid"} {
		body["requestId"] = "time-invalid-001"
		body["transactionTime"] = value
		if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); err == nil {
			t.Fatalf("接受非法时间 %q", value)
		}
	}
}

// TestTransactionTimeOrdering 验证补录顺序不影响交易时间排序及分页；参数：t 为测试上下文；返回值：无，仅写入隔离测试数据库。
func TestTransactionTimeOrdering(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "排序钱包", "balance": "100.00"}).(domain.Account)
	ids := []uint64{}
	for i, clock := range []string{"12:08", "11:56", "09:57", "12:08", "", "00:00"} {
		body := transactionBody("ordering-test-"+string(rune('a'+i)), a.ID, "expense", "1.00")
		body["transactionTime"] = clock
		row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
		ids = append(ids, row.ID)
	}
	want := []uint64{ids[3], ids[0], ids[1], ids[2], ids[5], ids[4]}
	rows, err := listTransactions(s.db, 1, Filter{})
	if err != nil || len(rows) != len(want) {
		t.Fatalf("查询失败：%v，流水数 %d", err, len(rows))
	}
	for i, row := range rows {
		if row.ID != want[i] {
			t.Fatalf("第 %d 笔应为 %d，实际 %d", i, want[i], row.ID)
		}
	}
	page, err := listTransactions(s.db, 1, Filter{Limit: 2, Offset: 1})
	if err != nil || len(page) != 2 || page[0].ID != want[1] || page[1].ID != want[2] {
		t.Fatalf("分页未按交易时间排序：%v，%v", page, err)
	}
}
