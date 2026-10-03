// 文件职责：返回模型提供商目录。

package handler

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/response"
)

// Providers 返回提供商目录。
// 接收者：h 为已初始化处理器；参数：c 为已认证请求；返回值：无，写入 JSON。
func (h *Handler) Providers(c *gin.Context) {
	// 读取静态目录并使用统一响应信封。
	response.Success(c, http.StatusOK, service.Providers())
}
