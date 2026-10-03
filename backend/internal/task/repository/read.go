// 文件职责：封装任务模块读取记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
)

// ReadTasks 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按sort_order, id排序。
func ReadTasks(tx *gorm.DB, owner uint64) ([]domain.Task, error) {
	rows := []domain.Task{}
	q := tx.Where("owner_id = ?", owner).Order("sort_order, id")
	err := q.Find(&rows).Error
	return rows, err
}

// ReadLists 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按id排序。
func ReadLists(tx *gorm.DB, owner uint64) ([]domain.List, error) {
	rows := []domain.List{}
	q := tx.Where("owner_id = ?", owner).Order("id")
	err := q.Find(&rows).Error
	return rows, err
}

// ReadEvents 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按id DESC排序。
func ReadEvents(tx *gorm.DB, owner uint64) ([]domain.Event, error) {
	rows := []domain.Event{}
	q := tx.Where("owner_id = ?", owner).Order("id DESC")
	q = q.Limit(100)
	err := q.Find(&rows).Error
	return rows, err
}

// ReadList 查询清单；参数：tx 为事务，owner 为可信归属，id 为目标 ID；返回值：清单及数据库错误；其他用户记录按不存在处理。
func ReadList(tx *gorm.DB, owner, id uint64) (domain.List, error) {
	var row domain.List
	err := tx.Where("owner_id = ? AND id = ?", owner, id).First(&row).Error
	return row, err
}
