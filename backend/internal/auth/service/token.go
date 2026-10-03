// 文件职责：封装认证令牌的签发与验证，统一签名密钥和有效期约束。

package service

import (
	"errors"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// ErrInvalidToken 表示令牌或身份声明无效。
var ErrInvalidToken = errors.New("令牌无效")

// Tokens 仅负责 JWT 协议，不访问数据库或 HTTP 请求。
type Tokens struct {
	secret []byte
	ttl    time.Duration
}

// NewTokens 创建不可变的凭证签发器。
// 参数：secret 为非空密钥；ttl 为正有效期。返回值：签发器及参数错误；无副作用。
func NewTokens(secret string, ttl time.Duration) (*Tokens, error) {
	if secret == "" || ttl <= 0 {
		// 拒绝本次操作：JWT 密钥及有效期必须有效。
		return nil, errors.New("JWT 密钥及有效期必须有效")
	}
	return &Tokens{secret: []byte(secret), ttl: ttl}, nil
}

// Issue 签发指定用户的 HS256 凭证。
// 接收者：t 为已初始化签发器；参数：id 为非零可信用户 ID。返回值：JWT 字符串与签名错误，零 ID 返回 ErrInvalidToken。
func (t *Tokens) Issue(id uint64) (string, error) {
	if id == 0 {
		return "", ErrInvalidToken
	}
	// 取得当前时间，作为本次操作的时间基准。
	now := time.Now()
	// 将资源标识转换为文本。
	claims := jwt.RegisteredClaims{Subject: strconv.FormatUint(id, 10), Issuer: "personal-assistant", IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(t.ttl))}
	// 对令牌签名后返回认证凭证。
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(t.secret)
}

// Verify 验证算法、签名、签发者、有效期和用户 ID，不查询用户是否存在。
// 接收者：t 为已初始化签发器；参数：raw 为原始 token。返回值：用户 ID 及错误，失败统一为 ErrInvalidToken。
func (t *Tokens) Verify(raw string) (uint64, error) {
	claims := &jwt.RegisteredClaims{}
	// 密钥回调仅为已限制的 HS256 验证返回服务端密钥，不信任客户端指定的密钥信息。
	// 参数：token 为待验证凭证；返回值：固定密钥及 nil 错误；无副作用。
	key := func(token *jwt.Token) (any, error) { return t.secret, nil }
	// 验证令牌并解析身份声明。
	token, err := jwt.ParseWithClaims(raw, claims, key, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("personal-assistant"), jwt.WithExpirationRequired())
	if err != nil || !token.Valid {
		return 0, ErrInvalidToken
	}
	// 将资源标识解析为无符号整数。
	id, err := strconv.ParseUint(claims.Subject, 10, 64)
	if err != nil || id == 0 {
		return 0, ErrInvalidToken
	}
	return id, nil
}
