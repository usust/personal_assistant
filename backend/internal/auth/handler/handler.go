// 文件职责：定义认证 HTTP 处理器及依赖注入入口，保持 HTTP 适配与认证规则分离。

package handler

import "personal_assistant_server/internal/auth/service"

// Handler 将 HTTP 认证请求交给共享认证服务，不持有数据库或启动配置。
type Handler struct{ service *service.Service }

// New 创建认证 HTTP 适配器。
// 参数：s 为非 nil、已初始化的认证服务；返回值：处理器；无副作用。
func New(s *service.Service) *Handler { return &Handler{service: s} }
