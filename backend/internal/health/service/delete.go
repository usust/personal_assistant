// 文件职责：执行健康汇总同步、授权分析或清理业务。
package service

import (
	"context"

	"personal_assistant_server/internal/health/repository"
)

// Clear 删除个人健康快照及报告；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份；返回值：公开错误或 nil；不删除手机原始数据。
func (s *Service) Clear(ctx context.Context, uid uint64) error {
	// 仓储保证报告与日汇总删除的原子性。
	if err := repository.Clear(s.db.WithContext(ctx), uid); err != nil {
		return &OperationError{500, "删除健康数据失败"}
	}
	return nil
}
