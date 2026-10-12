// 文件职责：验证报销资料、累计统计、退款、分期以及旧账本同步兼容性。
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	domain "personal_assistant_server/internal/finance/model"
)

// TestReimbursementMetadataAndRefund 验证独立报销 PATCH、零值、退款净额和余额边界；参数：t 为隔离测试上下文；返回值：无，失败终止测试，不连接生产数据库。
func TestReimbursementMetadataAndRefund(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "报销账户", "balance": "1000.00"}).(domain.Account)
	body := transactionBody("reimburse-metadata", a.ID, "expense", "100.00")
	body["discount"], body["reimbursable"], body["reimbursedAmount"] = "20.00", true, "30.00"
	row := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if !row.Reimbursable || row.ReimbursedAmount != 3000 || row.Amount != 8000 {
		t.Fatal("实付或报销资料错误", row)
	}
	var before, after int64
	if err := s.db.Model(&domain.Snapshot{}).Count(&before).Error; err != nil {
		t.Fatal(err)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "50.00"}).(domain.Transaction)
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"description": "保留报销"}).(domain.Transaction)
	if !row.Reimbursable || row.ReimbursedAmount != 5000 || row.Description != "保留报销" {
		t.Fatal("单字段更正覆盖其他资料", row)
	}
	if _, err := execute(s, 1, "finance.transaction.update", row.ID, map[string]any{"reimbursable": false}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("取消标记隐式清除了已报销金额", err)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "0.00"}).(domain.Transaction)
	if !row.Reimbursable || row.ReimbursedAmount != 0 {
		t.Fatal("零金额未保留标记", row)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursable": false}).(domain.Transaction)
	if row.Reimbursable || row.ReimbursedAmount != 0 {
		t.Fatal("false 零值未写入", row)
	}
	row = must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursable": true, "reimbursedAmount": "80.00"}).(domain.Transaction)
	if err := s.db.Model(&domain.Snapshot{}).Count(&after).Error; err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatal("报销资料更正生成余额快照", before, after)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 92000})
	refundBody := map[string]any{"requestId": "reimburse-refund-one", "amount": "20.00", "transactionDate": row.TransactionDate}
	if _, err := execute(s, 1, "finance.transaction.refund", row.ID, refundBody, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("退款使报销到账超出净额", err)
	}
	must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "50.00"})
	refund := must(t, s, "finance.transaction.refund", row.ID, refundBody).(domain.Transaction)
	if refund.Reimbursable || refund.ReimbursedAmount != 0 {
		t.Fatal("退款被标记为报销", refund)
	}
	must(t, s, "finance.transaction.refund", row.ID, map[string]any{"requestId": "reimburse-refund-two", "amount": "5.00", "transactionDate": row.TransactionDate})
	for _, patch := range []map[string]any{{"reimbursedAmount": "55.01"}, {"amount": "74.00"}, {"reimbursedAmount": "-0.01"}, {"reimbursable": nil}, {"reimbursedAmount": nil}} {
		if _, err := execute(s, 1, "finance.transaction.update", row.ID, patch, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("非法报销修改未拒绝", patch, err)
		}
	}
	if _, err := execute(s, 1, "finance.transaction.update", refund.ID, map[string]any{"reimbursable": true}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("退款子项允许独立报销", err)
	}
	if _, err := execute(s, 2, "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "0.00"}, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatal("报销更正未隔离用户", err)
	}
	out := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if out.ReimbursementTotal != 5500 || out.ReimbursementReceived != 5000 || out.ReimbursementPending != 500 || out.MonthExpense != 5500 || out.NetWorth != 94500 {
		t.Fatal("退款后统计或资产错误", out)
	}
	must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursable": false, "reimbursedAmount": "0.00"})
	balances(t, s, map[uint64]domain.Money{a.ID: 94500})
	// 作废或删除保留原报销资料用于审计，但不再计入卡片；原支出与退款统一回退余额。
	must(t, s, "finance.transaction.update", row.ID, map[string]any{"reimbursable": true, "reimbursedAmount": "55.00"})
	must(t, s, "finance.transaction.void", row.ID, nil)
	voided := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if voided.ReimbursementTotal != 0 || voided.ReimbursementReceived != 0 || voided.ReimbursementPending != 0 {
		t.Fatal("作废流水仍纳入报销", voided)
	}
	must(t, s, "finance.transaction.delete", row.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 100000})
}

// TestReimbursementCreationAndDrafts 验证输入范围及草稿、返现、模板权限；参数：t 为隔离测试上下文；返回值：无，失败终止测试，只有真实支出可参与报销。
func TestReimbursementCreationAndDrafts(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "创建账户"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "目标账户"}).(domain.Account)
	for i, patch := range []map[string]any{{"type": "income", "reimbursable": true}, {"type": "transfer", "targetAccountId": b.ID, "reimbursable": true}, {"reimbursedAmount": "1.00"}, {"reimbursable": true, "reimbursedAmount": "10.01"}, {"reimbursable": true, "reimbursedAmount": "-0.01"}} {
		body := transactionBody(fmt.Sprintf("reimburse-invalid-%d", i), a.ID, "expense", "10.00")
		for key, value := range patch {
			body[key] = value
		}
		if _, err := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("创建非法报销通过", body, err)
		}
	}
	body := transactionBody("reimburse-ai-draft", a.ID, "expense", "10.00")
	body["reimbursable"] = true
	draft, err := execute(s, 1, "finance.transaction.create", 0, body, "ai")
	if err != nil {
		t.Fatal(err)
	}
	row := draft.(domain.Transaction)
	if !row.Reimbursable || row.Status != "pending" || row.ReimbursedAmount != 0 {
		t.Fatal("草稿标记错误", row)
	}
	if _, err := execute(s, 1, "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "1.00"}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("草稿允许预记报销到账", err)
	}
	body["requestId"], body["reimbursedAmount"] = "reimburse-ai-received", "1.00"
	if _, err := execute(s, 1, "finance.transaction.create", 0, body, "ai"); !errors.Is(err, ErrInvalid) {
		t.Fatal("AI 可记录到账金额", err)
	}
	if _, err := execute(s, 1, "finance.preset.create", 0, map[string]any{"key": "reimburse-preset-bad", "name": "报销模板", "transaction": body}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("模板保存已到账金额", err)
	}
	body["reimbursedAmount"] = "0.00"
	preset := must(t, s, "finance.preset.create", 0, map[string]any{"key": "reimburse-preset-good", "name": "报销模板", "transaction": body}).(domain.Preset)
	if !preset.Transaction.Reimbursable || preset.Transaction.ReimbursedAmount != 0 {
		t.Fatal("模板未保留待报销标记", preset)
	}
	body["reimbursedAmount"] = "1.00"
	if _, err := execute(s, 1, "finance.preset.update", preset.ID, map[string]any{"transaction": body}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("模板修改允许到账金额", err)
	}
	transferBody := transactionBody("reimburse-rebate-parent", a.ID, "transfer", "10.00")
	transferBody["targetAccountId"], transferBody["rebate"] = b.ID, "1.00"
	transfer := must(t, s, "finance.transaction.create", 0, transferBody).(domain.Transaction)
	var rebate domain.Transaction
	if err := s.db.Where("rebate_parent_id = ?", transfer.ID).First(&rebate).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := execute(s, 1, "finance.transaction.update", rebate.ID, map[string]any{"reimbursable": true}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("返现子项允许报销", err)
	}
}

// TestReimbursementWholeLedgerSummary 验证累计报销不受分页、月份、退款条数或其他用户影响；参数：t 为隔离测试上下文；返回值：无，失败终止测试。
func TestReimbursementWholeLedgerSummary(t *testing.T) {
	s := fixture(t)
	rows := make([]domain.Transaction, 600)
	for i := range rows {
		rows[i] = domain.Transaction{OwnerID: 1, RequestID: fmt.Sprintf("reimburse-summary-%d", i), Type: "expense", Amount: 100, Reimbursable: true, Status: "posted", TransactionDate: "2025-01-01"}
	}
	if err := s.db.Create(&rows).Error; err != nil {
		t.Fatal(err)
	}
	parent := domain.Transaction{OwnerID: 1, RequestID: "reimburse-summary-parent", Type: "expense", Amount: 10000, Reimbursable: true, ReimbursedAmount: 2000, Status: "posted", TransactionDate: "2025-02-01"}
	if err := s.db.Create(&parent).Error; err != nil {
		t.Fatal(err)
	}
	extra := []domain.Transaction{
		{OwnerID: 1, RequestID: "reimburse-summary-refund-a", RefundParentID: &parent.ID, Type: "expense", Amount: -1000, Status: "posted", TransactionDate: "2026-01-01"},
		{OwnerID: 1, RequestID: "reimburse-summary-refund-b", RefundParentID: &parent.ID, Type: "expense", Amount: -1500, Status: "posted", TransactionDate: "2026-02-01"},
		{OwnerID: 1, RequestID: "reimburse-summary-refund-void", RefundParentID: &parent.ID, Type: "expense", Amount: -3000, Status: "voided"},
		{OwnerID: 2, RequestID: "reimburse-summary-foreign-refund", RefundParentID: &parent.ID, Type: "expense", Amount: -4000, Status: "posted"},
		{OwnerID: 1, RequestID: "reimburse-summary-pending", Type: "expense", Amount: 99999, Reimbursable: true, Status: "pending"},
		{OwnerID: 1, RequestID: "reimburse-summary-deleted", Type: "expense", Amount: 99999, Reimbursable: true, Status: "deleted"},
		{OwnerID: 1, RequestID: "reimburse-summary-installment", Type: "expense", Amount: 99999, Reimbursable: true, Status: "installment", InstallmentJSON: `{"name":"历史主单"}`},
		{OwnerID: 1, RequestID: "reimburse-summary-unmarked", Type: "expense", Amount: 99999, Status: "posted"},
		{OwnerID: 2, RequestID: "reimburse-summary-foreign", Type: "expense", Amount: 99999, Reimbursable: true, Status: "posted"},
	}
	if err := s.db.Create(&extra).Error; err != nil {
		t.Fatal(err)
	}
	out, err := overview(s.db, 1)
	if err != nil || out.ReimbursementTotal != 67500 || out.ReimbursementReceived != 2000 || out.ReimbursementPending != 65500 {
		t.Fatal("完整累计口径错误", out, err)
	}
	if _, err := listTransactions(s.db, 1, Filter{Limit: 1}); err != nil {
		t.Fatal(err)
	}
	other, err := overview(s.db, 2)
	if err != nil || other.ReimbursementTotal != 99999 || other.ReimbursementReceived != 0 {
		t.Fatal("报销统计未隔离用户", other, err)
	}
}

// TestReimbursementInstallmentInheritance 验证分期继承、单期独立修改和规则调整保护；参数：t 为隔离测试上下文；返回值：无，失败终止测试，已到账金额不会被规则重排丢失。
func TestReimbursementInstallmentInheritance(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "分期报销", "balance": "1000.00"}).(domain.Account)
	body := transactionBody("reimburse-installment-bill", a.ID, "expense", "300.00")
	body["reimbursable"] = true
	bill := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	must(t, s, "finance.transaction.update", bill.ID, map[string]any{"reimbursedAmount": "1.00"})
	terms := domain.InstallmentTerms{Name: "报销手机", Periods: 3, FirstDate: "2026-09-01", InterestMode: "spread", Rounding: "round", Remainder: "last"}
	if _, err := execute(s, 1, "finance.installment.create", bill.ID, terms, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("已到账报销支出被拆分", err)
	}
	must(t, s, "finance.transaction.update", bill.ID, map[string]any{"reimbursedAmount": "0.00"})
	// 测试时钟无参数，返回固定业务日期，使首期入账而后续期次保持待入账。
	s.now = func() time.Time { return time.Date(2026, 9, 15, 0, 0, 0, 0, time.UTC) }
	plan := must(t, s, "finance.installment.create", bill.ID, terms).(domain.InstallmentPlan)
	if !plan.Reimbursable {
		t.Fatal("计划未保存报销继承规则", plan)
	}
	parent := must(t, s, "finance.transaction.get", bill.ID, nil).(domain.Transaction)
	if parent.Reimbursable || parent.ReimbursedAmount != 0 {
		t.Fatal("分期主单仍标记报销", parent)
	}
	if _, err := execute(s, 1, "finance.transaction.update", bill.ID, map[string]any{"reimbursable": true}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatal("分期主单可独立报销", err)
	}
	for _, period := range plan.Rows {
		child := must(t, s, "finance.transaction.get", period.TransactionID, nil).(domain.Transaction)
		if !child.Reimbursable || child.ReimbursedAmount != 0 {
			t.Fatal("期次未继承报销标记", child)
		}
	}
	must(t, s, "finance.transaction.update", plan.Rows[0].TransactionID, map[string]any{"reimbursedAmount": "90.00"})
	must(t, s, "finance.transaction.update", plan.Rows[1].TransactionID, map[string]any{"reimbursable": false})
	for _, patch := range []map[string]any{{"periods": 4}, {"firstDate": "2026-10-01"}, {"startPeriod": 2}} {
		if _, err := execute(s, 1, "finance.installment.update", bill.ID, patch, "http"); !errors.Is(err, ErrInvalid) {
			t.Fatal("分期规则丢失已到账报销", patch, err)
		}
	}
	must(t, s, "finance.transaction.update", plan.Rows[0].TransactionID, map[string]any{"reimbursedAmount": "20.00"})
	expanded := must(t, s, "finance.installment.update", bill.ID, map[string]any{"periods": 4}).(domain.InstallmentPlan)
	first := must(t, s, "finance.transaction.get", expanded.Rows[0].TransactionID, nil).(domain.Transaction)
	second := must(t, s, "finance.transaction.get", expanded.Rows[1].TransactionID, nil).(domain.Transaction)
	fourth := must(t, s, "finance.transaction.get", expanded.Rows[3].TransactionID, nil).(domain.Transaction)
	if !first.Reimbursable || first.ReimbursedAmount != 2000 || second.Reimbursable || !fourth.Reimbursable || fourth.ReimbursedAmount != 0 {
		t.Fatal("规则更正覆盖期次资料或未继承新期次", first, second, fourth)
	}
	out := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if out.ReimbursementTotal != 7500 || out.ReimbursementReceived != 2000 || out.ReimbursementPending != 5500 {
		t.Fatal("未入账期次或父单混入报销统计", out)
	}
}

// TestReimbursementSyncAndMigration 验证旧表默认值、旧输入指纹、离线幂等和快照；参数：t 为隔离测试上下文；返回值：无，失败终止测试，不读取生产账本。
func TestReimbursementSyncAndMigration(t *testing.T) {
	s := fixture(t)
	legacy := domain.Transaction{OwnerID: 1, RequestID: "reimburse-legacy-row", Type: "expense", Amount: 100, Status: "posted"}
	if err := s.db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	// 模拟上线前的表结构，再迁移；新列的默认值不得把历史流水自动纳入报销。
	for _, column := range []string{"Reimbursable", "ReimbursedAmount"} {
		if err := s.db.Migrator().DropColumn(&domain.Transaction{}, column); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.db.AutoMigrate(&domain.Transaction{}, &domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	if err := s.db.First(&legacy, legacy.ID).Error; err != nil || legacy.Reimbursable || legacy.ReimbursedAmount != 0 {
		t.Fatal("历史流水默认值错误", legacy, err)
	}
	encoded, err := json.Marshal(domain.TransactionInput{RequestID: "legacy-input", AccountID: 1, Type: "expense", Amount: 100, TransactionDate: "2026-09-01"})
	if err != nil || strings.Contains(string(encoded), "reimburs") {
		t.Fatal("新增默认字段改变旧请求指纹", string(encoded), err)
	}
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "离线报销", "balance": "100.00"}).(domain.Account)
	body := transactionBody("reimburse-offline-payment", a.ID, "expense", "20.00")
	body["reimbursable"] = true
	command := syncTestCommand("reimburse-offline-create", "finance.transaction.create", 0, body)
	raw, err := s.SyncExecute(context.Background(), 1, command)
	if err != nil {
		t.Fatal(err)
	}
	var row domain.Transaction
	if err := json.Unmarshal(raw, &row); err != nil || !row.Reimbursable {
		t.Fatal("离线创建未保存报销标记", row, err)
	}
	patch := syncTestCommand("reimburse-offline-update", "finance.transaction.update", row.ID, map[string]any{"reimbursedAmount": "5.00"})
	first, err := s.SyncExecute(context.Background(), 1, patch)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.SyncExecute(context.Background(), 1, patch)
	if err != nil || string(first) != string(second) {
		t.Fatal("离线报销修改重放不稳定", err)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 8000})
	snapshot, err := s.SyncSnapshot(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, transaction := range snapshot["transactions"].([]domain.Transaction) {
		if transaction.ID == row.ID {
			found = transaction.Reimbursable && transaction.ReimbursedAmount == 500
		}
	}
	if !found {
		t.Fatal("全量快照遗漏报销资料", snapshot)
	}
}
