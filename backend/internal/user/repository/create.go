// 文件职责：用户记录创建和唯一约束错误转换。

package repository

import (
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/model"
)

// Create 插入已经通过业务校验的用户并回填 ID。
// 参数：db 为非 nil 数据库；user 为非 nil 用户指针。返回值：写入错误，唯一键冲突统一为 gorm.ErrDuplicatedKey。
func Create(db *gorm.DB, user *model.User) error {
	// 统一持久化错误，供业务层判断。
	return normalizeError(db.Create(user).Error)
}
