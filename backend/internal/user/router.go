// 文件职责：汇总用户业务路由，并为受保护的用户操作绑定登录要求。

package user

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/user/handler"
)

// RegisterRoutes 绑定用户接口，公开列表与注册保持既有行为。
// 参数：api 为 API 路由组；h 为已初始化处理器；requireLogin 为认证中间件。
// 返回值：无；仅注册路由，修改及删除的角色授权仍由用户 Service 执行。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, requireLogin gin.HandlerFunc) {
	// 按业务维度汇总查询结果。
	group := api.Group("/users")
	// 注册业务接口及对应的请求处理入口。
	group.POST("/register", h.Register)
	// 注册业务接口及对应的请求处理入口。
	group.GET("", h.List)
	// 注册业务接口及对应的请求处理入口。
	group.GET("/me", requireLogin, h.Current)
	// 注册业务接口及对应的请求处理入口。
	group.PATCH("/:id", requireLogin, h.Update)
	// 注册业务接口及对应的请求处理入口。
	group.DELETE("/:id", requireLogin, h.Delete)
}
