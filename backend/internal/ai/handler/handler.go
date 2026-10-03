// 文件职责：适配AI HTTP 请求并输出统一响应。

package handler

import (
	"personal_assistant_server/internal/ai/service"
)

// Handler 处理对话 HTTP 协议，数据库与模型网络请求均由注入的服务负责。
type Handler struct{ service *service.Service }

// NewHandler 创建对话 HTTP 适配器。
// 参数：s 为非 nil 对话服务；返回值：处理器；无副作用。
func NewHandler(s *service.Service) *Handler { return &Handler{service: s} }
