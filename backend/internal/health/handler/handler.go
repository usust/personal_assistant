// 文件职责：解析健康请求并返回统一信封。
package handler

import (
	"errors"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/response"
)

// Handler 仅负责健康 API 的 HTTP 适配。
type Handler struct{ service *service.Service }

// New 注入健康服务；参数：s 为非 nil 服务；返回值：处理器；无副作用。
func New(s *service.Service) *Handler { return &Handler{service: s} }

// writeError 映射公开业务错误；参数：c 为请求，err 为非 nil 错误；返回值：无；写入信封并隐藏内部细节。
func writeError(c *gin.Context, err error) {
	var e *service.OperationError
	if errors.As(err, &e) {
		response.Error(c, e.Status, e.Message)
	} else {
		response.Error(c, 500, "健康操作失败")
	}
}

// httpBody 限制请求为 64 KiB；参数：c 为当前请求；返回值：受限正文；超限读取失败。
func httpBody(c *gin.Context) io.ReadCloser {
	return http.MaxBytesReader(c.Writer, c.Request.Body, 64<<10)
}
