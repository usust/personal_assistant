// 文件职责：注册模型配置管理接口，并绑定登录校验。

package aiconfig

import (
	"github.com/gin-gonic/gin"
	"personal_assistant_server/internal/aiconfig/handler"
)

// RegisterRoutes 保留既有 AI 设置 URL，模块路径不再依附设置页面。
// 参数：api 为 API 路由组；h 为已初始化处理器；requireLogin 为认证中间件。
// 返回值：无；仅注册路由，不迁移数据库、不创建业务服务。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, requireLogin gin.HandlerFunc) {
	// 按业务维度汇总查询结果。
	group := api.Group("/setting/ai", requireLogin)
	// 注册业务接口及对应的请求处理入口。
	group.GET("/providers", h.Providers)
	// 注册业务接口及对应的请求处理入口。
	group.POST("/models", h.Models)
	// 注册业务接口及对应的请求处理入口。
	group.GET("/provider_config", h.List)
	// 注册业务接口及对应的请求处理入口。
	group.POST("/provider_config/create", h.Create)
	// 注册业务接口及对应的请求处理入口。
	group.PATCH("/provider_config/:id", h.Update)
	// 注册业务接口及对应的请求处理入口。
	group.DELETE("/provider_config/:id", h.Delete)
}
