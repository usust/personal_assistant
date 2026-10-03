// 文件职责：读写离线同步幂等回执，与业务变更共用事务。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// ReadReceipt 读取用户的同步回执；参数：tx 为持有用户锁的事务，owner 为归属，operationID 为稳定标识；返回值：回执及数据库错误，无写入。
func ReadReceipt(tx *gorm.DB, owner uint64, operationID string) (domain.SyncReceipt, error) {
	var row domain.SyncReceipt
	err := tx.Where("owner_id = ? AND operation_id = ?", owner, operationID).First(&row).Error
	return row, err
}

// CreateReceipt 插入成功回执；参数：tx 为业务事务，row 为已完成指纹及响应序列化的回执；返回值：数据库错误或 nil；失败由外层回滚业务变更。
func CreateReceipt(tx *gorm.DB, row *domain.SyncReceipt) error { return tx.Create(row).Error }
