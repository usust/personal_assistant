// 文件职责：注册认证入口，集中组织登录与验证码接口。

package auth

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth/handler"
)

// RegisterRoutes 绑定公开认证接口，不初始化服务、不执行数据库操作。
// 参数：api 为 API 路由组；h 为已初始化处理器；返回值：无；副作用为注册 Gin 路由。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler) {
	// 将公开认证入口集中到 /auth 路由组。
	group := api.Group("/auth")
	// 注册业务接口及对应的请求处理入口。
	group.GET("/captcha", h.CreateCaptcha)
	// 注册业务接口及对应的请求处理入口。
	group.POST("/login", h.Login)
}
