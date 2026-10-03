// 文件职责：解析配置 ID 并执行删除接口。

package handler

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
	"strconv"
)

// Delete 删除指定服务，响应不包含任何连接或密钥资料。
// 接收者：h 为已初始化处理器。
// 参数：c 为已认证请求，id 必须为正整数；返回值：无，成功返回 200，权限和非法 ID 返回对应错误。
func (h *Handler) Delete(c *gin.Context) {
	// 将资源标识解析为无符号整数。
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "配置 ID 无效")
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	actorID, _ := auth.UserID(c)
	// 删除满足业务范围约束的记录。
	if err := h.service.Delete(c.Request.Context(), actorID, uint(id)); err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, nil)
}
