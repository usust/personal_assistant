// 文件职责：定义用户持久化结构与角色语义，为认证和业务授权提供基础模型。

package model

import "time"

// Role 表示用户角色。
type Role string

const (
	RoleUser     Role = "user"      // 普通用户
	RoleAdmin    Role = "admin"     // 普通管理员
	RoleSysAdmin Role = "sys_admin" // 系统管理员
)

// User 保存用户账号资料。
// ID 为用户唯一标识（主键）；Account 为登录账号，具有唯一索引。
// PasswordHash 为密码哈希，不会出现在 JSON 响应中。
// Nickname 为用户昵称；Role 为角色，默认为普通用户。
// CreatedAt 为创建时间；UpdatedAt 为最后更新时间，由 GORM 自动维护。
type User struct {
	ID           uint64    `gorm:"primaryKey" json:"id"`
	Account      string    `gorm:"size:64;not null;uniqueIndex" json:"account"`
	PasswordHash string    `gorm:"size:255;not null" json:"-"`
	Nickname     string    `gorm:"size:64;not null" json:"nickname"`
	Role         Role      `gorm:"size:32;not null;default:user" json:"role"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// IsAdmin 判断角色是否具有当前产品定义的管理员权限。
// 接收者：r 为数据库读取的角色；参数：无；返回值：admin 或 sys_admin 为 true，其他值为 false。
func (r Role) IsAdmin() bool { return r == RoleAdmin || r == RoleSysAdmin }
