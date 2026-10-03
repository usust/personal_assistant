// 文件职责：账号、昵称和密码共用校验。

package service

import (
	"fmt"
	"regexp"
	"strings"
)

var accountPattern = regexp.MustCompile(`^[a-z0-9_]{3,64}$`)

// validateAccount 规范化并校验登录账号。
// 参数：value 为原始账号，允许首尾空白和大写；返回值：规范化账号及校验错误；无副作用。
func validateAccount(value string) (string, error) {
	account := strings.ToLower(strings.TrimSpace(value))
	if !accountPattern.MatchString(account) {
		return "", fmt.Errorf("%w：账号只能包含小写字母、数字和下划线，长度须为 3～64 个字符", ErrInvalidInput)
	}
	return account, nil
}

// validatePassword 检查密码是否满足 bcrypt 支持的长度约束。
// 参数：value 为原始密码，不做空白裁剪；返回值：非法输入错误，合法时为 nil；无副作用。
func validatePassword(value string) error {
	if len(value) < 8 || len(value) > 72 {
		return fmt.Errorf("%w：密码长度须为 8～72 字节", ErrInvalidInput)
	}
	return nil
}
