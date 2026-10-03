// 文件职责：将task业务适配为共享 AI 能力。

package capability

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/service"
	"personal_assistant_server/internal/user/model"
)

// TestAITools 验证真实注册表工具与 HTTP 共用持久化和权限；参数：t 为测试上下文；返回值：无。
func TestAITools(t *testing.T) {
	s := fixture(t)
	executor := capability.NewExecutor(capability.NewRegistry(Definitions(s)...))
	ctx := context.Background()
	for _, def := range executor.Definitions() {
		if !json.Valid(def.InputSchema) {
			t.Fatalf("无效 Schema %s", def.Name)
		}
	}
	out, err := executor.Invoke(ctx, capability.Actor{UserID: 1}, "task_list.create", json.RawMessage(`{"changes":{"name":"AI 清单"}}`))
	if err != nil {
		t.Fatal(err)
	}
	list := out.(domain.List)
	raw, _ := json.Marshal(map[string]any{"changes": map[string]any{"title": "AI 任务", "listId": list.ID}})
	if _, err = executor.Invoke(ctx, capability.Actor{UserID: 1}, "task.create", raw); err != nil {
		t.Fatal(err)
	}
	if len(run(t, s, "task.list", 0, nil).([]domain.Task)) != 1 {
		t.Fatal("工具未持久化")
	}
	if _, err = executor.Invoke(ctx, capability.Actor{UserID: 2}, "task.create", raw); !errors.Is(err, service.ErrNotFound) {
		t.Fatalf("AI 越权: %v", err)
	}
	events := run(t, s, "task.events", 0, nil).([]domain.Event)
	if len(events) != 2 || events[0].Source != "ai" {
		t.Fatalf("AI 来源未记录: %+v", events)
	}
}

// fixture 创建隔离数据库和两名用户；参数：t 为测试上下文；返回值：业务服务，测试结束关闭连接，不访问生产数据。
func fixture(t *testing.T) *service.Service {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "tasks.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.User{}, &domain.List{}, &domain.Task{}, &domain.Event{}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []model.User{{ID: 1, Account: "one"}, {ID: 2, Account: "two"}} {
		if err = db.Create(&u).Error; err != nil {
			t.Fatal(err)
		}
	}
	// 清理回调关闭测试连接；参数：无；返回值：无，关闭错误令测试失败。
	t.Cleanup(func() {
		conn, err := db.DB()
		if err == nil {
			err = conn.Close()
		}
		if err != nil {
			t.Error(err)
		}
	})
	return service.NewService(db)
}

// run 执行测试命令；参数：t、s 为测试与服务，op 为操作，id 为目标，changes 为字段；返回值：结果，失败终止测试。
func run(t *testing.T, s *service.Service, op string, id uint64, changes any) any {
	t.Helper()
	raw, err := json.Marshal(changes)
	if err != nil {
		t.Fatal(err)
	}
	out, err := s.Execute(context.Background(), capability.Actor{UserID: 1}, op, service.Input{ID: id, Changes: raw}, "http")
	if err != nil {
		t.Fatal(err)
	}
	return out
}
