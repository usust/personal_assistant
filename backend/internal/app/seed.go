// 文件职责：在迁移完成后初始化空库管理员，并按显式开发配置输出调试凭证。

package app

import (
	"context"
	"fmt"
	"log"

	"github.com/gin-gonic/gin"

	userservice "personal_assistant_server/internal/user/service"
)

// seed 将配置转换为用户业务输入，并在迁移后初始化空库管理员。
// 接收者：a 为已迁移应用；参数：ctx 控制初始化；返回值：用户业务错误；成功后可按显式开发开关输出凭证。
func (a *App) seed(ctx context.Context) error {
	cfg := a.config.DefaultUser
	// 在空库中初始化默认管理员。
	if err := a.users.EnsureDefaultAdmin(
		ctx,
		userservice.RegisterInput{Account: cfg.Account, Password: cfg.Password, Nickname: cfg.Nickname}); err != nil {
		return err
	}
	// 按开发开关尝试输出调试凭证。
	a.printDevToken(ctx)
	return nil
}

// printDevToken 在明确启用的 debug 模式下复用认证服务输出开发凭证。
// 接收者：a 为已初始化应用；参数：ctx 为启动上下文；返回值：无；凭证仅输出终端，不写业务日志文件。
func (a *App) printDevToken(ctx context.Context) {
	if !a.config.Auth.PrintDevToken {
		return
	}
	if a.config.RunMode != gin.DebugMode {
		// 记录本次失败或运行提示。
		log.Print("跳过调试 token 输出：仅允许 run_mode: debug")
		return
	}
	// 验证账号密码并取得登录凭证。
	token, err := a.auth.LoginForBootstrap(ctx, a.config.DefaultUser.Account, a.config.DefaultUser.Password)
	if err != nil {
		// 记录本次失败或运行提示。
		log.Print("生成调试 token 失败：请检查 default_user 账号密码")
		return
	}
	// 向终端输出开发调试信息。
	fmt.Printf("本地调试登录凭证（有效期 %d 小时，请勿分享）：\nAuthorization: Bearer %s\n", a.config.Auth.JWTExpireHours, token)
}
