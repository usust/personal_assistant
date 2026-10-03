// 文件职责：解析健康请求并返回统一信封。
package handler

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/response"
)

// Analyze 解析健康分析请求；接收者：h 已初始化；参数：c 为认证请求，正文最大 64 KiB；返回值：无，新报告返回 201，无效同意返回 400。
func (h *Handler) Analyze(c *gin.Context) {
	c.Request.Body = httpBody(c)
	var input service.AnalyzeInput
	if c.ShouldBindJSON(&input) != nil {
		response.Error(c, 400, "请选择 AI 配置并同意发送健康日汇总")
		return
	}
	// 从认证上下文取得归属，客户端正文不能指定目标用户。
	uid, _ := auth.UserID(c)
	// 授权、外发同意和报告落库由业务服务统一处理。
	report, err := h.service.Analyze(c.Request.Context(), uid, input)
	if err != nil {
		// 将服务公开错误转换为统一 HTTP 信封。
		writeError(c, err)
		return
	}
	// 成功状态码与信封 code 保持一致。
	response.Success(c, 201, report)
}
