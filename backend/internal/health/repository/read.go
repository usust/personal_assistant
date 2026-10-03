// 文件职责：按用户隔离读写健康数据。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/health/model"
)

// Days 查询个人最近 30 条日汇总；参数：db 为上下文数据库，uid 为可信身份；返回值：非 nil 列表和查询错误；无写入。
func Days(db *gorm.DB, uid uint64) ([]domain.Day, error) {
	rows := []domain.Day{}
	err := db.Where("user_id = ?", uid).Order("date DESC").Limit(30).Find(&rows).Error
	return rows, err
}

// Reports 查询个人最近 20 份报告；参数：db 为上下文数据库，uid 为可信身份；返回值：非 nil 列表及查询错误；无写入。
func Reports(db *gorm.DB, uid uint64) ([]domain.Report, error) {
	rows := []domain.Report{}
	err := db.Where("user_id = ?", uid).Order("id DESC").Limit(20).Find(&rows).Error
	return rows, err
}
