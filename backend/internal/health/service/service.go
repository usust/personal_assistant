// 文件职责：执行健康汇总同步、授权分析或清理业务。
package service

import (
	"gorm.io/gorm"

	aimodel "personal_assistant_server/internal/ai/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
)

// Service 持有健康业务的数据库、配置授权与模型依赖。
type Service struct {
	db      *gorm.DB
	configs *aiconfigservice.Service
	client  aimodel.Completer
}

// NewService 注入健康业务依赖；参数：db、configs、client 必须已初始化；返回值：服务；不访问数据库或网络。
func NewService(db *gorm.DB, configs *aiconfigservice.Service, client aimodel.Completer) *Service {
	return &Service{db: db, configs: configs, client: client}
}

// OperationError 保存公开状态和消息，隐藏内部错误。
type OperationError struct {
	Status  int
	Message string
}

// Error 返回可公开说明；接收者：e 为非 nil 错误；参数：无；返回值：说明；无副作用。
func (e *OperationError) Error() string { return e.Message }
