// 文件职责：用户部分字段 map 更新与唯一约束错误转换。

package repository

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"personal_assistant_server/internal/user/model"
)

// Update 在事务中锁定用户，仅更新白名单 map 中实际提交的字段。
// 参数：db 为非 nil 数据库；id 为目标用户 ID；fields 必须由服务层校验，不接受原始客户端 map。
// 返回值：更新后的用户及错误；不存在返回 gorm.ErrRecordNotFound，冲突返回 gorm.ErrDuplicatedKey。
func Update(db *gorm.DB, id uint64, fields map[string]any) (*model.User, error) {
	var user model.User
	// 事务回调锁定、更新并重新读取同一用户，避免响应与本次修改不一致。
	// 参数：tx 为当前事务；返回值：任一步骤错误触发回滚，nil 提交。
	err := db.Transaction(func(tx *gorm.DB) error {
		// 读取满足条件的目标记录。
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, id).Error; err != nil {
			return err
		}
		// 仅写入本次经过校验的变更字段。
		if err := tx.Model(&user).Updates(fields).Error; err != nil {
			return err
		}
		// 读取满足条件的目标记录。
		return tx.First(&user, id).Error
	})
	if err != nil {
		// 统一持久化错误，供业务层判断。
		return nil, normalizeError(err)
	}
	return &user, nil
}
