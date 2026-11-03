package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestSyncUncategorizedLegacyQueue 验证旧截图队列的零分类可入账且原命令可幂等重试；参数：t 为测试上下文；返回值：无；仅写独立测试数据库。
func TestSyncUncategorizedLegacyQueue(t *testing.T) {
	s := fixture(t)
	if err := s.db.AutoMigrate(&domain.SyncReceipt{}); err != nil {
		t.Fatal(err)
	}
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "本机钱包", "balance": "100.00"}).(domain.Account)
	body := transactionBody("screenshot-zero-category", a.ID, "expense", "12.00")
	body["categoryId"] = 0
	cmd := syncTestCommand("legacy-zero-category", "finance.transaction.create", 0, body)
	original := string(cmd.Body)
	first, err := s.SyncExecute(context.Background(), 1, cmd)
	if err != nil {
		t.Fatalf("旧截图未分类队列不能上传: %v", err)
	}
	var row domain.Transaction
	if err := json.Unmarshal(first, &row); err != nil {
		t.Fatal(err)
	}
	if row.CategoryID != nil {
		t.Fatalf("未分类必须持久化为 NULL: %+v", row.CategoryID)
	}
	if string(cmd.Body) != original {
		t.Fatal("不得改写原始队列命令")
	}
	repeated, err := s.SyncExecute(context.Background(), 1, cmd)
	if err != nil || string(first) != string(repeated) {
		t.Fatalf("原请求重试不稳定: %v", err)
	}
	var count int64
	s.db.Model(&domain.Transaction{}).Where("request_id = ?", body["requestId"]).Count(&count)
	if count != 1 {
		t.Fatalf("重复入账: %d", count)
	}
	var saved domain.Account
	if err := s.db.First(&saved, a.ID).Error; err != nil {
		t.Fatal(err)
	}
	if saved.Balance != domain.Money(8800) {
		t.Fatalf("余额被重复扣减: %v", saved.Balance)
	}
	// 修改分类为空使用现有 PATCH map 路径，不抹掉未提交的金额、账户等字段。
	patch := syncTestCommand("legacy-clear-category", "finance.transaction.update", row.ID, map[string]any{"categoryId": 0, "description": "备注保留"})
	if _, err := s.SyncExecute(context.Background(), 1, patch); err != nil {
		t.Fatal(err)
	}
	var updated domain.Transaction
	if err := s.db.First(&updated, row.ID).Error; err != nil {
		t.Fatal(err)
	}
	if updated.CategoryID != nil || updated.Amount != row.Amount || updated.AccountID != a.ID || updated.Description != "备注保留" {
		t.Fatalf("PATCH错误: %+v", updated)
	}
	// 真正缺失的非零分类仍须拒绝，不能通过吞掉外键错误越过权限或业务校验。
	bad := transactionBody("missing-category-payment", a.ID, "expense", "1.00")
	bad["categoryId"] = 999999
	if _, err := s.SyncExecute(context.Background(), 1, syncTestCommand("missing-category-op", "finance.transaction.create", 0, bad)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("非零缺失分类未拒绝: %v", err)
	}
	// 未确认旧命令不能因兼容处理而改变回执指纹：同 operationId 换正文仍冲突。
	body["categoryId"] = nil
	if _, err := s.SyncExecute(context.Background(), 1, syncTestCommand(cmd.OperationID, cmd.Operation, 0, body)); !errors.Is(err, ErrConflict) {
		t.Fatalf("原始指纹语义被改变: %v", err)
	}
}

// TestSyncCategoryNormalizationScope 验证兼容仅作用于普通流水的零分类；参数：t 为测试上下文；返回值：无；无数据库或网络副作用。
func TestSyncCategoryNormalizationScope(t *testing.T) {
	for _, op := range []string{"finance.installment.update", "finance.preset.create", "finance.account.update"} {
		raw := json.RawMessage(`{"categoryId":0}`)
		out, err := normalizeSyncCategory(op, raw)
		if err != nil || string(out) != string(raw) {
			t.Fatalf("不应改写 %s: %s %v", op, out, err)
		}
	}
	for _, raw := range []string{`{}`, `{"categoryId":null}`, `{"categoryId":123}`, `{"categoryId":"0"}`} {
		out, err := normalizeSyncCategory("finance.transaction.create", json.RawMessage(raw))
		if err != nil || string(out) != raw {
			t.Fatalf("不应改写 %s: %s %v", raw, out, err)
		}
	}
}
