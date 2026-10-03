// 文件职责：适配用户删除 HTTP 请求，将操作者身份和目标用户交给业务服务授权。

package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/auth"
)

// Delete 解析目标用户并调用统一授权的删除业务。
// 接收者：h 为已初始化处理器；参数：c 为经过认证的请求上下文；返回值：无，成功返回 200 和 data=null，失败统一映射错误。
func (h *Handler) Delete(c *gin.Context) {
	// 将资源标识解析为无符号整数。
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "用户 ID 无效")
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	actorID, _ := auth.UserID(c)
	// 删除满足业务范围约束的记录。
	if err := h.service.Delete(c.Request.Context(), actorID, id); err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 返回本次操作的 HTTP 状态。
	response.Success(c, http.StatusOK, nil)
}
