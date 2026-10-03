// 文件职责：按用户隔离读写健康数据。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/health/model"
)

// CreateReport 保存已生成的报告并回填 ID。
// 参数：db 为上下文数据库，report 为非 nil 报告指针；返回值：写入错误；成功写入数据库。
func CreateReport(db *gorm.DB, report *domain.Report) error { return db.Create(report).Error }
