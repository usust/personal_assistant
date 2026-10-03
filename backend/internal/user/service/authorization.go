// 文件职责：管理员权限和角色变更规则。

package service

import (
	"context"
	"errors"
)

// RequireAdmin 检查数据库中的当前角色，防止旧登录凭证保留已撤销的管理员权限。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 只能来自认证结果。
// 返回值：允许时为 nil，身份不存在或角色不足为 ErrForbidden，查询失败返回原始错误。
func (s *Service) RequireAdmin(ctx context.Context, actorID uint64) error {
	// 读取当前用户的业务信息。
	user, err := s.Current(ctx, actorID)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, ErrUserNotFound) {
		return ErrForbidden
	}
	if err != nil {
		return err
	}
	// 根据用户角色选择对应的访问范围。
	if !user.Role.IsAdmin() {
		return ErrForbidden
	}
	return nil
}
