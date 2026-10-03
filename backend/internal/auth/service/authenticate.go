// 文件职责：验证令牌并复核用户是否仍然存在，避免已删除身份继续使用有效令牌。

package service

import (
	"context"
	"errors"
	userservice "personal_assistant_server/internal/user/service"
)

// Authenticate 验证 JWT 并检查用户当前是否仍然存在。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；raw 为去掉 Bearer 前缀的 token。
// 返回值：可信用户 ID 及错误；无效或已删除身份返回 ErrUnauthorized，数据库故障保留原始错误。
func (s *Service) Authenticate(ctx context.Context, raw string) (uint64, error) {
	// 验证凭证是否仍然有效。
	id, err := s.tokens.Verify(raw)
	if err != nil {
		return 0, ErrUnauthorized
	}
	// 读取当前用户的业务信息。
	if _, err := s.users.Current(ctx, id); err != nil {
		// 区分预期错误与需要继续上报的异常。
		if errors.Is(err, userservice.ErrUserNotFound) {
			return 0, ErrUnauthorized
		}
		return 0, err
	}
	return id, nil
}
