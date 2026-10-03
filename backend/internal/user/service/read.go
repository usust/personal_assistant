// 文件职责：用户列表、当前用户与认证凭证查询。

package service

import (
	"context"
	"errors"
	"gorm.io/gorm"
	"personal_assistant_server/internal/user/model"
	"personal_assistant_server/internal/user/repository"
	"strings"
)

// List 返回全部公开用户资料，沿用公开列表的既有业务规则。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文。返回值：用户切片及查询错误，不含密码哈希。
func (s *Service) List(ctx context.Context) ([]model.User, error) {
	// 读取用户列表。
	return repository.FindAll(s.db.WithContext(ctx))
}

// Current 查询服务端确定的用户身份及资料。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；id 为可信用户 ID。
// 返回值：公开用户资料及错误；零 ID 或不存在返回 ErrUserNotFound。
func (s *Service) Current(ctx context.Context, id uint64) (*model.User, error) {
	if id == 0 {
		return nil, ErrUserNotFound
	}
	// 按用户标识读取记录。
	user, err := repository.FindByID(s.db.WithContext(ctx), id)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrUserNotFound
	}
	return user, err
}

// Credentials 查询登录校验所需资料，仅供服务端认证流程使用。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；account 为账号，允许首尾空白和大写。
// 返回值：含密码哈希的用户及错误；不存在返回 ErrUserNotFound，调用方不得记录或展示哈希。
func (s *Service) Credentials(ctx context.Context, account string) (*model.User, error) {
	// 按账号查询用户记录。
	user, err := repository.FindByAccount(s.db.WithContext(ctx), strings.ToLower(strings.TrimSpace(account)))
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrUserNotFound
	}
	return user, err
}
