// 文件职责：封装记账模块更新字段的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// UpdateAccount 保存部分字段；参数：tx 为事务，owner 和 id 限定归属及目标，fields 为服务层验证后的数据库列白名单 map；返回值：数据库错误或 nil；显式零值会写入，空 map 不覆盖其他字段。
func UpdateAccount(tx *gorm.DB, owner, id uint64, fields map[string]any) error {
	return tx.Model(&domain.Account{}).Where("owner_id = ? AND id = ?", owner, id).Updates(fields).Error
}

// UpdateTransaction 保存部分字段；参数：tx 为事务，owner 和 id 限定归属及目标，fields 为服务层验证后的数据库列白名单 map；返回值：数据库错误或 nil；显式零值会写入，空 map 不覆盖其他字段。
func UpdateTransaction(tx *gorm.DB, owner, id uint64, fields map[string]any) error {
	return tx.Model(&domain.Transaction{}).Where("owner_id = ? AND id = ?", owner, id).Updates(fields).Error
}

// UpdatePendingInstallmentChildren 更新待入账分期资料，保留零值；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 主账单 ID，fields 为 经过白名单验证的待更新列，仅含提交字段；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func UpdatePendingInstallmentChildren(db *gorm.DB, owner uint64, parent uint64, fields map[string]any) error {
	return db.Model(&domain.Transaction{}).Where("owner_id = ? AND installment_parent_id = ? AND status = ?", owner, parent, "pending").Updates(fields).Error
}

// UpdatePreset 保存预设部分字段；参数：db 为事务，owner 为可信归属，id 为预设主键，fields 为已通过白名单和业务校验的数据库列 map；返回值：数据库错误或 nil；零值正常写入，其他字段保持不变。
func UpdatePreset(db *gorm.DB, owner, id uint64, fields map[string]any) error {
	return db.Model(&domain.Preset{}).Where("owner_id = ? AND id = ?", owner, id).Updates(fields).Error
}

// UpdateLoanRevision 按版本保存贷款计划；参数：db 为事务，owner 为归属，id 为账户，revision 为预期旧版本，fields 为验证后的列白名单；返回值：影响行数及数据库错误；0 行由业务层判为并发冲突，错误由外层回滚。
func UpdateLoanRevision(db *gorm.DB, owner, id uint64, revision int, fields map[string]any) (int64, error) {
	result := db.Model(&domain.Account{}).Where("owner_id = ? AND id = ? AND loan_revision = ?", owner, id, revision).Updates(fields)
	return result.RowsAffected, result.Error
}
