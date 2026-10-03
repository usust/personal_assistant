// 文件职责：封装任务模块创建记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
)

// CreateTask 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateTask(tx *gorm.DB, row *domain.Task) error { return tx.Create(row).Error }

// CreateList 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateList(tx *gorm.DB, row *domain.List) error { return tx.Create(row).Error }

// CreateEvent 插入记录；参数：tx 为当前事务，row 为已验证且含可信归属的记录指针；返回值：数据库错误或 nil；成功回填主键，失败由调用方回滚。
func CreateEvent(tx *gorm.DB, row *domain.Event) error { return tx.Create(row).Error }
