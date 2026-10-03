// 文件职责：在事务内按管理范围更新白名单字段。

package repository

import (
	"errors"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"personal_assistant_server/internal/aiconfig/model"
)

// UpdateConfig 事务内按管理范围更新并返回配置。
// 参数：db 为绑定上下文的数据库，actorID 为可信身份，admin 为当前管理员状态，id 为配置 ID，fields 为服务校验后的白名单 map。
// 返回值：最新记录及数据库错误；不存在或无管理权限返回 gorm.ErrRecordNotFound；空 map 不更新。
func UpdateConfig(db *gorm.DB, actorID uint64, admin bool, id uint, fields map[string]any) (*model.AIProviderConfig, error) {
	var result model.AIProviderConfig
	// 回调参数 tx 为事务连接；返回值：错误回滚，nil 提交；关闭 SQL 日志避免泄露密钥。
	err := db.Session(&gorm.Session{Logger: logger.Default.LogMode(logger.Silent)}).Transaction(func(tx *gorm.DB) error {
		var row model.AIProviderConfig
		query := tx.Model(&model.AIProviderConfig{}).Where("id = ?", id)
		// 根据用户角色选择对应的访问范围。
		if admin {
			// 将业务筛选条件加入数据库查询。
			query = query.Where("(owner_type = ? AND owner_id = ?) OR owner_type = ?", model.OwnerTypeUser, actorID, model.OwnerTypeSystem)
		} else {
			// 将业务筛选条件加入数据库查询。
			query = query.Where("owner_type = ? AND owner_id = ?", model.OwnerTypeUser, actorID)
		}
		// 读取满足条件的目标记录。
		if e := query.First(&row).Error; errors.Is(e, gorm.ErrRecordNotFound) {
			return gorm.ErrRecordNotFound
		} else if e != nil {
			return e
		}
		if len(fields) > 0 {
			// 仅写入本次经过校验的变更字段。
			if e := tx.Model(&model.AIProviderConfig{}).Where("id = ?", row.ID).Updates(fields).Error; e != nil {
				return e
			}
		}
		// 读取满足条件的目标记录。
		if e := tx.First(&row, id).Error; e != nil {
			return e
		}
		// 返回持久化记录，公开摘要转换由服务层负责。
		result = row
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}
