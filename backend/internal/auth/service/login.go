// 文件职责：执行公开登录的验证码消费、密码校验与令牌签发，统一认证失败口径。

package service

import (
	"context"
	"errors"
	userservice "personal_assistant_server/internal/user/service"

	"golang.org/x/crypto/bcrypt"
)

// LoginInput 保存登录业务输入；密码不得记录，验证码为一次性使用。
type LoginInput struct {
	Account       string
	Password      string
	CaptchaID     string
	CaptchaAnswer string
}

// Login 消费验证码、校验账号密码并签发 JWT；所有公开登录入口必须调用本方法。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；input 为账号、原始密码和一次性验证码；不得记录密码。
// 返回值：不含 Bearer 前缀的 token 及错误；验证码失败返回 ErrInvalidCaptcha；账号不存在、密码错误统一返回 ErrUnauthorized。
func (s *Service) Login(ctx context.Context, input LoginInput) (string, error) {
	// 验证码先消费再验证密码，失败后也不能重复使用。
	if !s.captcha.Verify(input.CaptchaID, input.CaptchaAnswer) {
		return "", ErrInvalidCaptcha
	}
	// 验证码通过后再校验密码并签发令牌，避免绕过公开登录的挑战。
	return s.loginWithPassword(ctx, input.Account, input.Password)
}

// loginWithPassword 复用登录和启动凭证的账号密码校验与签发。
// 接收者：s 为已初始化服务；参数：ctx 控制查询，account 为账号，password 为原始密码。
// 返回值：令牌及认证或查询错误；不校验验证码，仅供内部调用。
func (s *Service) loginWithPassword(ctx context.Context, account, password string) (string, error) {
	// 读取认证所需的用户凭证。
	user, err := s.users.Credentials(ctx, account)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, userservice.ErrUserNotFound) {
		return "", ErrUnauthorized
	}
	if err != nil {
		return "", err
	}
	// 验证输入密码是否匹配已保存的哈希。
	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)) != nil {
		return "", ErrUnauthorized
	}
	// 签发用户登录令牌。
	return s.tokens.Issue(user.ID)
}
