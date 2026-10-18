// 文件职责：验证报销标记的写入、资料更正、退款净额、分期继承及云同步契约。
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestReimbursementWrites 验证新增及白名单 PATCH 的报销校验与余额隔离；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestReimbursementWrites(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "报销账户", "balance": "100"}).(domain.Account)
	body := transactionBody("reimbursement-create", a.ID, "expense", "20")
	body["discount"], body["reimbursementStatus"] = "2", "pending"
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if row.ReimbursementStatus != "pending" || row.Amount != 1800 {
		t.Fatal(row)
	}
	replay := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if replay.ID != row.ID {
		t.Fatal("新增重试未幂等")
	}
	body["reimbursementStatus"] = "reimbursed"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrConflict) {
		t.Fatal("幂等内容忽略报销字段", err)
	}
	for _, status := range []string{"reimbursed", "", "pending"} {
		row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursementStatus": status}).(domain.Transaction)
		if row.ReimbursementStatus != status || row.Amount != 1800 || row.Discount != 200 || row.Type != "expense" {
			t.Fatal("零值或未提交字段被覆盖", row)
		}
		balances(t, s, map[uint64]domain.Money{a.ID: 8200})
	}
	for _, change := range []map[string]any{{"reimbursementStatus": "received"}, {"reimbursementStatus": nil}, {"type": "income"}} {
		if _, err := execute(s, 1, "finance.transaction.update", row.ID, change, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("非法更正未拒绝", change, err)
		}
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"amount": "30", "description": "金额更正"}).(domain.Transaction)
	if row.ReimbursementStatus != "pending" || row.Amount != 2800 {
		t.Fatal("财务修改丢失标记", row)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"type": "income", "discount": "0", "reimbursementStatus": ""}).(domain.Transaction)
	balances(t, s, map[uint64]domain.Money{a.ID: 13000})
	for i, typ := range []string{"income", "transfer"} {
		invalid := transactionBody(fmt.Sprintf("reimbursement-invalid-%d", i), a.ID, typ, "1")
		invalid["reimbursementStatus"] = "pending"
		if _, err := execute(s, 1, "finance.transaction.create", 0, invalid, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("非支出允许标记", typ, err)
		}
	}
	original := must(t, s, "finance.transaction.create", 0, transactionBody("reimbursement-refund", a.ID, "expense", "10")).(domain.Transaction)
	refund := must(t, s, "finance.transaction.refund", original.ID, map[string]any{"requestId": "reimbursement-refund-child", "amount": "2", "transactionDate": original.TransactionDate}).(domain.Transaction)
	if refund.ReimbursementStatus != "" {
		t.Fatal("退款继承了标记", refund)
	}
	if _, err := execute(s, 1, "finance.transaction.update", refund.ID, map[string]any{"reimbursementStatus": "pending"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("退款允许独立标记", err)
	}
	// 将账户置于金额上限：如资料 PATCH 误走旧流水冲销，会先加回支出而溢出，测试必须成功。
	if err := s.db.Model(&domain.Account{}).Where("id = ?", a.ID).Updates(map[string]any{"balance": domain.MaxMoney}).Error; err != nil {
		t.Fatal(err)
	}
	must(t, s, "finance.transaction.update", original.ID, map[string]any{"reimbursementStatus": "reimbursed"})
	balances(t, s, map[uint64]domain.Money{a.ID: domain.MaxMoney})
}

// TestReimbursementSummary 验证原单日期归属、跨月有效退款、逐笔下限、状态过滤与账户隔离；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestReimbursementSummary(t *testing.T) {
	s := fixture(t)
	rows := []domain.Transaction{
		{ID: 101, OwnerID: 1, AccountID: 10, Type: "expense", Amount: 9001, Discount: 999, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-09-01"},
		{ID: 102, OwnerID: 1, AccountID: 10, Type: "expense", Amount: 2000, Status: "posted", ReimbursementStatus: "reimbursed", TransactionDate: "2026-09-30"},
		{ID: 103, OwnerID: 1, AccountID: 20, Type: "expense", Amount: 700, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
		{ID: 104, OwnerID: 1, AccountID: 10, Type: "expense", Amount: 500, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
		{ID: 105, OwnerID: 1, AccountID: 10, Type: "expense", Amount: 8000, Status: "posted", TransactionDate: "2026-09-15"},
	}
	// 所有非入账原支出、未标记支出、其他用户及其他月份均不得进入报销统计。
	for i, status := range []string{"pending", "voided", "deleted", "installment"} {
		rows = append(rows, domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: 999999, Status: status, ReimbursementStatus: "pending", TransactionDate: "2026-09-15", ID: uint64(110 + i)})
	}
	parent, received, overRefund := uint64(101), uint64(102), uint64(104)
	installmentParent := uint64(113)
	rows = append(rows,
		domain.Transaction{OwnerID: 1, AccountID: 99, Type: "expense", Amount: -2001, Status: "posted", RefundParentID: &parent, TransactionDate: "2026-10-20"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -1000, Status: "posted", RefundParentID: &parent, TransactionDate: "2026-09-15"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -99999, Status: "deleted", RefundParentID: &parent, TransactionDate: "2026-10-20"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -99999, Status: "voided", RefundParentID: &parent, TransactionDate: "2026-10-20"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -99999, Status: "pending", RefundParentID: &parent, TransactionDate: "2026-10-20"},
		domain.Transaction{OwnerID: 2, AccountID: 10, Type: "expense", Amount: -99999, Status: "posted", RefundParentID: &parent, TransactionDate: "2026-10-20"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -501, Status: "posted", RefundParentID: &received, TransactionDate: "2026-11-01"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: -700, Status: "posted", RefundParentID: &overRefund, TransactionDate: "2026-11-01"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "income", Amount: 99999, Status: "posted", RebateParentID: &parent, ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "transfer", Amount: 99999, Fee: 500, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
		domain.Transaction{OwnerID: 2, AccountID: 10, Type: "expense", Amount: 99999, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: 99999, Status: "posted", ReimbursementStatus: "pending", TransactionDate: "2026-10-01"},
		domain.Transaction{OwnerID: 1, AccountID: 10, Type: "expense", Amount: 100, Status: "posted", InstallmentParentID: &installmentParent, ReimbursementStatus: "pending", TransactionDate: "2026-09-15"},
	)
	for i := range rows {
		rows[i].RequestID = fmt.Sprintf("reimbursement-summary-%d", i)
	}
	if err := s.db.Create(&rows).Error; err != nil {
		t.Fatal(err)
	}
	filter := Filter{StartDate: "2026-09-01", EndDate: "2026-09-30"}
	all, err := transactionSummary(s.db, 1, filter)
	if err != nil || all.ReimbursementPending != 6800 || all.ReimbursementReceived != 1499 || all.ReimbursementTotal != 8299 {
		t.Fatal("全月净额错误", all, err)
	}
	filter.AccountID = 10
	one, err := transactionSummary(s.db, 1, filter)
	if err != nil || one.ReimbursementPending != 6100 || one.ReimbursementReceived != 1499 || one.ReimbursementTotal != 7599 {
		t.Fatal("账户过滤或跨账户退款错误", one, err)
	}
	filter.AccountID = 20
	two, err := transactionSummary(s.db, 1, filter)
	if err != nil || two.Expense != 700 || two.Income != 0 || two.ReimbursementTotal != 700 {
		t.Fatal("收支未应用账户筛选", two, err)
	}
	// 原单当前状态决定所有退款归类；改状态不新增收入，不改变原有现金流汇总。
	must(t, s, "finance.transaction.update", parent, map[string]any{"reimbursementStatus": "reimbursed"})
	filter.AccountID = 0
	changed, err := transactionSummary(s.db, 1, filter)
	if err != nil || changed.ReimbursementPending != 800 || changed.ReimbursementReceived != 7499 || changed.ReimbursementTotal != all.ReimbursementTotal || changed.Income != all.Income || changed.Expense != all.Expense {
		t.Fatal("状态重分类错误", changed, err)
	}
	raw, err := json.Marshal(changed)
	if err != nil || !strings.Contains(string(raw), `"reimbursementTotal":"82.99"`) || !strings.Contains(string(raw), `"reimbursementReceived":"74.99"`) {
		t.Fatal("金额未使用精确字符串", string(raw), err)
	}
	filter.AccountID = 999
	empty, err := transactionSummary(s.db, 1, filter)
	if err != nil || empty != (domain.TransactionSummary{}) {
		t.Fatal("空账户结果错误", empty, err)
	}
}

// TestReimbursementInstallments 验证消费分期输入继承、单期资料 PATCH 与规则重建保留状态；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestReimbursementInstallments(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "分期账户", "balance": "100"}).(domain.Account)
	body := transactionBody("reimbursement-installment", a.ID, "expense", "30")
	body["reimbursementStatus"] = "pending"
	bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	terms := map[string]any{"name": "消费分期", "periods": 3, "firstDate": "2030-01-01", "interest": "0", "interestMode": "spread", "rounding": "floor", "remainder": "last"}
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	child := must(t, s, "finance.transaction.update", plan.Rows[0].TransactionID, map[string]any{"reimbursementStatus": "reimbursed"}).(domain.Transaction)
	if child.ReimbursementStatus != "reimbursed" || child.Status != "pending" || child.Amount != 1000 {
		t.Fatal("分期子单资料修改失败", child)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	if _, err := execute(s, 1, "finance.transaction.update", child.ID, map[string]any{"amount": "9"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("分期财务字段保护失效", err)
	}
	// 未提交报销设置的规则修改保留单期标记；新增期次从原主单继承。
	plan = must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 4}).(domain.InstallmentPlan)
	var children []domain.Transaction
	if err := s.db.Where("installment_parent_id = ?", bill.ID).Order("installment_period").Find(&children).Error; err != nil {
		t.Fatal(err)
	}
	if len(children) != 4 || children[0].ReimbursementStatus != "reimbursed" || children[1].ReimbursementStatus != "pending" || children[3].ReimbursementStatus != "pending" {
		t.Fatal("分期继承或重建丢失状态", children)
	}
	must(t, s, "finance.transaction.confirm", plan.Rows[0].TransactionID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 9250})
	must(t, s, "finance.installment.update", bill.ID, map[string]any{"reimbursementStatus": ""})
	if err := s.db.Where("installment_parent_id = ?", bill.ID).Order("installment_period").Find(&children).Error; err != nil {
		t.Fatal(err)
	}
	if children[0].ReimbursementStatus != "reimbursed" || children[1].ReimbursementStatus != "" || children[3].ReimbursementStatus != "" {
		t.Fatal("计划资料覆盖已入账期次或未清空待入账期次", children)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 9250})
	// 新建分期显式设置可覆盖原单默认值，并传给生成期次。
	other := must(t, s, "finance.transaction.create", 0, transactionBody("reimbursement-installment-explicit", a.ID, "expense", "20")).(domain.Transaction)
	terms["reimbursementStatus"] = "pending"
	explicit := must(t, s, "finance.installment.create", other.ID, terms).(domain.InstallmentPlan)
	var first domain.Transaction
	if err := s.db.First(&first, explicit.Rows[0].TransactionID).Error; err != nil || first.ReimbursementStatus != "pending" {
		t.Fatal("分期输入未传给子单", first, err)
	}
}

// TestReimbursementSyncAndMigration 验证云同步新增、更正、重放及快照保留字段，历史行迁移默认空；参数：t 为测试上下文；返回值：无，失败终止测试。
func TestReimbursementSyncAndMigration(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "同步账户", "balance": "100"}).(domain.Account)
	body := transactionBody("reimbursement-sync-create", a.ID, "expense", "12.34")
	body["reimbursementStatus"] = "pending"
	command := syncTestCommand("reimbursement-sync-operation", "finance.transaction.create", 0, body)
	raw, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	var row domain.Transaction
	if err := json.Unmarshal(raw, &row); err != nil || row.ReimbursementStatus != "pending" {
		t.Fatal(string(raw), err)
	}
	command = syncTestCommand("reimbursement-sync-update", "finance.transaction.update", row.ID, map[string]any{"reimbursementStatus": "reimbursed"})
	raw, err = s.SyncExecute(context.Background(), 1, command)
	if err != nil || !strings.Contains(string(raw), `"reimbursementStatus":"reimbursed"`) {
		t.Fatal(string(raw), err)
	}
	replay, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil || string(raw) != string(replay) {
		t.Fatal("同步回执不稳定", err)
	}
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	transactions := snapshot["transactions"].([]domain.Transaction)
	if len(transactions) != 1 || transactions[0].ReimbursementStatus != "reimbursed" {
		t.Fatal("快照丢失报销状态", transactions)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 8766})
	// 模拟升级前的表结构，重新迁移时已有行必须获得非 null 空字符串默认值。
	if err := s.db.Migrator().DropColumn(&domain.Transaction{}, "ReimbursementStatus"); err != nil {
		t.Fatal(err)
	}
	if err := s.db.AutoMigrate(&domain.Transaction{}); err != nil {
		t.Fatal(err)
	}
	if err := s.db.First(&row, row.ID).Error; err != nil || row.ReimbursementStatus != "" {
		t.Fatal("旧行默认值错误", row, err)
	}
}
