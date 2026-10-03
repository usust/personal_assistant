// 文件职责：区分可公开的业务错误与内部原因，保留错误链并约束对外错误信息。

package capability

import "errors"

var (
	// 拒绝本次操作：能力不存在。
	ErrNotFound     = errors.New("能力不存在")
	// 拒绝本次操作：能力参数无效。
	ErrInvalidInput = errors.New("能力参数无效")
)

// PublicError 由具体工具适配器声明可展示消息，原始原因不自动发送给模型或浏览器。
type PublicError struct {
	message string
	cause   error
}

// NewPublicError 包装已经过业务适配器审核的错误消息。
// 参数：message 必须可公开且不含密钥；cause 为原始错误，可为 nil。返回值：可通过 errors.As 识别的工具错误。
func NewPublicError(message string, cause error) error {
	return &PublicError{message: message, cause: cause}
}

// Error 返回可展示消息。
// 接收者：e 为非 nil 错误；参数：无；返回值：公开消息；无副作用。
func (e *PublicError) Error() string { return e.message }

// Unwrap 保留错误链，供服务端诊断。
// 接收者：e 为非 nil 错误；参数：无；返回值：原始错误，可为 nil；无副作用。
func (e *PublicError) Unwrap() error { return e.cause }

// PublicMessage 生成可以交给模型和前端的错误文本。
// 参数：err 为工具错误，可为 nil；返回值：nil 对应空字符串，未知错误返回固定消息而不暴露内部原因。
func PublicMessage(err error) string {
	if err == nil {
		return ""
	}
	var public *PublicError
	// 提取错误链中的具体错误类型。
	if errors.As(err, &public) {
		// 记录错误原因，供响应或日志使用。
		return public.Error()
	}
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, ErrInvalidInput) {
		// 记录错误原因，供响应或日志使用。
		return ErrInvalidInput.Error()
	}
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, ErrNotFound) {
		// 记录错误原因，供响应或日志使用。
		return ErrNotFound.Error()
	}
	return "业务执行失败，请检查服务状态"
}
