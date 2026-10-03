// 文件职责：管理验证码生成、存储与消费，使用随机源和摘要校验控制验证码生命周期。

package service

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"personal_assistant_server/internal/auth/repository"
	"strings"
	"time"
)

const (
	captchaLength = 6
	captchaTTL    = 2 * time.Minute
	// 排除容易混淆的 0/O/o 和 1/I/i/l。
	captchaChars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"
)

// Create 生成验证码内容和图片，并记录后续校验所需的摘要及过期时间。
// 接收者：s 的 store 必须已初始化；参数：无；返回值：验证码 ID、PNG Data URL、过期时间和生成错误。
// 随机源或图片生成失败时不保存挑战；成功写入内存并清理过期记录，允许并发调用。
func (s *Captcha) Create() (string, string, time.Time, error) {
	// 生成 18 字节的密码学安全随机数，后续编码为对外暴露的验证码 ID。
	// 该 ID 仅用于定位服务端保存的验证码记录，足够的随机性可降低被猜中或枚举的风险。
	idBytes, err := secureRandom(18)
	if err != nil {
		return "", "", time.Time{}, err
	}
	// 为验证码内容单独生成一组安全随机字节，每个字节将在下方映射为一个可读字符。
	// ID 与验证码使用独立的随机数，使客户端无法根据 ID 推断验证码内容或关联其他请求。
	codeBytes, err := secureRandom(captchaLength)
	if err != nil {
		return "", "", time.Time{}, err
	}
	code := make([]byte, captchaLength)
	// 使用排除易混淆字符的目录提高可读性；取模映射存在轻微分布偏差，不等同于均匀采样。
	for i := range code {
		code[i] = captchaChars[int(codeBytes[i])%len(captchaChars)]
	}

	// 将验证码字符绘制成 PNG Data URL，客户端可以直接设置到 img 的 src 属性。
	imageData, err := renderCaptcha(string(code))
	if err != nil {
		return "", "", time.Time{}, err
	}
	// 将随机字节编码为不带填充符的 URL 安全 Base64 字符串，便于在 HTTP 请求中传递验证码 ID。
	id := base64.RawURLEncoding.EncodeToString(idBytes)
	// 以当前服务时间为起点加上验证码有效期，得到该验证码的绝对过期时间。
	now := time.Now()
	// 保存绝对期限，生成与消费共用同一过期边界。
	expiresAt := now.Add(captchaTTL)

	// 仓储只保存摘要与期限，并在锁内清理过期记录。
	s.store.Save(id, captchaHash(string(code)), expiresAt, now)

	return id, imageData, expiresAt, nil
}

// secureRandom 生成密码学随机字节。
// 参数：size 为非负字节数；返回值：随机字节及生成错误，负数会 panic，仅供内部固定长度调用。
func secureRandom(size int) ([]byte, error) {
	b := make([]byte, size)
	// 读取安全随机数据。
	if _, err := rand.Read(b); err != nil {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("生成验证码随机数: %w", err)
	}
	return b, nil
}

// captchaHash 计算规范化验证码摘要。
// 参数：value 为验证码或答案，忽略首尾空白与大小写；返回值：SHA-256 摘要；无副作用。
func captchaHash(value string) [sha256.Size]byte {
	// 生成和校验共用规范化逻辑，忽略字母大小写及首尾空白。
	return sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(value))))
}

// Captcha 执行验证码生成与校验规则，存储由仓储负责。
type Captcha struct{ store *repository.CaptchaStore }

// Verify 消费并校验一次性验证码，失败也不可重用。
// 接收者：s 为已初始化验证码服务；参数：id 为标识，answer 为答案；返回值：是否正确且未过期。
func (s *Captcha) Verify(id, answer string) bool {
	// 仓储原子读取并删除，业务层判断过期与答案。
	hash, expiresAt, exists := s.store.Consume(id)
	// 已消费或到达期限的挑战直接拒绝，答案校验不能延长有效期。
	if !exists || !expiresAt.After(time.Now()) {
		return false
	}
	// 使用与生成阶段一致的规范化规则计算答案摘要。
	actual := captchaHash(answer)
	// 固定时间比较摘要，避免答案匹配程度通过比较耗时泄露。
	return subtle.ConstantTimeCompare(hash[:], actual[:]) == 1
}

// CreateCaptcha 创建一次性验证码。
// 接收者：s 为已初始化服务；参数：无；返回值：ID、PNG Data URL、过期时间及生成错误；成功写入本实例内存。
func (s *Service) CreateCaptcha() (string, string, time.Time, error) {
	// 委托验证码服务生成挑战，并保留底层生成错误。
	return s.captcha.Create()
}
