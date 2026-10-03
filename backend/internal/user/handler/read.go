// 文件职责：提供用户列表与当前用户查询 HTTP 入口。

package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/auth"
)

// List 返回全部公开用户资料。
// 接收者：h 为已初始化处理器；参数：c 为请求上下文；返回值：无，写入 JSON 或数据库错误响应。
func (h *Handler) List(c *gin.Context) {
	// 读取当前身份可访问的业务列表。
	users, err := h.service.List(c.Request.Context())
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, users)
}

// Current 返回当前登录用户资料，身份只能来自认证中间件。
// 接收者：h 为已初始化处理器；参数：c 为请求上下文；返回值：无，缺失身份返回 401，其他错误统一映射。
func (h *Handler) Current(c *gin.Context) {
	// 取得已认证的操作者身份，作为业务隔离依据。
	id, ok := auth.UserID(c)
	if !ok {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusUnauthorized, "登录凭证无效")
		return
	}
	// 读取当前用户的业务信息。
	user, err := h.service.Current(c.Request.Context(), id)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, user)
}
