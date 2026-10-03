// 文件职责：组装业务服务、共享能力、模型客户端与 HTTP 路由，使依赖关系集中于应用层。

package app

import (
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
	"gorm.io/gorm"

	aihandler "personal_assistant_server/internal/ai/handler"
	airepository "personal_assistant_server/internal/ai/repository"
	aiservice "personal_assistant_server/internal/ai/service"
	aiconfighandler "personal_assistant_server/internal/aiconfig/handler"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/auth"
	authhandler "personal_assistant_server/internal/auth/handler"
	authservice "personal_assistant_server/internal/auth/service"
	"personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/config"
	financecapability "personal_assistant_server/internal/finance/capability"
	financehandler "personal_assistant_server/internal/finance/handler"
	financeservice "personal_assistant_server/internal/finance/service"
	healthhandler "personal_assistant_server/internal/health/handler"
	healthservice "personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/router"
	taskcapability "personal_assistant_server/internal/task/capability"
	taskhandler "personal_assistant_server/internal/task/handler"
	taskservice "personal_assistant_server/internal/task/service"
	usercap "personal_assistant_server/internal/user/capability"
	userhandler "personal_assistant_server/internal/user/handler"
	userservice "personal_assistant_server/internal/user/service"
)

// New 组装共享服务、工具和 HTTP 处理器，不读写数据库，便于独立验证路由。
// 参数：cfg 为有效运行配置；db、logger 与 modelClient 必须非 nil；modelClient 由调用方设置超时。返回值：应用及依赖错误；成功后应用接管资源关闭职责。
// 本函数设置 Gin 全局模式，应在进程启动时调用，不应与其他实例并发改变模式。
func New(cfg config.Config, db *gorm.DB, logger *zap.Logger, modelClient *http.Client) (*App, error) {
	if db == nil || logger == nil || modelClient == nil {
		// 拒绝本次操作：应用需要数据库、日志与模型客户端。
		return nil, errors.New("应用需要数据库、日志与模型客户端")
	}
	// 在创建运行资源前确认配置有效。
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	// 创建业务服务并注入所需依赖。
	users, err := userservice.NewService(db)
	if err != nil {
		return nil, err
	}
	// 创建业务服务并注入所需依赖。
	authService, err := authservice.NewService(users, cfg.Auth.JWTSecret, time.Duration(cfg.Auth.JWTExpireHours)*time.Hour)
	if err != nil {
		return nil, err
	}
	// 创建业务服务并注入所需依赖。
	configs, err := aiconfigservice.NewService(db, users)
	if err != nil {
		return nil, err
	}
	// 创建业务服务并注入所需依赖。
	tasks := taskservice.NewService(db)
	// 创建业务服务并注入所需依赖。
	finances := financeservice.NewService(db)
	// 取得模块对外提供的共享能力。
	definitions := append(usercap.Definitions(users), taskcapability.Definitions(tasks)...)
	// 取得模块对外提供的共享能力。
	definitions = append(definitions, financecapability.Definitions(finances)...)
	// 创建共享能力执行入口。
	executor := capability.NewExecutor(capability.NewRegistry(definitions...))
	// 创建模型请求客户端。
	chat := &aiservice.Chat{Executor: executor, Client: airepository.NewHTTPClient(modelClient)}
	// 创建业务服务并注入所需依赖。
	chatService, err := aiservice.NewService(configs, chat)
	if err != nil {
		return nil, err
	}
	// 按启动配置切换 HTTP 框架运行模式。
	gin.SetMode(cfg.RunMode)
	// 创建当前流程所需的组件。
	handlers := router.Handlers{
		Health:       healthhandler.New(healthservice.NewService(db, configs, airepository.NewHTTPClient(modelClient))),
		Finance:      financehandler.NewHandler(finances),
		Tasks:        taskhandler.NewHandler(tasks),
		Auth:         authhandler.New(authService),
		Users:        userhandler.New(users),
		AI:           aihandler.NewHandler(chatService),
		AIConfig:     aiconfighandler.NewHandler(configs, modelClient),
		RequireLogin: auth.RequireLogin(authService),
	}
	// 注册业务接口及对应的请求处理入口。
	return &App{
			Handler: router.Register(handlers),
			config:  cfg,
			db:      db,
			logger:  logger,
			users:   users,
			auth:    authService},
		nil
}
