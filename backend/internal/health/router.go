// 文件职责：注册健康管理接口与登录要求。
package health

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/health/handler"
)

// RegisterRoutes 注册登录用户的健康接口；参数：api 路由、h 处理器、login 认证中间件；返回值：无。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, login gin.HandlerFunc) {
	// 按业务维度汇总查询结果。
	g := api.Group("/health-management", login)
	// 注册业务接口及对应的请求处理入口。
	g.GET("", h.Read)
	// 注册业务接口及对应的请求处理入口。
	g.POST("/sync", h.Sync)
	// 注册业务接口及对应的请求处理入口。
	g.POST("/reports", h.Analyze)
	// 注册业务接口及对应的请求处理入口。
	g.DELETE("", h.Clear)
}
