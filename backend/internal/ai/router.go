// 文件职责：注册AI模块路由。

package ai

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/ai/handler"
)

// RegisterRoutes 绑定对话接口，不承担配置授权、服务创建或数据库访问。
// 参数：api 为 API 路由组；h 为已初始化处理器；requireLogin 为认证中间件。
// 返回值：无；副作用为注册对话与只读截图识别 POST 接口。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, requireLogin gin.HandlerFunc) {
	// 注册业务接口及对应的请求处理入口。
	api.POST("/ai/chat", requireLogin, h.Chat)
	// 注册业务接口及对应的请求处理入口。
	api.POST("/ai/screenshot", requireLogin, h.Screenshot)
}
