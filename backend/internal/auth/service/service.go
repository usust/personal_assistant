// 文件职责：定义认证依赖契约并组装令牌与验证码服务，验证码状态按实例隔离。

package service

import (
	"context"
	"errors"
	"personal_assistant_server/internal/auth/repository"
	"personal_assistant_server/internal/user/model"
	"time"
)

// Service 组合账号查询、凭证和验证码，不依赖 Gin 或启动资源容器。
type Service struct {
	users   UserReader
	tokens  *Tokens
	captcha CaptchaProvider
}

// NewService 创建认证服务及其独立验证码存储。
// 参数：users 为非 nil 用户查询实现，其底层对象也必须非 nil；secret 为非空签名密钥；ttl 为正的凭证有效期。
// 返回值：认证服务及配置错误；无数据库写入，验证码状态不会跨应用实例共享。
func NewService(users UserReader, secret string, ttl time.Duration) (*Service, error) {
	if users == nil {
		// 拒绝本次操作：认证模块需要用户服务。
		return nil, errors.New("认证模块需要用户服务")
	}
	// 创建令牌服务并校验签名配置。
	tokens, err := NewTokens(secret, ttl)
	if err != nil {
		return nil, err
	}
	// 每个认证服务使用独立仓储，避免验证码跨实例共享。
	return &Service{users: users, tokens: tokens, captcha: &Captcha{store: repository.NewCaptchaStore()}}, nil
}

// UserReader 限定认证所需的用户查询能力，由调用方注入实现。
type UserReader interface {
	// Credentials 查询登录凭证；参数：ctx 为请求上下文，account 为允许首尾空白和大写的账号。
	// 返回值：成功时为非 nil 用户（含不可记录或展示的密码哈希）及 nil；不存在返回 userservice.ErrUserNotFound，其他查询失败返回原始错误。
	Credentials(ctx context.Context, account string) (*model.User, error)
	// Current 查询当前身份；参数：ctx 为请求上下文，id 为可信用户 ID。
	// 返回值：成功时为非 nil 公开用户资料及 nil；零 ID 或不存在返回 userservice.ErrUserNotFound，其他查询失败返回原始错误。
	Current(ctx context.Context, id uint64) (*model.User, error)
}

// CaptchaProvider 限定验证码生成与一次性消费能力，生产实现使用内存存储。
type CaptchaProvider interface {
	// Create 创建验证码；参数：无；返回值：ID、图片、过期时间和生成错误；成功保存待校验状态。
	Create() (string, string, time.Time, error)
	// Verify 消费验证码；参数：id 为标识，answer 为答案；返回值：是否正确且有效，找到后无论正确与否均消费。
	Verify(id, answer string) bool
}

// ErrUnauthorized 拒绝本次操作：账号、密码或登录凭证无效。
var ErrUnauthorized = errors.New("账号、密码或登录凭证无效")

// ErrInvalidCaptcha 表示验证码不存在、错误、过期或已消费。
var ErrInvalidCaptcha = errors.New("验证码无效或已过期")
