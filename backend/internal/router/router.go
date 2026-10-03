// 文件职责：汇总各业务 HTTP 路由和注入的处理器，保持路由注册与资源创建、数据初始化分离。

// Package router 只汇总 HTTP 路由，依赖由应用层组装，不执行迁移或初始化数据。
package router

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/ai"
	aihandler "personal_assistant_server/internal/ai/handler"
	"personal_assistant_server/internal/aiconfig"
	aiconfighandler "personal_assistant_server/internal/aiconfig/handler"
	"personal_assistant_server/internal/auth"
	authhandler "personal_assistant_server/internal/auth/handler"
	"personal_assistant_server/internal/finance"
	financehandler "personal_assistant_server/internal/finance/handler"
	healthmodule "personal_assistant_server/internal/health"
	healthhandler "personal_assistant_server/internal/health/handler"
	"personal_assistant_server/internal/task"
	taskhandler "personal_assistant_server/internal/task/handler"
	"personal_assistant_server/internal/user"
	userhandler "personal_assistant_server/internal/user/handler"
)

// Handlers 是路由注册所需的明确依赖，不包含数据库、日志或启动资源。
type Handlers struct {
	Health       *healthhandler.Handler
	Finance      *financehandler.Handler
	Tasks        *taskhandler.Handler
	Auth         *authhandler.Handler
	Users        *userhandler.Handler
	AI           *aihandler.Handler
	AIConfig     *aiconfighandler.Handler
	RequireLogin gin.HandlerFunc
}

// Register 创建 Gin 引擎并绑定已组装的业务处理器。
// 参数：handlers 的各字段必须非 nil；返回值：HTTP 引擎；仅修改内存路由，不访问数据库。
func Register(handlers Handlers) *gin.Engine {
	// 创建带请求日志与异常恢复的 HTTP 引擎。
	r := gin.Default()
	// 按业务维度汇总查询结果。
	api := r.Group("/api")
	// 注册业务接口及对应的请求处理入口。
	api.GET("/health", health)
	// 注册业务接口及对应的请求处理入口。
	auth.RegisterRoutes(api, handlers.Auth)
	// 注册业务接口及对应的请求处理入口。
	user.RegisterRoutes(api, handlers.Users, handlers.RequireLogin)
	// 注册业务接口及对应的请求处理入口。
	ai.RegisterRoutes(api, handlers.AI, handlers.RequireLogin)
	// 注册业务接口及对应的请求处理入口。
	aiconfig.RegisterRoutes(api, handlers.AIConfig, handlers.RequireLogin)
	// 注册业务接口及对应的请求处理入口。
	task.RegisterRoutes(api, handlers.Tasks, handlers.RequireLogin)
	// 注册业务接口及对应的请求处理入口。
	finance.RegisterRoutes(api, handlers.Finance, handlers.RequireLogin)
	// 注册业务接口及对应的请求处理入口。
	healthmodule.RegisterRoutes(api, handlers.Health, handlers.RequireLogin)
	return r
}
