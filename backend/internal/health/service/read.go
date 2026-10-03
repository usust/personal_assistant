// 文件职责：执行健康汇总同步、授权分析或清理业务。
package service

import (
	"context"

	domain "personal_assistant_server/internal/health/model"
	"personal_assistant_server/internal/health/repository"
)

// Overview 保存健康查询结果。
type Overview struct {
	Days    []domain.Day    `json:"days"`
	Reports []domain.Report `json:"reports"`
}

// Read 返回个人日汇总与报告；接收者：s 已初始化；参数：ctx 为请求上下文，uid 为可信身份；返回值：汇总及公开错误；无写入。
func (s *Service) Read(ctx context.Context, uid uint64) (Overview, error) {
	// 两组查询始终使用同一可信身份，避免跨用户泄露。
	days, err := repository.Days(s.db.WithContext(ctx), uid)
	if err != nil {
		return Overview{}, &OperationError{500, "读取健康数据失败"}
	}
	reports, err := repository.Reports(s.db.WithContext(ctx), uid)
	if err != nil {
		return Overview{}, &OperationError{500, "读取健康数据失败"}
	}
	return Overview{days, reports}, nil
}
