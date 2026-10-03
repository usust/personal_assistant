// 文件职责：解析健康请求并返回统一信封。
package handler

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// Clear 清理本人健康资料；接收者：h 已初始化；参数：c 为认证请求；返回值：无，成功 200、data:null。
func (h *Handler) Clear(c *gin.Context) {
	// 从认证上下文取得归属，客户端正文不能指定目标用户。
	uid, _ := auth.UserID(c)
	if err := h.service.Clear(c.Request.Context(), uid); err != nil {
		writeError(c, err)
		return
	}
	// 成功状态码与信封 code 保持一致。
	response.Success(c, 200, nil)
}
