// 文件职责：按主键删除已授权用户记录。

package repository

import (
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/model"
)

// Delete 物理删除指定用户，不处理其他业务模块的数据。
// 参数：db 为非 nil 数据库；id 为非零用户 ID。返回值：删除错误，无匹配记录返回 gorm.ErrRecordNotFound。
func Delete(db *gorm.DB, id uint64) error {
	// 删除满足业务范围约束的记录。
	result := db.Where("id = ?", id).Delete(&model.User{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}
