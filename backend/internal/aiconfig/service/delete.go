// 文件职责：授权配置删除并转换仓储错误。

package service

import (
	"context"
	"errors"
	"gorm.io/gorm"
	"personal_assistant_server/internal/aiconfig/repository"
)

// Delete 删除本人服务或管理员系统服务，共享使用不授予删除权。
// 接收者：s 为已初始化服务。
// 参数：ctx 为调用上下文，actorID 为可信身份，id 为正数服务 ID；返回值：身份、权限或数据库错误，成功永久删除记录与密钥。
func (s *Service) Delete(ctx context.Context, actorID uint64, id uint) error {
	// 读取当前用户的业务信息。
	actor, err := s.users.Current(ctx, actorID)
	if err != nil {
		return err
	}
	// 仓储在 DELETE 条件中校验归属，避免检查与删除分离。
	err = repository.DeleteConfig(s.db.WithContext(ctx), actorID, actor.Role.IsAdmin(), id)
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return ErrForbidden
	}
	return err
}
