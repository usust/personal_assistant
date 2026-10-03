// 文件职责：提供启动阶段的开发凭证入口，复用密码认证但不消费公开登录验证码。

package service

import "context"

// LoginForBootstrap 校验启动配置中的账号密码并签发开发凭证，不消费验证码。
// 接收者：s 为已初始化服务；参数：ctx 为启动上下文，account 为配置账号，password 为原始密码。
// 返回值：令牌及认证或查询错误；仅供启动层在显式 debug 配置下调用，不得绑定公开接口。
func (s *Service) LoginForBootstrap(ctx context.Context, account, password string) (string, error) {
	// 启动层复用密码认证；调用方负责限制为显式启用的开发场景。
	return s.loginWithPassword(ctx, account, password)
}
