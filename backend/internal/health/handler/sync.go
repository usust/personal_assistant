// 文件职责：解析健康请求并返回统一信封。
package handler

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/response"
)

// Sync 解析并同步日快照；接收者：h 已初始化；参数：c 为认证请求，正文最大 64 KiB；返回值：无，写入成功数量或错误。
func (h *Handler) Sync(c *gin.Context) {
	c.Request.Body = httpBody(c)
	var input service.SyncInput
	if c.ShouldBindJSON(&input) != nil {
		response.Error(c, 400, "请求无效或过大")
		return
	}
	// 从认证上下文取得归属，客户端正文不能指定目标用户。
	uid, _ := auth.UserID(c)
	count, err := h.service.Sync(c.Request.Context(), uid, input)
	if err != nil {
		// 将服务公开错误转换为统一 HTTP 信封。
		writeError(c, err)
		return
	}
	// 成功状态码与信封 code 保持一致。
	response.Success(c, 200, gin.H{"synced": count})
}
