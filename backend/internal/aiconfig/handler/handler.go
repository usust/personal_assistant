// 文件职责：定义处理器依赖并统一业务错误到 HTTP 的映射。

package handler

import (
	"errors"
	"github.com/gin-gonic/gin"
	"net/http"
	"personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/response"
	userservice "personal_assistant_server/internal/user/service"
)

// Handler 只处理 HTTP 协议，不持有数据库或启动资源。
type Handler struct {
	service *service.Service
	client  *http.Client
}

// NewHandler 创建配置 HTTP 适配器。
// 参数：s 为非 nil 配置服务，client 为非 nil 上游网络客户端；返回值：处理器；无副作用。
func NewHandler(s *service.Service, client *http.Client) *Handler {
	return &Handler{service: s, client: client}
}

// writeError 将配置服务错误映射为 HTTP 响应，隐藏数据库内部信息。
// 参数：c 为请求上下文；err 为非 nil 错误；返回值：无，写入 JSON。
func writeError(c *gin.Context, err error) {
	switch {
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, userservice.ErrUserNotFound):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusUnauthorized, "登录凭证无效")
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrInvalid):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, err.Error())
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrForbidden):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusForbidden, err.Error())
	default:
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusInternalServerError, "AI 配置操作失败")
	}
}
