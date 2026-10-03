// 文件职责：定义模型连接配置持久化模型与归属语义。

package model

import (
	"time"
)

// OwnerType 表示配置归属方的类型，与是否共享独立。
type OwnerType string

const (
	OwnerTypeSystem OwnerType = "system" // 系统所有，兼容现有全局配置。
	OwnerTypeUser   OwnerType = "user"   // 用户所有。
	OwnerTypeGroup  OwnerType = "group"  // 群体所有。
)

// Visibility 表示配置的使用范围，不授予编辑配置或读取密钥的权限。
type Visibility string

const (
	VisibilityPrivate Visibility = "private" // 仅归属方：所属用户、所属群体成员或系统管理方。
	VisibilityShared  Visibility = "shared"  // 允许所有登录用户使用。
)

// AIProviderConfig 统一定义 AI 配置，数据库保存和后端读取共用此模型。
// ID 唯一标识一条配置；同一个 ProviderName 可以创建多条不同名称、模型或密钥的配置。
// 业务含义：system 对应空 OwnerID，user/group 对应归属方 ID；字段类型本身不强制这些约束。
// CreatedBy 为创建者用户 ID，与归属方独立；历史数据或系统自动创建时可为空。
// 使用权限由 Service 查询范围限制，创建者由 Service 赋值；创建归属策略沿用旧行为，未增加新的授权校验。
// APIKey 仅供后端调用模型，禁止 JSON 序列化；UpdatedAt 由 GORM 自动维护。
type AIProviderConfig struct {
	ID           uint       `gorm:"primaryKey" json:"id"`
	OwnerType    OwnerType  `gorm:"size:16;not null;default:system;index:idx_ai_config_owner,priority:1" json:"owner_type"`
	OwnerID      *uint64    `gorm:"index:idx_ai_config_owner,priority:2" json:"owner_id"`
	Visibility   Visibility `gorm:"size:16;not null;default:private" json:"visibility"`
	CreatedBy    *uint64    `json:"created_by"`
	IsSelected   bool       `gorm:"not null;default:false" json:"is_selected"` // 是否选中，默认未选中。
	Name         string     `gorm:"size:255;not null" json:"name"`
	ProviderName string     `gorm:"column:provider_name;size:32;not null;index" json:"provider_name"`
	BaseURL      string     `gorm:"size:2048;not null" json:"base_url"`
	ModelName    string     `gorm:"column:model_name;size:255;not null" json:"model_name"`
	APIKey       string     `gorm:"type:text;not null" json:"-"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

// TableName 保留迁移前的表名，目录调整不创建新业务表。
// 接收者：配置模型，允许零值；参数：无；返回值：固定表名；无副作用。
func (AIProviderConfig) TableName() string { return "setting_ai_configurations" }
