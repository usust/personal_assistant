// 文件职责：注册任务模块路由。

package task

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/task/handler"
)

// RegisterRoutes 注册原前端契约；参数：api 为路由组，h 为处理器，login 为认证中间件；返回值：无，仅绑定路由。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, login gin.HandlerFunc) {
	// 按业务维度汇总查询结果。
	group := api.Group("", login)
	for _, route := range []struct{ method, path, op string }{
		{"GET", "/tasks", "task.list"}, {"POST", "/tasks", "task.create"}, {"PATCH", "/tasks/:id", "task.update"}, {"DELETE", "/tasks/:id", "task.delete"}, {"PATCH", "/tasks/:id/progress", "task.progress"}, {"PUT", "/tasks/reorder", "task.reorder"}, {"GET", "/tasks/events", "task.events"},
		{"GET", "/task-lists", "task_list.list"}, {"GET", "/task-lists/:id", "task_list.get"}, {"POST", "/task-lists", "task_list.create"}, {"PATCH", "/task-lists/:id", "task_list.update"}, {"DELETE", "/task-lists/:id", "task_list.delete"},
	} {
		// 注册业务接口及对应的请求处理入口。
		group.Handle(route.method, route.path, h.Handle(route.op))
	}
}
