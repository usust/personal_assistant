// 文件职责：保存配置并关闭 SQL 日志保护密钥。

package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"personal_assistant_server/internal/aiconfig/model"
)

// CreateConfig 插入已由业务层构造的配置，每次创建独立记录。
// 参数：db 为非 nil 数据库；row 为非 nil 模型，成功回填 ID 和时间；返回值：数据库错误，SQL 日志关闭避免输出密钥。
func CreateConfig(db *gorm.DB, row *model.AIProviderConfig) error {
	// 保存新建的业务记录。
	return db.Session(&gorm.Session{Logger: logger.Default.LogMode(logger.Silent)}).Create(row).Error
}
