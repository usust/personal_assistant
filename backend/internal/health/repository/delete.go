// 文件职责：按用户隔离读写健康数据。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/health/model"
)

// Clear 原子删除本人健康数据与报告。
// 参数：db 为上下文数据库，uid 为可信身份；返回值：数据库错误；失败回滚，不影响手机 HealthKit。
func Clear(db *gorm.DB, uid uint64) error {
	// 事务回调参数 tx 为当前事务；返回数据库错误，任一步失败回滚全部删除。
	return db.Transaction(func(tx *gorm.DB) error {
		// 删除满足业务范围约束的记录。
		if e := tx.Where("user_id = ?", uid).Delete(&domain.Report{}).Error; e != nil {
			return e
		}
		// 删除满足业务范围约束的记录。
		return tx.Where("user_id = ?", uid).Delete(&domain.Day{}).Error
	})
}
