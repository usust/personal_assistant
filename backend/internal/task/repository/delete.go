// 文件职责：封装任务模块删除记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
)

// DeleteTasks 删除选中节点；参数：tx 为事务，owner 为可信归属，ids 为服务层计算的节点集合；返回值：数据库错误或 nil；空集合无副作用。
func DeleteTasks(tx *gorm.DB, owner uint64, ids []uint64) error {
	if len(ids) == 0 {
		return nil
	}
	return tx.Where("owner_id = ? AND id IN ?", owner, ids).Delete(&domain.Task{}).Error
}

// DeleteList 删除清单及其任务；参数：tx 为当前事务，owner 为可信归属，id 为已经验证的清单；返回值：数据库错误或 nil；两次删除共用事务。
func DeleteList(tx *gorm.DB, owner, id uint64) error {
	if err := tx.Where("owner_id = ? AND list_id = ?", owner, id).Delete(&domain.Task{}).Error; err != nil {
		return err
	}
	return tx.Where("owner_id = ? AND id = ?", owner, id).Delete(&domain.List{}).Error
}
