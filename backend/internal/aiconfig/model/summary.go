// 文件职责：定义无密钥的配置公开摘要。

package model

import (
	"time"
)

// ProviderConfigSummary 仅用于列表响应，不参与迁移，也不包含密钥。
// 显式列出允许返回的字段，避免配置模型新增敏感字段后被自动暴露。
type ProviderConfigSummary struct {
	ID           uint       `json:"id"`
	OwnerType    OwnerType  `json:"owner_type"`
	OwnerID      *uint64    `json:"owner_id"`
	Visibility   Visibility `json:"visibility"`
	CreatedBy    *uint64    `json:"created_by"`
	IsSelected   bool       `json:"is_selected"`
	Name         string     `json:"name"`
	ProviderName string     `json:"provider_name"`
	BaseURL      string     `json:"base_url"`
	ModelName    string     `json:"model_name"`
	UpdatedAt    time.Time  `json:"updated_at"`
}
