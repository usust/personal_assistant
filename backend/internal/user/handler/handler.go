// 文件职责：定义用户 HTTP 处理器及统一错误映射，集中管理处理器依赖。

package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/user/service"
)

// Handler 适配用户 HTTP 协议；业务授权及校验统一由 Service 完成。
type Handler struct{ service *service.Service }

// New 创建用户处理器。
// 参数：s 为非 nil 用户服务；返回值：共享该服务的处理器；无副作用。
func New(s *service.Service) *Handler { return &Handler{service: s} }

// writeError 将用户业务错误转换为 HTTP 状态，隐藏未分类的数据库错误。
// 参数：c 为请求上下文；err 为非 nil 错误；返回值：无，写入 JSON 响应。
func writeError(c *gin.Context, err error) {
	switch {
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrForbidden):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusForbidden, err.Error())
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrInvalidInput):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, err.Error())
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrUserNotFound):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusNotFound, err.Error())
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrAccountExists):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusConflict, err.Error())
	default:
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusInternalServerError, "服务器内部错误")
	}
}
