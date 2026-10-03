// 文件职责：返回当前身份可使用的配置列表。

package handler

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// List 返回当前用户可使用的配置元数据，不读取客户端筛选条件。
// 接收者：h 为已初始化处理器；参数：c 为已认证请求；返回值：无，写入 JSON 或分类错误。
func (h *Handler) List(c *gin.Context) {
	// 取得已认证的操作者身份，作为业务隔离依据。
	id, _ := auth.UserID(c)
	// 读取当前身份可访问的业务列表。
	rows, err := h.service.List(c.Request.Context(), id)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, rows)
}
