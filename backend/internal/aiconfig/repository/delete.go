// 文件职责：在 DELETE 条件中限制配置管理范围。

package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"personal_assistant_server/internal/aiconfig/model"
)

// DeleteConfig 按管理范围删除配置。
// 参数：db 为绑定上下文的数据库，actorID 为可信身份，admin 为管理员状态，id 为配置 ID。
// 返回值：数据库错误；未找到或无管理权限返回 gorm.ErrRecordNotFound；成功物理删除配置及密钥。
func DeleteConfig(db *gorm.DB, actorID uint64, admin bool, id uint) error {
	// 在同一 DELETE 中校验归属，避免先查询后删除期间的权限变化。
	query := db.Session(&gorm.Session{Logger: logger.Default.LogMode(logger.Silent)}).Where("id = ?", id)
	// 根据用户角色选择对应的访问范围。
	if admin {
		// 将业务筛选条件加入数据库查询。
		query = query.Where("(owner_type = ? AND owner_id = ?) OR owner_type = ?", model.OwnerTypeUser, actorID, model.OwnerTypeSystem)
	} else {
		// 将业务筛选条件加入数据库查询。
		query = query.Where("owner_type = ? AND owner_id = ?", model.OwnerTypeUser, actorID)
	}
	// 删除满足业务范围约束的记录。
	result := query.Delete(&model.AIProviderConfig{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
