// 文件职责：定义创建输入、创建配置与公开摘要转换。

package service

import (
	"context"
	"personal_assistant_server/internal/aiconfig/model"
	"personal_assistant_server/internal/aiconfig/repository"
)

// summarize 将持久化模型转换为明确的响应白名单。
// 参数：row 为非 nil 已保存模型；返回值：不含密钥的元数据副本；无副作用。
func summarize(row *model.AIProviderConfig) model.ProviderConfigSummary {
	return model.ProviderConfigSummary{ID: row.ID, OwnerType: row.OwnerType, OwnerID: row.OwnerID, Visibility: row.Visibility, CreatedBy: row.CreatedBy, IsSelected: row.IsSelected, Name: row.Name, ProviderName: row.ProviderName, BaseURL: row.BaseURL, ModelName: row.ModelName, UpdatedAt: row.UpdatedAt}
}

// CreateInput 只包含允许提交的配置字段；主键、创建者和更新时间由服务端维护。
// 保留现有 snake_case 协议；APIKey 仅为输入，不复用此类型生成响应。
type CreateInput struct {
	OwnerType    model.OwnerType  `json:"owner_type"`
	OwnerID      *uint64          `json:"owner_id"`
	Visibility   model.Visibility `json:"visibility"`
	IsSelected   bool             `json:"is_selected"`
	Name         string           `json:"name"`
	ProviderName string           `json:"provider_name"`
	BaseURL      string           `json:"base_url"`
	ModelName    string           `json:"model_name"`
	APIKey       string           `json:"api_key"`
}

// Create 创建配置并返回不含密钥的摘要；本次结构调整沿用已有归属与共享字段语义。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 为认证所得创建者；input 为已解析创建字段。
// 返回值：新配置摘要及身份或数据库错误；主键和更新时间由数据库生成，创建者不接受客户端指定。
func (s *Service) Create(ctx context.Context, actorID uint64, input CreateInput) (model.ProviderConfigSummary, error) {
	// 读取当前用户的业务信息。
	if _, err := s.users.Current(ctx, actorID); err != nil {
		return model.ProviderConfigSummary{}, err
	}
	// 持久化模型与请求 DTO 分离，避免模型新增服务器字段后自动开放客户端写入。
	row := &model.AIProviderConfig{OwnerType: input.OwnerType, OwnerID: input.OwnerID, Visibility: input.Visibility, CreatedBy: &actorID, IsSelected: input.IsSelected, Name: input.Name, ProviderName: input.ProviderName, BaseURL: input.BaseURL, ModelName: input.ModelName, APIKey: input.APIKey}
	// 保存新的模型连接配置。
	if err := repository.CreateConfig(s.db.WithContext(ctx), row); err != nil {
		return model.ProviderConfigSummary{}, err
	}
	// 将配置记录转换为对外摘要。
	return summarize(row), nil
}
