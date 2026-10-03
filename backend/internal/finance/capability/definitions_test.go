// 文件职责：将finance业务适配为共享 AI 能力。

package capability

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/service"
	"personal_assistant_server/internal/user/model"
)

// TestCapabilities 验证注册表的真实 JSON 工具入口只创建草稿；参数：t 为测试上下文；返回值：无，不访问真实模型。
func TestCapabilities(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, map[string]any{"name": "现金", "balance": "10"}).(domain.Account)
	defs := Definitions(s)
	for _, d := range defs {
		if !json.Valid(d.InputSchema) {
			t.Fatal(d.Name)
		}
	}
	executor := capability.NewExecutor(capability.NewRegistry(defs...))
	body, _ := json.Marshal(service.Input{Changes: json.RawMessage(fmt.Sprintf(`{"requestId":"tool-test-001","accountId":%d,"type":"expense","amount":"1.25","transactionDate":"2026-09-26"}`, a.ID))})
	out, e := executor.Invoke(context.Background(), capability.Actor{UserID: 1}, "finance.transaction.create", body)
	if e != nil || out.(domain.Transaction).Status != "pending" {
		t.Fatal(out, e)
	}
	balances(t, s, map[uint64]domain.Money{a.ID: 1000})
	if _, e = executor.Invoke(context.Background(), capability.Actor{UserID: 1}, "finance.transaction.confirm", json.RawMessage(`{"id":1}`)); !errors.Is(e, capability.ErrNotFound) {
		t.Fatal("确认能力不应对模型公开")
	}
}

// fixture 创建独立 SQLite 数据库；参数：t 为测试上下文；返回值：已迁移且有两名用户的服务，退出时关闭连接，不连接生产环境。
func fixture(t *testing.T) *service.Service {
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
	s := service.NewService(db)
	// 测试时钟默认早于固定分期日期，避免历史用例随真实日期变化；自动入账测试显式推进该时钟。
	return s
}

// execute 执行指定身份和来源的操作；参数：s 为服务，owner 为身份，op 为操作，id 为目标，body 为字段，source 为来源；返回值：结果及错误。
func execute(s *service.Service, owner uint64, op string, id uint64, body any, source string) (any, error) {
	raw, e := json.Marshal(body)
	if e != nil {
		return nil, e
	}
	return s.Execute(context.Background(), capability.Actor{UserID: owner}, op, service.Input{ID: id, Changes: raw}, source)
}

// must 执行用户一的操作并断言成功；参数：t 为测试，s 为服务，op 为操作，id 为目标，body 为字段；返回值：业务结果，失败终止测试。
func must(t *testing.T, s *service.Service, op string, id uint64, body any) any {
	t.Helper()
	out, e := execute(s, 1, op, id, body, "http")
	if e != nil {
		t.Fatal(e)
	}
	return out
}

// balances 验证能力调用后余额；参数：t 为测试上下文，s 为服务，expected 为账户余额；返回值：无。
func balances(t *testing.T, s *service.Service, expected map[uint64]domain.Money) {
	out, err := s.Execute(context.Background(), capability.Actor{UserID: 1}, "finance.account.list", service.Input{}, "http")
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range out.([]domain.Account) {
		if value, ok := expected[a.ID]; ok && a.Balance != value {
			t.Fatalf("余额不符: %d", a.ID)
		}
	}
}
