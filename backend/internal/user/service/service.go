// 文件职责：定义用户业务服务及构造约束，为 HTTP、认证和模型能力提供共享依赖。

// Package service 统一用户业务规则，供 HTTP、认证与 AI 工具复用。
package service

import (
	"errors"
	"fmt"

	"gorm.io/gorm"
)

var (
	// ErrInvalidInput 拒绝本次操作：用户参数无效。
	ErrInvalidInput = errors.New("用户参数无效")
	// ErrAccountExists 拒绝本次操作：账号已存在。
	ErrAccountExists = errors.New("账号已存在")
	// ErrUserNotFound 拒绝本次操作：用户不存在。
	ErrUserNotFound = errors.New("用户不存在")
	// ErrForbidden 拒绝本次操作：需要管理员权限。
	ErrForbidden = errors.New("需要管理员权限")
)

// Service 持有可复用数据库连接；各请求通过显式 ctx 绑定取消信号。
type Service struct{ db *gorm.DB }

// NewService 创建用户业务服务，不迁移表、不写入数据。
// 参数：db 为非 nil 数据库；返回值：服务及依赖校验错误，数据库生命周期由应用管理。
func NewService(db *gorm.DB) (*Service, error) {
	if db == nil {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("用户模块需要数据库")
	}
	return &Service{db: db}, nil
}
