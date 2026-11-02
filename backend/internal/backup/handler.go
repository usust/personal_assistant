// 文件职责：提供认证备份 HTTP 接口；先完成读取和编码，再发送成功信封，禁止缓存。
package backup

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// exporter 将 HTTP 层和一致事务读取解耦，便于验证错误时不会产生成功空备份。
type exporter interface {
	// Export 读取本人快照；参数：ctx 为可取消上下文，ownerID 为认证用户 ID；返回值：完整快照或错误，失败不返回部分数据。
	Export(ctx context.Context, ownerID uint64) (*Snapshot, error)
}

// Handler 只通过可信认证上下文取得归属，不接受客户端提供的用户 ID。
type Handler struct{ service exporter }

// NewHandler 创建备份处理器；参数：service 为非 nil 备份服务；返回值：HTTP 处理器，无副作用。
func NewHandler(service *Service) *Handler { return &Handler{service: service} }

// Export 响应完整快照；参数：c 为当前 HTTP 上下文；返回值：无，写入 JSON 信封与 no-store 响应头。
// 未认证返回 401；读取或序列化失败返回 500 且 data 为 null，不对外暴露 SQL 或内部错误正文。
func (h *Handler) Export(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	ownerID, ok := auth.UserID(c)
	if !ok || ownerID == 0 {
		response.AbortError(c, http.StatusUnauthorized, "请先登录")
		return
	}
	if h == nil || h.service == nil {
		response.Error(c, http.StatusInternalServerError, "数据导出失败")
		return
	}
	snapshot, err := h.service.Export(c.Request.Context(), ownerID)
	if err != nil || snapshot == nil {
		response.Error(c, http.StatusInternalServerError, "数据导出失败")
		return
	}
	// 预先编码整个数据，避免非法浮点数、损坏时间等在 Gin 已发送 200 后才被发现；大集合不设置截断上限。
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		response.Error(c, http.StatusInternalServerError, "数据导出失败")
		return
	}
	response.Success(c, http.StatusOK, json.RawMessage(encoded))
}

// RegisterRoutes 注册认证的完整导出入口；参数：api 为 /api 路由组，handler 为非 nil 处理器，requireLogin 为可信认证中间件；返回值：无，仅注册路由。
func RegisterRoutes(api *gin.RouterGroup, handler *Handler, requireLogin gin.HandlerFunc) {
	// no-store 必须先于认证执行，使认证拒绝的响应同样不可缓存。
	api.GET("/backup/export", noStore, requireLogin, handler.Export)
}

// noStore 禁止缓存认证成功和失败的导出响应；参数：c 为当前请求上下文；返回值：无，设置响应头后继续调用后续中间件。
func noStore(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	c.Next()
}
