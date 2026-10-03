// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/user/model"
)

// fixture 创建独立 SQLite 数据库；参数：t 为测试上下文；返回值：已迁移且有两名用户的服务，退出时关闭连接，不连接生产环境。
func fixture(t *testing.T) *Service {
	t.Helper()
	db, e := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "finance.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if e != nil {
		t.Fatal(e)
	}
	if e = db.AutoMigrate(&model.User{}, &domain.Account{}, &domain.Category{}, &domain.Transaction{}, &domain.Snapshot{}, &domain.Preset{}, &domain.Event{}); e != nil {
		t.Fatal(e)
	}
	for _, u := range []model.User{{ID: 1, Account: "one"}, {ID: 2, Account: "two"}} {
		if e = db.Create(&u).Error; e != nil {
			t.Fatal(e)
		}
	}
	// 清理测试连接；参数：无；返回值：无，关闭错误使测试失败。
	t.Cleanup(func() {
		sqlDB, e := db.DB()
		if e == nil {
			e = sqlDB.Close()
		}
		if e != nil {
			t.Error(e)
		}
	})
	s := NewService(db)
	// 测试时钟默认早于固定分期日期，避免历史用例随真实日期变化；自动入账测试显式推进该时钟。
	s.now = func() time.Time { return time.Date(1999, 1, 1, 0, 0, 0, 0, time.UTC) }
	return s
}

// execute 执行指定身份和来源的操作；参数：s 为服务，owner 为身份，op 为操作，id 为目标，body 为字段，source 为来源；返回值：结果及错误。
func execute(s *Service, owner uint64, op string, id uint64, body any, source string) (any, error) {
	raw, e := json.Marshal(body)
	if e != nil {
		return nil, e
	}
	return s.Execute(context.Background(), capability.Actor{UserID: owner}, op, Input{ID: id, Changes: raw}, source)
}

// must 执行用户一的操作并断言成功；参数：t 为测试，s 为服务，op 为操作，id 为目标，body 为字段；返回值：业务结果，失败终止测试。
func must(t *testing.T, s *Service, op string, id uint64, body any) any {
	t.Helper()
	out, e := execute(s, 1, op, id, body, "http")
	if e != nil {
		t.Fatal(e)
	}
	return out
}

// transactionBody 构造流水输入；参数：key 为幂等键，id 为账户，kind 为类型，amount 为元金额；返回值：本月流水字段，无副作用。
func transactionBody(key string, id uint64, kind, amount string) map[string]any {
	return map[string]any{"requestId": key, "accountId": id, "type": kind, "amount": amount, "transactionDate": time.Now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")}
}

// balances 验证余额；参数：t、s 为测试和服务，want 为账户 ID 到分金额的映射；返回值：无，不符合即失败。
func balances(t *testing.T, s *Service, want map[uint64]domain.Money) {
	t.Helper()
	for id, value := range want {
		a, e := account(s.db, 1, id, false)
		if e != nil || a.Balance != value {
			t.Fatalf("账户 %d: %+v %v，预期 %s", id, a, e, value.String())
		}
	}
}

// TestLedger 验证金额精度、原子转账、幂等、草稿确认、冲销及统计；参数：t 为测试上下文；返回值：无。
func TestLedger(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "钱包", "balance": "100.00"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "银行卡"}).(domain.Account)
	category := must(t, s, "finance.category.create", 0, map[string]any{"name": "自定义午餐", "type": "expense"}).(domain.Category)
	if category.ID == 0 {
		t.Fatal("未返回分类 ID")
	}
	body := transactionBody("expense-001", a.ID, "expense", "0.10")
	body["categoryId"] = category.ID
	expense := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	replay := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	if replay.ID != expense.ID {
		t.Fatal("重试生成重复流水")
	}
	body["amount"] = "0.20"
	if _, e := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	transfer := transactionBody("transfer-001", a.ID, "transfer", "20.00")
	transfer["targetAccountId"] = b.ID
	tr := must(t, s, "finance.transaction.create", 0, transfer).(domain.Transaction)
	balances(t, s, map[uint64]domain.Money{a.ID: 7990, b.ID: 2000})
	summary := must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthExpense != 10 || summary.MonthIncome != 0 || summary.NetWorth != 9990 || len(summary.ExpenseCategories) != 1 {
		t.Fatalf("错误统计: %+v", summary)
	}
	draftBody := transactionBody("ai-income-001", b.ID, "income", "1.23")
	draft, e := execute(s, 1, "finance.transaction.create", 0, draftBody, "ai")
	if e != nil {
		t.Fatal(e)
	}
	d := draft.(domain.Transaction)
	if d.Status != "pending" {
		t.Fatal(d)
	}
	balances(t, s, map[uint64]domain.Money{b.ID: 2000})
	if _, e = execute(s, 1, "finance.transaction.confirm", d.ID, nil, "ai"); !errors.Is(e, ErrInvalid) {
		t.Fatal("AI 不应确认", e)
	}
	must(t, s, "finance.transaction.confirm", d.ID, nil)
	must(t, s, "finance.transaction.confirm", d.ID, nil)
	balances(t, s, map[uint64]domain.Money{b.ID: 2123})
	must(t, s, "finance.transaction.void", tr.ID, nil)
	must(t, s, "finance.transaction.void", tr.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 9990, b.ID: 123})
	must(t, s, "finance.transaction.void", expense.ID, nil)
	balances(t, s, map[uint64]domain.Money{a.ID: 10000})
	summary = must(t, s, "finance.overview", 0, nil).(domain.Overview)
	if summary.MonthExpense != 0 || summary.MonthIncome != 123 {
		t.Fatal(summary)
	}
	var count int64
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 3 {
		t.Fatal(count)
	}
}

// TestIsolationAndPatch 验证关联权限、白名单、零值更新及不可修改入账金额；参数：t 为测试上下文；返回值：无。
func TestIsolationAndPatch(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "A", "notes": "原备注", "sortOrder": 5, "maskedAccountNumber": "1234567890123456"}).(domain.Account)
	if a.MaskedAccountNumber != "**** 3456" {
		t.Fatal("完整卡号未脱敏")
	}
	changed := must(t, s, "finance.account.update", a.ID, map[string]any{"notes": "", "sortOrder": 0, "includeInNetWorth": false}).(domain.Account)
	if changed.Name != "A" || changed.Notes != "" || changed.SortOrder != 0 || changed.IncludeInNetWorth {
		t.Fatal(changed)
	}
	foreign, e := execute(s, 2, "finance.account.create", 0, map[string]any{"name": "他人账户"}, "http")
	if e != nil {
		t.Fatal(e)
	}
	c := must(t, s, "finance.category.create", 0, map[string]any{"name": "自定义奖金", "type": "income"}).(domain.Category)
	cases := []struct {
		owner uint64
		op    string
		id    uint64
		body  any
		want  error
	}{
		{2, "finance.account.update", a.ID, map[string]any{"name": "越权"}, ErrNotFound},
		{1, "finance.account.update", a.ID, map[string]any{"balance": "0"}, ErrInvalid},
		{1, "finance.account.update", a.ID, map[string]any{"owner_id": 2}, ErrInvalid},
		{1, "finance.account.update", a.ID, map[string]any{"name": nil}, ErrInvalid},
		{1, "finance.transaction.create", 0, transactionBody("foreign-001", foreign.(domain.Account).ID, "expense", "1"), ErrNotFound},
	}
	for _, tc := range cases {
		if _, e = execute(s, tc.owner, tc.op, tc.id, tc.body, "http"); !errors.Is(e, tc.want) {
			t.Fatalf("%s: %v", tc.op, e)
		}
	}
	body := transactionBody("income-001", a.ID, "income", "5")
	body["categoryId"] = c.ID
	body["description"] = "原说明"
	tr := must(t, s, "finance.transaction.create", 0, body).(domain.Transaction)
	updated := must(t, s, "finance.transaction.update", tr.ID, map[string]any{"categoryId": nil, "description": ""}).(domain.Transaction)
	if updated.CategoryID != nil || updated.Description != "" || updated.Amount != 500 {
		t.Fatal(updated)
	}
	if _, e = execute(s, 2, "finance.transaction.void", tr.ID, nil, "http"); !errors.Is(e, ErrNotFound) {
		t.Fatal(e)
	}
	if _, e = execute(s, 1, "finance.transaction.update", tr.ID, map[string]any{"amount": "0"}, "http"); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if _, e = execute(s, 1, "finance.account.archive", a.ID, nil, "http"); e != nil {
		t.Fatal(e)
	}
	rows, e := s.Execute(context.Background(), capability.Actor{UserID: 2}, "finance.transaction.list", Input{}, "http")
	if e != nil || len(rows.([]domain.Transaction)) != 0 {
		t.Fatal("跨用户泄漏", e)
	}
}

// TestRollbackAndFilters 验证余额上限失败回滚整笔转账及筛选分页；参数：t 为测试上下文；返回值：无。
func TestRollbackAndFilters(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "A", "balance": "10"}).(domain.Account)
	b := must(t, s, "finance.account.create", 0, map[string]any{"name": "B", "balance": maxMoney.String()}).(domain.Account)
	body := transactionBody("overflow-001", a.ID, "transfer", "1")
	body["targetAccountId"] = b.ID
	if _, e := execute(s, 1, "finance.transaction.create", 0, body, "http"); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 1000, b.ID: maxMoney})
	var count int64
	s.db.Model(&domain.Transaction{}).Count(&count)
	if count != 0 {
		t.Fatal("留下半笔流水")
	}
	for i := range 3 {
		must(t, s, "finance.transaction.create", 0, transactionBody(fmt.Sprintf("expense-%03d", i), a.ID, "expense", "0.01"))
	}
	rows, e := listTransactions(s.db, 1, Filter{AccountID: a.ID, Limit: 2, Offset: 1, MinAmount: "0.01", MaxAmount: "0.01"})
	if e != nil || len(rows) != 2 {
		t.Fatal(rows, e)
	}
	for _, f := range []Filter{{StartDate: "2026-02-30"}, {MinAmount: "2", MaxAmount: "1"}, {Limit: 501}, {Offset: -1}, {Status: "bad"}} {
		if _, e = listTransactions(s.db, 1, f); !errors.Is(e, ErrInvalid) {
			t.Fatal(f, e)
		}
	}
	for _, s := range []string{"0.001", "NaN", "1e3", " 1", "1000000000000.01"} {
		if _, e = domain.ParseMoney(s); e == nil {
			t.Fatal("非法金额", s)
		}
	}
}
