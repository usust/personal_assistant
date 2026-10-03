// 文件职责：封装任务模块更新字段的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
)

// UpdateTask 保存部分字段；参数：tx 为事务，owner 和 id 限定归属及目标，fields 为服务层验证后的数据库列白名单 map；返回值：数据库错误或 nil；显式零值会写入，空 map 不覆盖其他字段。
func UpdateTask(tx *gorm.DB, owner, id uint64, fields map[string]any) error {
	return tx.Model(&domain.Task{}).Where("owner_id = ? AND id = ?", owner, id).Updates(fields).Error
}

// UpdateList 保存部分字段；参数：tx 为事务，owner 和 id 限定归属及目标，fields 为服务层验证后的数据库列白名单 map；返回值：数据库错误或 nil；显式零值会写入，空 map 不覆盖其他字段。
func UpdateList(tx *gorm.DB, owner, id uint64, fields map[string]any) error {
	return tx.Model(&domain.List{}).Where("owner_id = ? AND id = ?", owner, id).Updates(fields).Error
}
