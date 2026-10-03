// 文件职责：定义配置服务、用户查询依赖与业务错误。

package service

import (
	"context"
	"errors"
	"gorm.io/gorm"
	usermodel "personal_assistant_server/internal/user/model"
)

// 拒绝本次操作：该 AI 配置不存在或无权使用。
var ErrForbidden = errors.New("该 AI 配置不存在或无权使用")

// UserReader 限定模型配置授权所需的用户查询能力，由调用方注入实现。
type UserReader interface {
	// Current 查询当前身份和角色；参数：ctx 为请求上下文，id 为可信用户 ID。
	// 返回值：成功时为非 nil 公开用户资料及 nil；零 ID 或不存在返回用户模块的 ErrUserNotFound，其他查询失败返回原始错误。
	Current(ctx context.Context, id uint64) (*usermodel.User, error)
}

// Service 管理配置使用范围和创建者赋值，数据库细节集中在 repository 包。
type Service struct {
	db    *gorm.DB
	users UserReader
}

// NewService 创建配置服务，不执行迁移或查询。
// 参数：db 为非 nil 数据库；users 为非 nil 用户查询实现，其底层对象也必须非 nil；返回值：服务及依赖错误，资源生命周期由应用管理。
func NewService(db *gorm.DB, users UserReader) (*Service, error) {
	if db == nil || users == nil {
		// 拒绝本次操作：AI 配置模块需要数据库及用户服务。
		return nil, errors.New("AI 配置模块需要数据库及用户服务")
	}
	return &Service{db: db, users: users}, nil
}

// 拒绝本次操作：AI 配置字段无效。
var ErrInvalid = errors.New("AI 配置字段无效")
