// 文件职责：用户删除约束与持久化编排。

package service

import (
	"context"
	"errors"
	"fmt"
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/repository"
)

// Delete 校验操作者权限并删除用户，HTTP 与工具入口共用此授权边界。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 为可信操作者；id 为目标用户 ID。
// 返回值：授权、参数或数据库错误；目标不存在返回 ErrUserNotFound，成功时为 nil；副作用为物理删除用户。
func (s *Service) Delete(ctx context.Context, actorID, id uint64) error {
	// 先确认管理员权限，再执行管理操作。
	if err := s.RequireAdmin(ctx, actorID); err != nil {
		return err
	}
	if id == 0 {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("%w：用户 ID 无效", ErrInvalidInput)
	}
	// 删除满足业务范围约束的记录。
	err := repository.Delete(s.db.WithContext(ctx), id)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return ErrUserNotFound
	}
	return err
}
