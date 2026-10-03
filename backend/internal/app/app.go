// 文件职责：管理真实运行资源的创建、初始化、运行和释放，明确应用生命周期各阶段的资源归属。

// Package app 是唯一的应用组装入口，管理启动、初始化与资源生命周期。
package app

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
	"gorm.io/gorm"

	authservice "personal_assistant_server/internal/auth/service"
	"personal_assistant_server/internal/config"
	financeservice "personal_assistant_server/internal/finance/service"
	"personal_assistant_server/internal/platform/database"
	"personal_assistant_server/internal/platform/logging"
	userservice "personal_assistant_server/internal/user/service"
)

// App 持有应用资源，Handler 可供 HTTP 服务或集成测试调用；业务模块不依赖此类型。
type App struct {
	Handler *gin.Engine
	config  config.Config
	db      *gorm.DB
	logger  *zap.Logger
	users   *userservice.Service
	auth    *authservice.Service
}

// Open 加载配置并创建真实运行资源，不迁移或初始化业务数据。
// 参数：无；返回值：应用及启动错误；失败关闭已创建资源，成功后调用方负责 Close。
// 配置文件缺失、读取失败或校验失败时直接返回错误，不创建配置文件。
func Open() (*App, error) {
	// 取得启动配置的默认值。
	cfg := config.Defaults()
	// 加载本次启动使用的配置。
	if err := config.LoadConfig(&cfg); err != nil {
		return nil, err
	}
	// 显式映射文件配置与组件参数，使外部配置契约和日志实现可以独立演进。
	logger, err := logging.InitZap(logging.Options{
		Output:     cfg.ZapLog.Output,
		Level:      cfg.ZapLog.LogLevel,
		Dir:        cfg.ZapLog.LogDir,
		MaxSize:    cfg.ZapLog.MaxSize,
		MaxBackups: cfg.ZapLog.MaxBackups,
		MaxAge:     cfg.ZapLog.MaxAge,
		Compress:   cfg.ZapLog.IsCompress,
	})
	if err != nil {
		return nil, err
	}
	// 将文件配置显式映射为组件参数，保留外部字段兼容性并隔离驱动实现。
	db, err := database.Open(database.Options{
		Driver: cfg.DataBaseDriver,
		MySQL: database.MySQLOptions{
			Host:      cfg.MysqlConnection.Host,
			Port:      cfg.MysqlConnection.Port,
			Username:  cfg.MysqlConnection.Username,
			Password:  cfg.MysqlConnection.Password,
			Database:  cfg.MysqlConnection.Database,
			Charset:   cfg.MysqlConnection.Charset,
			ParseTime: cfg.MysqlConnection.ParseTime,
			Local:     cfg.MysqlConnection.Local,
		},
	})
	if err != nil {
		// 刷新已创建的日志资源。
		_ = logger.Sync()
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("连接数据库失败: %w", err)
	}
	// 创建当前流程所需的组件。
	application, err := New(cfg, db, logger, &http.Client{Timeout: 60 * time.Second})
	if err != nil {
		// 取得底层连接池，供资源管理使用。
		if sqlDB, dbErr := db.DB(); dbErr == nil {
			// 关闭数据库连接池。
			_ = sqlDB.Close()
		}
		// 刷新已创建的日志资源。
		_ = logger.Sync()
		return nil, err
	}
	return application, nil
}

// Initialize 在开始接收请求前按顺序迁移表并初始化默认数据。
// 接收者：a 为已组装应用；参数：ctx 控制数据库初始化；返回值：迁移或默认数据错误，失败时不得启动 HTTP。
func (a *App) Initialize(ctx context.Context) error {
	// 先使业务表结构满足当前版本要求。
	if err := a.migrate(ctx); err != nil {
		return err
	}
	// 在迁移完成后准备默认业务数据。
	return a.seed(ctx)
}

// Run 监听 HTTP 并在上下文取消时等待在途请求完成。
// 接收者：a 为已初始化应用；参数：ctx 为进程生命周期上下文；返回值：监听、运行或停机错误，正常取消为 nil。
// 本方法阻塞，不关闭数据库；调用方必须在返回后执行 Close。
func (a *App) Run(ctx context.Context) error {
	// 检查当前操作是否已经取消。
	if err := ctx.Err(); err != nil {
		return err
	}
	// 创建 HTTP 监听端口。
	listener, err := net.Listen("tcp", a.config.ListenAddr)
	if err != nil {
		return err
	}
	// 周期任务随 HTTP 服务退出而取消；错误回调参数为运行错误，返回值无，只记录日志。
	recurringCtx, cancelRecurring := context.WithCancel(ctx)
	recurringDone := make(chan struct{})
	// 停机回调无参数、无返回值；等待后台退出后才允许调用方关闭数据库。
	defer func() { cancelRecurring(); <-recurringDone }()
	// 周期工作回调无参数、无返回值；错误回调接收运行错误并写日志。
	go func() {
		defer close(recurringDone)
		// 运行周期记账任务，直到应用停止。
		financeservice.NewService(a.db).RunRecurring(recurringCtx, func(err error) { a.logger.Error("周期记账失败", zap.Error(err)) })
	}()
	server := &http.Server{Handler: a.Handler, ReadHeaderTimeout: 10 * time.Second}
	stopped := make(chan error, 1)
	// HTTP 运行回调把唯一退出结果传给主流程；参数：无；返回值：无，不访问业务状态。
	go func() { stopped <- server.Serve(listener) }()
	// 记录应用当前运行状态。
	a.logger.Info("HTTP 服务已启动", zap.String("address", listener.Addr().String()))
	select {
	case err := <-stopped:
		// 区分预期错误与需要继续上报的异常。
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	// 等待应用取消通知。
	case <-ctx.Done():
		// 独立停机上下文允许最多 90 秒的 AI 请求完成，避免进程信号立即中断已执行的写工具。
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
		// 释放本次上下文及相关计时资源。
		defer cancel()
		// 等待在途请求结束后停止 HTTP 服务。
		if err := server.Shutdown(shutdownCtx); err != nil {
			// 优雅停机失败时关闭 HTTP 服务。
			_ = server.Close()
			<-stopped
			return err
		}
		err := <-stopped
		// 区分预期错误与需要继续上报的异常。
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// Close 释放应用持有的数据库连接并刷新日志。
// 接收者：a 为非 nil 应用，必须已停止接收请求；参数：无；返回值：数据库获取或关闭错误。
// 终端日志可能不支持 Sync，沿用忽略其错误的行为；本方法不停止正在运行的 HTTP 服务。
func (a *App) Close() error {
	// 退出前刷新日志输出。
	defer a.logger.Sync()
	// 取得底层连接池，供资源管理使用。
	sqlDB, err := a.db.DB()
	if err != nil {
		return err
	}
	// 关闭数据库连接池。
	return sqlDB.Close()
}
