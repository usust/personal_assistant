// 文件职责：用户列表、主键、账号和角色查询。

package repository

import (
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/model"
)

// FindAll 查询全部公开用户资料。
// 参数：db 为已绑定请求上下文的非 nil 数据库；返回值：按 ID 升序的非 nil 切片及查询错误，不读取密码哈希。
func FindAll(db *gorm.DB) ([]model.User, error) {
	users := make([]model.User, 0)
	// 读取符合业务条件的记录集合。
	err := db.Omit("PasswordHash").Order("id ASC").Find(&users).Error
	return users, err
}

// FindByID 查询单个用户的公开资料和当前角色。
// 参数：db 为非 nil 数据库；id 为非零用户 ID。返回值：用户及错误，不存在时返回 gorm.ErrRecordNotFound。
func FindByID(db *gorm.DB, id uint64) (*model.User, error) {
	var user model.User
	// 读取满足条件的目标记录。
	err := db.Omit("PasswordHash").First(&user, id).Error
	return &user, err
}

// FindByAccount 读取认证所需的账号资料，包含密码哈希。
// 参数：db 为非 nil 数据库；account 为规范化账号。返回值：用户及错误；调用方不得记录密码哈希。
func FindByAccount(db *gorm.DB, account string) (*model.User, error) {
	var user model.User
	// 读取满足条件的目标记录。
	err := db.Where("account = ?", account).First(&user).Error
	return &user, err
}

// AccountExists 检查账号是否已被占用。
// 参数：db 为非 nil 数据库；account 为规范化账号。返回值：是否存在及数据库错误。
func AccountExists(db *gorm.DB, account string) (bool, error) {
	var count int64
	// 统计符合条件的业务记录。
	err := db.Model(&model.User{}).Where("account = ?", account).Count(&count).Error
	return count > 0, err
}

// Count 返回用户总数，供空库初始化判断使用。
// 参数：db 为非 nil 数据库或事务；返回值：用户数量及数据库错误。
func Count(db *gorm.DB) (int64, error) {
	var count int64
	// 统计符合条件的业务记录。
	err := db.Model(&model.User{}).Count(&count).Error
	return count, err
}
