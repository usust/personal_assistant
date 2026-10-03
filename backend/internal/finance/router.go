// 文件职责：注册记账模块路由。

package finance

import (
	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/finance/handler"
)

// RegisterRoutes 绑定认证后的财务接口；参数：api 为路由组，h 为处理器，login 为认证中间件；返回值：无，只注册路由。
func RegisterRoutes(api *gin.RouterGroup, h *handler.Handler, login gin.HandlerFunc) {
	// 按业务维度汇总查询结果。
	group := api.Group("/finance", login)
	// 注册业务接口及对应的请求处理入口。
	group.GET("/sync/snapshot", h.SyncSnapshot)
	// 注册业务接口及对应的请求处理入口。
	group.POST("/sync/commands", h.SyncCommand)
	for _, r := range []struct{ method, path, op string }{
		{"GET", "/presets", "finance.preset.list"}, {"POST", "/presets", "finance.preset.create"}, {"PATCH", "/presets/:id", "finance.preset.update"}, {"DELETE", "/presets/:id", "finance.preset.delete"},
		{"POST", "/recurring/materialize", "finance.recurring.materialize"},
		{"GET", "/accounts/:id/statements", "finance.account.statements"}, {"GET", "/accounts/:id/statement", "finance.account.statement"}, {"GET", "/accounts", "finance.account.list"}, {"POST", "/accounts", "finance.account.create"}, {"PATCH", "/accounts/:id", "finance.account.update"}, {"GET", "/accounts/:id/impact", "finance.account.impact"}, {"DELETE", "/accounts/:id", "finance.account.archive"},
		{"GET", "/categories", "finance.category.list"}, {"POST", "/categories", "finance.category.create"},
		{"POST", "/transactions/:id/refund", "finance.transaction.refund"}, {"DELETE", "/transactions/:id", "finance.transaction.delete"},
		{"GET", "/transactions/:id", "finance.transaction.get"}, {"GET", "/transactions", "finance.transaction.list"}, {"POST", "/transactions", "finance.transaction.create"}, {"PATCH", "/transactions/:id", "finance.transaction.update"}, {"POST", "/transactions/:id/confirm", "finance.transaction.confirm"}, {"POST", "/transactions/:id/void", "finance.transaction.void"},
		{"GET", "/transactions-summary", "finance.transaction.summary"},
		{"GET", "/installments", "finance.installment.list"},
		{"PATCH", "/installments/:id", "finance.installment.update"},
		{"DELETE", "/installments/:id", "finance.installment.delete"},
		{"POST", "/installments/:id/finish", "finance.installment.finish"},
		{"GET", "/transactions/:id/installment", "finance.installment.plan"},
		{"POST", "/transactions/:id/installment-preview", "finance.installment.preview"},
		{"POST", "/transactions/:id/installment", "finance.installment.create"},
		{"POST", "/loan-preview", "finance.loan.preview"},
		{"GET", "/accounts/:id/loan-plan", "finance.loan.plan"},
		{"POST", "/accounts/:id/loan-adjustment-preview", "finance.loan.adjustment.preview"},
		{"POST", "/accounts/:id/loan-adjustments", "finance.loan.adjustment.save"},
		{"GET", "/overview", "finance.overview"}, {"GET", "/events", "finance.events"},
	} {
		// 注册业务接口及对应的请求处理入口。
		group.Handle(r.method, r.path, h.Handle(r.op))
	}
}
