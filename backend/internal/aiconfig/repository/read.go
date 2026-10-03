// 文件职责：按可见范围查询配置摘要与调用连接。

package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"personal_assistant_server/internal/aiconfig/model"
)

// accessibleQuery 构造当前用户可使用配置的 SQL 范围，供列表与按 ID 读取共同使用。
// 参数：db 为绑定上下文的非 nil 数据库；userID 为可信身份；admin 表示业务层确认的当前管理员角色。
// 返回值：限定共享、本人私有及管理员系统私有范围的查询；不会执行 SQL，不开放群体私有配置。
func accessibleQuery(db *gorm.DB, userID uint64, admin bool) *gorm.DB {
	scope := "visibility = ? OR (owner_type = ? AND owner_id = ?)"
	args := []any{model.VisibilityShared, model.OwnerTypeUser, userID}
	if admin {
		scope += " OR (owner_type = ? AND visibility = ?)"
		args = append(args, model.OwnerTypeSystem, model.VisibilityPrivate)
	}
	// 将业务筛选条件加入数据库查询。
	return db.Model(&model.AIProviderConfig{}).Where("("+scope+")", args...)
}

// ListConfigs 查询允许使用的配置元数据，在 SQL 层排除密钥。
// 参数：db 为非 nil 数据库；userID 和 admin 为服务端确定的权限信息；返回值：非 nil 列表及数据库错误。
func ListConfigs(db *gorm.DB, userID uint64, admin bool) ([]model.ProviderConfigSummary, error) {
	rows := make([]model.ProviderConfigSummary, 0)
	// 将查询结果映射为业务展示结构。
	err := accessibleQuery(db, userID, admin).Select("id", "owner_type", "owner_id", "visibility", "created_by", "is_selected", "name", "provider_name", "base_url", "model_name", "updated_at").Order("id").Scan(&rows).Error
	return rows, err
}

// UsableConfig 在同一查询中同时限制配置 ID 与访问范围，供模型调用读取密钥。
// 参数：db 为非 nil 数据库；userID、admin 为可信权限；id 为目标配置 ID。
// 返回值：配置与数据库错误；无权或不存在均返回 gorm.ErrRecordNotFound；查询日志关闭以保护密钥。
func UsableConfig(db *gorm.DB, userID uint64, admin bool, id uint) (*model.AIProviderConfig, error) {
	var row model.AIProviderConfig
	// 读取满足条件的目标记录。
	err := accessibleQuery(db.Session(&gorm.Session{Logger: logger.Default.LogMode(logger.Silent)}), userID, admin).Where("id = ?", id).First(&row).Error
	return &row, err
}
