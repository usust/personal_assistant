// 文件职责：授权并校验用户部分更新，通过白名单 map 写入实际提交的字段。

package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"personal_assistant_server/internal/user/model"
	"personal_assistant_server/internal/user/repository"
)

// Update 校验管理员权限和字段白名单，只更新实际提交的字段。
// 接收者：s 为已初始化服务；参数：ctx 为调用上下文；actorID 为可信操作者；id 为目标用户；input 为待校验字段。
// 返回值：更新后用户及错误；未提交或 null 的字段保持原值，非法零值按业务规则拒绝；密码在写入前哈希。
func (s *Service) Update(ctx context.Context, actorID, id uint64, input map[string]any) (*model.User, error) {
	// 先确认管理员权限，再执行管理操作。
	if err := s.RequireAdmin(ctx, actorID); err != nil {
		return nil, err
	}
	if id == 0 {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w：用户 ID 无效", ErrInvalidInput)
	}
	fields := make(map[string]any, len(input))
	for key, raw := range input {
		switch key {
		case "account", "nickname", "password", "role":
		default:
			// 为失败补充当前操作的错误上下文。
			return nil, fmt.Errorf("%w：不支持修改字段 %s", ErrInvalidInput, key)
		}
		if raw == nil {
			continue
		}
		value, ok := raw.(string)
		if !ok {
			// 为失败补充当前操作的错误上下文。
			return nil, fmt.Errorf("%w：字段 %s 必须为字符串", ErrInvalidInput, key)
		}
		switch key {
		case "account":
			// 复用创建账号的规范化与约束。
			account, err := validateAccount(value)
			if err != nil {
				return nil, err
			}
			fields[key] = account
		case "nickname":
			// 规范化输入，避免首尾空白影响校验。
			nickname := strings.TrimSpace(value)
			// 按字符数校验文本长度，避免中文被按字节误计。
			if nickname == "" || utf8.RuneCountInString(nickname) > 64 {
				// 为失败补充当前操作的错误上下文。
				return nil, fmt.Errorf("%w：昵称须为 1～64 个字符", ErrInvalidInput)
			}
			fields[key] = nickname
		case "role":
			role := model.Role(value)
			if role != model.RoleUser && role != model.RoleAdmin && role != model.RoleSysAdmin {
				// 为失败补充当前操作的错误上下文。
				return nil, fmt.Errorf("%w：角色须为 user、admin 或 sys_admin", ErrInvalidInput)
			}
			fields[key] = role
		case "password":
			if err := validatePassword(value); err != nil {
				return nil, err
			}
			// 将密码转换为带盐哈希后再保存。
			hash, err := bcrypt.GenerateFromPassword([]byte(value), bcrypt.DefaultCost)
			if err != nil {
				return nil, err
			}
			fields["password_hash"] = string(hash)
		}
	}
	if len(fields) == 0 {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w：至少提供一个待更新字段", ErrInvalidInput)
	}
	// 写入当前业务字段的变更。
	u, err := repository.Update(s.db.WithContext(ctx), id, fields)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrUserNotFound
	}
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrDuplicatedKey) {
		return nil, ErrAccountExists
	}
	return u, err
}
