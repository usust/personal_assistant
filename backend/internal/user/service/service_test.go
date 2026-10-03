// 文件职责：用户业务规则与数据库隔离测试。

package service

import (
	"context"
	"errors"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/model"
	"testing"
)

// testUserService 创建独立内存数据库与测试服务。
// 参数：t 为测试上下文；返回值：已迁移用户表的服务；失败终止测试，结束时关闭数据库。
func testUserService(t *testing.T) *Service {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{TranslateError: true})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	// 清理回调关闭测试数据库；参数：无；返回值：无，释放连接。
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&model.User{}); err != nil {
		t.Fatal(err)
	}
	s, err := NewService(db)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// TestUserCRUD 验证注册规范化、重复账号、授权与部分更新的数据保留。
// 参数：t 为测试上下文；返回值：无；只写入独立测试数据库。
func TestUserCRUD(t *testing.T) {
	s := testUserService(t)
	ctx := context.Background()
	if err := s.EnsureDefaultAdmin(ctx, RegisterInput{Account: "admin", Password: "password123", Nickname: "管理员"}); err != nil {
		t.Fatal(err)
	}
	admin, err := s.Credentials(ctx, "admin")
	if err != nil {
		t.Fatal(err)
	}
	u, err := s.Register(ctx, RegisterInput{Account: " TEST_USER ", Password: "password123", Nickname: " 用户 "})
	if err != nil || u.Account != "test_user" || u.Nickname != "用户" || u.Role != model.RoleUser {
		t.Fatalf("注册失败: %v", err)
	}
	if _, err := s.Register(ctx, RegisterInput{Account: "test_user", Password: "password123", Nickname: "重复"}); !errors.Is(err, ErrAccountExists) {
		t.Fatalf("重复账号错误: %v", err)
	}
	if _, err := s.Update(ctx, u.ID, u.ID, map[string]any{"nickname": "越权"}); !errors.Is(err, ErrForbidden) {
		t.Fatal("普通用户被允许修改")
	}
	updated, err := s.Update(ctx, admin.ID, u.ID, map[string]any{"nickname": "新昵称"})
	if err != nil || updated.Account != u.Account || updated.Role != u.Role || updated.PasswordHash != u.PasswordHash {
		t.Fatalf("单字段更新覆盖其他数据: %v", err)
	}
	updated, err = s.Update(ctx, admin.ID, u.ID, map[string]any{"nickname": "多字段", "account": " RENAMED "})
	if err != nil || updated.Account != "renamed" || updated.Nickname != "多字段" {
		t.Fatalf("多字段更新失败: %v", err)
	}
	for _, input := range []map[string]any{{"nickname": ""}, {"nickname": nil}, {"id": uint64(10)}, {"password": "short"}} {
		if _, err := s.Update(ctx, admin.ID, u.ID, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("无效更新未被拒绝: %v", err)
		}
	}
	if _, err := s.Update(ctx, admin.ID, u.ID, map[string]any{"account": "admin"}); !errors.Is(err, ErrAccountExists) {
		t.Fatalf("重复账号更新错误: %v", err)
	}
	current, err := s.Current(ctx, u.ID)
	if err != nil || current.Account != "renamed" || current.PasswordHash != "" {
		t.Fatalf("公开查询或更新回滚失败: %v", err)
	}
	credentials, err := s.Credentials(ctx, " RENAMED ")
	if err != nil || credentials.PasswordHash != u.PasswordHash {
		t.Fatalf("凭证查询失败: %v", err)
	}
	if err := s.Delete(ctx, u.ID, u.ID); !errors.Is(err, ErrForbidden) {
		t.Fatal("普通用户被允许删除")
	}
	if err := s.Delete(ctx, admin.ID, u.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Current(ctx, u.ID); !errors.Is(err, ErrUserNotFound) {
		t.Fatalf("删除后仍可查询: %v", err)
	}
}
