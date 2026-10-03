// 文件职责：解析健康请求并返回统一信封。
package handler

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// Read 返回本人健康摘要；接收者：h 已初始化；参数：c 为认证请求；返回值：无，写入 200 或公开错误。
func (h *Handler) Read(c *gin.Context) {
	// 从认证上下文取得归属，客户端正文不能指定目标用户。
	uid, _ := auth.UserID(c)
	out, err := h.service.Read(c.Request.Context(), uid)
	if err != nil {
		// 将服务公开错误转换为统一 HTTP 信封。
		writeError(c, err)
		return
	}
	// 成功状态码与信封 code 保持一致。
	response.Success(c, 200, out)
}
