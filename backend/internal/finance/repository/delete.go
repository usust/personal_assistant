// 文件职责：封装记账模块删除记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// DeletePreset 删除预设，保留历史生成流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 已验证预设主键；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func DeletePreset(db *gorm.DB, owner uint64, id uint64) error {
	return db.Where("owner_id = ? AND id = ?", owner, id).Delete(&domain.Preset{}).Error
}

// MarkTransactionDeleted 软删除主流水及附属流水，保留审计与幂等键；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 已经冲销余额的主流水 ID；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func MarkTransactionDeleted(db *gorm.DB, owner uint64, id uint64) error {
	return db.Model(&domain.Transaction{}).Where("owner_id = ? AND (id = ? OR refund_parent_id = ? OR rebate_parent_id = ?)", owner, id, id, id).Updates(map[string]any{"status": "deleted"}).Error
}
