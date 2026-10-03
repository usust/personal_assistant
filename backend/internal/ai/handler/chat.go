// 文件职责：适配AI HTTP 请求并输出统一响应。

package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	domain "personal_assistant_server/internal/ai/model"
	"personal_assistant_server/internal/ai/service"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/response"
)

// Chat 解析文本消息并保留旧接口的部分成功响应格式。
// 接收者：h 为已初始化处理器；参数：c 为已认证请求；返回值：无，前置错误返回 400/403/500，执行结果返回 200。
func (h *Handler) Chat(c *gin.Context) {
	var input domain.ChatInput
	// 绑定请求字段，进入业务校验流程。
	if err := c.ShouldBindJSON(&input); err != nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, service.ErrInvalidInput.Error())
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	id, _ := auth.UserID(c)
	// 执行当前业务流程。
	result, err := h.service.Run(c.Request.Context(), capability.Actor{UserID: id}, input)
	switch {
	case err == nil:
		// 向客户端返回本次操作结果。
		response.Success(c, http.StatusOK, result)
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrInvalidInput):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, err.Error())
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, aiconfigservice.ErrForbidden):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusForbidden, err.Error())
	default:
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusInternalServerError, "读取 AI 配置失败")
	}
}
