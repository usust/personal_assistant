// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"fmt"
	"testing"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
)

// TestTransactionSummary 验证完整月统计独立于分页、退款和费用口径及用户隔离；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestTransactionSummary(t *testing.T) {
	s := fixture(t)
	var rows []domain.Transaction
	for i := 0; i < 65; i++ {
		rows = append(rows, domain.Transaction{OwnerID: 1, Type: "expense", Amount: 100, Status: "posted", TransactionDate: "2026-09-01"})
	}
	rows = append(rows,
		domain.Transaction{OwnerID: 1, Type: "expense", Amount: -500, Status: "posted", TransactionDate: "2026-09-30"},
		domain.Transaction{OwnerID: 1, Type: "income", Amount: 10000, Status: "posted", TransactionDate: "2026-09-30"},
		domain.Transaction{OwnerID: 1, Type: "transfer", Amount: 50000, Fee: 200, Status: "posted", TransactionDate: "2026-09-20"},
		domain.Transaction{OwnerID: 1, Type: "expense", Amount: 99999, Status: "pending", TransactionDate: "2026-09-20"},
		domain.Transaction{OwnerID: 1, Type: "expense", Amount: 99999, Status: "deleted", TransactionDate: "2026-09-20"},
		domain.Transaction{OwnerID: 1, Type: "expense", Amount: 99999, Status: "posted", TransactionDate: "2026-10-01"},
		domain.Transaction{OwnerID: 2, Type: "expense", Amount: 99999, Status: "posted", TransactionDate: "2026-09-20"})
	for i := range rows {
		rows[i].RequestID = fmt.Sprintf("summary_%d", i)
	}
	if err := s.db.Create(&rows).Error; err != nil {
		t.Fatal(err)
	}
	out, err := s.Execute(context.Background(), capability.Actor{UserID: 1}, "finance.transaction.summary", Input{Filter: Filter{StartDate: "2026-09-01", EndDate: "2026-09-30"}}, "http")
	if err != nil {
		t.Fatal(err)
	}
	result := out.(domain.TransactionSummary)
	if result.Income != 10000 || result.Expense != 6200 || result.Balance != 3800 {
		t.Fatal("汇总口径错误", result)
	}
	empty, err := transactionSummary(s.db, 1, Filter{StartDate: "2026-08-01", EndDate: "2026-08-31"})
	if err != nil || empty != (domain.TransactionSummary{}) {
		t.Fatal("空月份错误", empty, err)
	}
	for _, f := range []Filter{{}, {StartDate: "2026-09-30", EndDate: "2026-09-01"}, {StartDate: "2026-09-01", EndDate: "2026-09-30", Limit: 50}} {
		if _, err := transactionSummary(s.db, 1, f); err == nil {
			t.Fatal("非法范围未拒绝", f)
		}
	}
}
