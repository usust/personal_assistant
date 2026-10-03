// 文件职责：执行用户注册与创建，统一账户校验、密码处理和角色赋值。

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

// RegisterInput 表示用户注册所需的信息。
// Account 为登录账号。
// Password 为原始密码。
// Nickname 为用户昵称。
type RegisterInput struct {
	Account  string `json:"account"`
	Password string `json:"password"`
	Nickname string `json:"nickname"`
}

// Register 校验信息、哈希密码并创建普通账号，沿用公开注册规则。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；input 为账号、原始密码和昵称。
// 返回值：用户与错误；参数无效为 ErrInvalidInput，账号重复为 ErrAccountExists，成功会写数据库。
func (s *Service) Register(ctx context.Context, input RegisterInput) (*model.User, error) {
	// 按指定角色创建用户并处理密码。
	return createUser(s.db.WithContext(ctx), input, model.RoleUser)
}

// createUser 复用注册与默认管理员初始化的字段校验和密码哈希。
// 参数：db 为非 nil 数据库或事务；input 为注册信息；role 只能由服务端指定。
// 返回值：新用户与业务或数据库错误；成功插入记录，不记录原始密码。
func createUser(db *gorm.DB, input RegisterInput, role model.Role) (*model.User, error) {
	// 创建与更新复用账号、密码校验，昵称仍遵循注册的错误提示。
	account, err := validateAccount(input.Account)
	if err != nil {
		return nil, err
	}
	input.Account = account
	input.Nickname = strings.TrimSpace(input.Nickname)
	if err := validatePassword(input.Password); err != nil {
		return nil, err
	}
	if input.Nickname == "" {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w：昵称不能为空", ErrInvalidInput)
	}
	// 按字符数校验文本长度，避免中文被按字节误计。
	if utf8.RuneCountInString(input.Nickname) > 64 {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w：昵称不能超过 64 个字符", ErrInvalidInput)
	}

	// 通过仓储检查账号是否存在，已存在时拒绝重复注册。
	exists, err := repository.AccountExists(db, input.Account)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, ErrAccountExists
	}

	// 使用 bcrypt 默认计算成本生成带随机盐的密码哈希，避免存储明文密码；生成失败时返回错误并终止注册。
	hash, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	// 使用账号、密码哈希和昵称构造用户对象。
	u := &model.User{
		Account:      input.Account,
		PasswordHash: string(hash),
		Nickname:     input.Nickname,
		Role:         role,
	}
	// 调用仓储将用户写入数据库；重复键错误转换为账号已存在，其他错误原样返回。
	// 即使前面已检查账号，并发注册仍可能产生冲突，因此这里需要处理数据库唯一索引约束。
	if err := repository.Create(db, u); err != nil {
		// 区分预期错误与需要继续上报的异常。
		if errors.Is(err, gorm.ErrDuplicatedKey) {
			return nil, ErrAccountExists
		}
		return nil, err
	}
	return u, nil
}
