// 文件职责：适配用户注册请求，将注册输入交给业务服务校验和创建。

package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/user/service"
)

// Register 解析公开注册协议并调用共享用户服务。
// 接收者：h 为已初始化处理器；参数：c 为请求上下文；返回值：无，成功返回 201，业务错误统一映射。
func (h *Handler) Register(c *gin.Context) {
	var input service.RegisterInput
	// 绑定请求字段，进入业务校验流程。
	if err := c.ShouldBindJSON(&input); err != nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体不是有效的 JSON，或字段类型不正确")
		return
	}
	// 注册业务接口及对应的请求处理入口。
	user, err := h.service.Register(c.Request.Context(), input)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusCreated, user)
}
