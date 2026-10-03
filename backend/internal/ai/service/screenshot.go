// 文件职责：执行截图校验、配置版本授权与只读视觉识别。
package service

import (
	"context"
	"strings"
	"time"

	domain "personal_assistant_server/internal/ai/model"
	"personal_assistant_server/internal/ai/repository"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
)

// RequestError 保存可公开的业务状态与说明。
type RequestError struct {
	Status  int
	Message string
}

// Error 返回公开错误文本；接收者：e 为非 nil 业务错误；参数：无；返回值：说明；无副作用。
func (e *RequestError) Error() string { return e.Message }

// Recognize 校验截图与配置版本后执行只读识别。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文，userID 为可信身份，input 为截图请求。
// 返回值：识别资料及带 HTTP 分类的错误；调用限时 45 秒，不记录截图和密钥，不执行工具或写账本。
func (s *Service) Recognize(ctx context.Context, userID uint64, input domain.ScreenshotInput) (domain.ScreenshotResult, error) {
	if input.ConfigID == 0 || input.ConfigVersion == "" {
		return domain.ScreenshotResult{}, &RequestError{Status: 400, Message: "截图请求无效"}
	}
	// 限制候选目录体积，避免无界提示词；只接受非空短名称。
	if len(input.Categories) > 1000 {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 400, Message: "分类目录过大"}
	}
	for _, name := range input.Categories {
		// 规范化输入，避免首尾空白影响校验。
		if strings.TrimSpace(name) == "" || len(name) > 128 {
			// 向客户端返回本次操作结果。
			return domain.ScreenshotResult{}, &RequestError{Status: 400, Message: "分类名称无效"}
		}
	}
	// 确认截图输入满足大小和格式约束。
	if err := repository.ValidateScreenshot(input.Image); err != nil {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 400, Message: err.Error()}
	}
	// 为外部调用或清理操作设置时间上限。
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	// 释放本次上下文及相关计时资源。
	defer cancel()
	// 取得当前用户有权使用的模型连接。
	config, err := s.configs.GetUsable(ctx, userID, input.ConfigID)
	if err != nil {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 403, Message: "该 AI 配置不存在或无权使用"}
	}
	// 读取当前身份可访问的业务列表。
	summaries, err := s.configs.List(ctx, userID)
	if err != nil {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 403, Message: "无法校验 AI 配置"}
	}
	versionOK := false
	for _, item := range summaries {
		// 将业务时间转换为约定的存储或展示格式。
		if item.ID == input.ConfigID && item.UpdatedAt.Format(time.RFC3339Nano) == input.ConfigVersion {
			versionOK = true
		}
	}
	if !versionOK {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 409, Message: "AI 配置已变化，请重新选择并同意截图外发"}
	}
	recognizer, ok := s.chat.Client.(interface {
		RecognizeScreenshot(context.Context, aiconfigservice.Connection, domain.ScreenshotInput) (domain.ScreenshotResult, error)
	})
	if !ok {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 502, Message: "视觉识别服务不可用"}
	}
	// 调用模型识别截图中的记账信息。
	result, err := recognizer.RecognizeScreenshot(ctx, config, input)
	if err != nil {
		// 向客户端返回本次操作结果。
		return domain.ScreenshotResult{}, &RequestError{Status: 502, Message: err.Error()}
	}
	// 向客户端返回本次操作结果。
	return result, nil
}
