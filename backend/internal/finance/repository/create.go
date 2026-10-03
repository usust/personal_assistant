// 文件职责：封装记账模块创建记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// CreateAccount 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateAccount(tx *gorm.DB, row *domain.Account) error { return tx.Create(row).Error }

// CreateCategory 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateCategory(tx *gorm.DB, row *domain.Category) error { return tx.Create(row).Error }

// CreateTransaction 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateTransaction(tx *gorm.DB, row *domain.Transaction) error { return tx.Create(row).Error }

// CreateEvent 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateEvent(tx *gorm.DB, row *domain.Event) error { return tx.Create(row).Error }

// CreateSnapshot 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateSnapshot(tx *gorm.DB, row *domain.Snapshot) error { return tx.Create(row).Error }

// CreateCategories 批量补齐分类；参数：tx 为持有用户锁的事务，rows 为缺失分类；返回值：数据库错误或 nil；空集合无需写入。
func CreateCategories(tx *gorm.DB, rows []domain.Category) error {
	if len(rows) == 0 {
		return nil
	}
	return tx.CreateInBatches(&rows, 100).Error
}

// CreatePreset 创建预设并回填主键；参数：db 为 当前事务，row 为 已验证且包含可信归属的预设指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func CreatePreset(db *gorm.DB, row *domain.Preset) error { return db.Create(row).Error }
