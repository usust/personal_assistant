// 文件职责：校验实际提交字段并构建白名单更新 map。

package service

import (
	"context"
	"errors"
	"gorm.io/gorm"
	"net/url"
	"personal_assistant_server/internal/aiconfig/model"
	"personal_assistant_server/internal/aiconfig/repository"
	"strings"
	"unicode/utf8"
)

// Update 局部修改本人配置或管理员系统配置；共享仅授予使用权。
// 接收者：s 为已初始化服务。
// 参数：ctx 为上下文，actorID 为可信登录身份，id 为正数配置 ID，input 为字段白名单。
// 返回值：不含密钥的最新摘要及校验、权限或数据库错误；空请求不修改更新时间。
func (s *Service) Update(ctx context.Context, actorID uint64, id uint, input UpdateInput) (model.ProviderConfigSummary, error) {
	// 读取当前用户的业务信息。
	actor, err := s.users.Current(ctx, actorID)
	if err != nil {
		return model.ProviderConfigSummary{}, err
	}
	fields := map[string]any{}
	// 只转换实际提交字段，保留 false，拒绝空连接字段及未知提供商。
	for column, value := range map[string]*string{"name": input.Name, "provider_name": input.ProviderName, "base_url": input.BaseURL, "model_name": input.ModelName, "api_key": input.APIKey} {
		if value == nil {
			continue
		}
		// 规范化输入，避免首尾空白影响校验。
		v := strings.TrimSpace(*value)
		if v == "" {
			return model.ProviderConfigSummary{}, ErrInvalid
		}
		// 按字符数校验文本长度，避免中文被按字节误计。
		if (column == "name" || column == "model_name") && utf8.RuneCountInString(v) > 255 {
			return model.ProviderConfigSummary{}, ErrInvalid
		}
		if column == "provider_name" {
			valid := false
			// 取得配置界面的提供商目录。
			for _, provider := range Providers() {
				if provider.ID == v {
					valid = true
				}
			}
			if !valid {
				return model.ProviderConfigSummary{}, ErrInvalid
			}
		}
		if column == "base_url" {
			// 解析外部服务地址，供地址规则校验。
			u, e := url.Parse(v)
			// 取得外部地址主机名用于访问校验。
			if e != nil || len(v) > 2048 || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" {
				return model.ProviderConfigSummary{}, ErrInvalid
			}
		}
		fields[column] = v
	}
	if input.Visibility != nil {
		if *input.Visibility != model.VisibilityPrivate && *input.Visibility != model.VisibilityShared {
			return model.ProviderConfigSummary{}, ErrInvalid
		}
		fields["visibility"] = *input.Visibility
	}
	if input.IsSelected != nil {
		fields["is_selected"] = *input.IsSelected
	}
	// 仓储在同一事务内限制归属、更新白名单并返回最新记录。
	row, err := repository.UpdateConfig(s.db.WithContext(ctx), actorID, actor.Role.IsAdmin(), id, fields)
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return model.ProviderConfigSummary{}, ErrForbidden
	}
	if err != nil {
		return model.ProviderConfigSummary{}, err
	}
	return summarize(row), nil
}

// UpdateInput 区分未提交字段与零值；密钥只允许替换，不返回客户端。
type UpdateInput struct {
	Name         *string           `json:"name"`
	ProviderName *string           `json:"provider_name"`
	BaseURL      *string           `json:"base_url"`
	ModelName    *string           `json:"model_name"`
	APIKey       *string           `json:"api_key"`
	Visibility   *model.Visibility `json:"visibility"`
	IsSelected   *bool             `json:"is_selected"`
}
