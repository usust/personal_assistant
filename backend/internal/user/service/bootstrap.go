// 文件职责：在空库初始化默认管理员，集中处理启动期管理员创建规则。

package service

import (
	"context"
	"fmt"

	"gorm.io/gorm"

	"personal_assistant_server/internal/user/model"
	"personal_assistant_server/internal/user/repository"
)

// EnsureDefaultAdmin 在空用户表中创建默认系统管理员，已有任何用户时跳过。
// 接收者：s 为已初始化且已迁移用户表的服务；参数：ctx 控制初始化；input 为启动层提供的账号信息。
// 返回值：校验或数据库错误，失败回滚；成功为 nil。本方法仅供启动层调用，不暴露为 HTTP 或工具。
func (s *Service) EnsureDefaultAdmin(ctx context.Context, input RegisterInput) error {
	// 事务回调将空表检查与创建放在同一事务，唯一索引仍负责防止相同账号的并发插入。
	// 参数：tx 为当前事务；返回值：nil 提交，其他错误回滚并阻止启动。
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// 确认用户表是否需要启动初始化。
		count, err := repository.Count(tx)
		if err != nil {
			// 为失败补充当前操作的错误上下文。
			return fmt.Errorf("检查用户表失败: %w", err)
		}
		if count > 0 {
			return nil
		}
		// 按指定角色创建用户并处理密码。
		if _, err := createUser(tx, input, model.RoleSysAdmin); err != nil {
			// 为失败补充当前操作的错误上下文。
			return fmt.Errorf("创建默认管理员失败，请检查 default_user 配置: %w", err)
		}
		return nil
	})
}
