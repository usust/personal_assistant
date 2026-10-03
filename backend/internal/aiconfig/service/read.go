// 文件职责：查询可用配置与模型调用连接。

package service

import (
	"context"
	"errors"
	"gorm.io/gorm"
	"personal_assistant_server/internal/aiconfig/model"
	"personal_assistant_server/internal/aiconfig/repository"
)

// Connection 保存模型调用的最小连接信息，密钥禁止序列化。
type Connection struct {
	BaseURL   string
	ModelName string
	APIKey    string `json:"-"`
}

// List 返回共享、本人拥有及管理员可用的系统私有配置，不含密钥。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 为可信身份。
// 返回值：配置元数据及身份或查询错误，管理员不获得其他用户或群体私有配置。
func (s *Service) List(ctx context.Context, actorID uint64) ([]model.ProviderConfigSummary, error) {
	// 读取当前用户的业务信息。
	actor, err := s.users.Current(ctx, actorID)
	if err != nil {
		return nil, err
	}
	// 读取可展示的模型配置列表。
	return repository.ListConfigs(s.db.WithContext(ctx), actorID, actor.Role.IsAdmin())
}

// GetUsable 按 ID 获取本次模型调用所需配置，不通过全量列表判断权限。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 为可信身份；id 为配置 ID。
// 返回值：最小连接信息及错误；不存在或无权统一返回 ErrForbidden，包含的密钥不得记录或输出。
func (s *Service) GetUsable(ctx context.Context, actorID uint64, id uint) (Connection, error) {
	// 读取当前用户的业务信息。
	actor, err := s.users.Current(ctx, actorID)
	if err != nil {
		return Connection{}, err
	}
	// 确认所选模型配置可供当前用户使用。
	row, err := repository.UsableConfig(s.db.WithContext(ctx), actorID, actor.Role.IsAdmin(), id)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Connection{}, ErrForbidden
	}
	if err != nil {
		return Connection{}, err
	}
	return Connection{BaseURL: row.BaseURL, ModelName: row.ModelName, APIKey: row.APIKey}, nil
}
