// 文件职责：适配记账 HTTP 请求并输出统一响应。

package handler

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/finance/service"
	"personal_assistant_server/internal/response"
)

type Handler struct{ service *service.Service }

// NewHandler 注入业务服务；参数：s 必须非 nil；返回值：处理器，无副作用。
func NewHandler(s *service.Service) *Handler { return &Handler{service: s} }

// Handle 构造固定操作适配器；参数：op 为服务端操作名；返回值：Gin 回调，写入 data 信封或脱敏错误。
func (h *Handler) Handle(op string) gin.HandlerFunc {
	// 请求回调验证路径、查询和 64 KiB JSON 正文；参数：c 为认证上下文；返回值：无，响应客户端。
	return func(c *gin.Context) {
		// 取得已认证的操作者身份，作为业务隔离依据。
		owner, _ := auth.UserID(c)
		in := service.Input{}
		// 读取路由中的目标资源标识。
		if s := c.Param("id"); s != "" {
			// 将资源标识解析为无符号整数。
			n, e := strconv.ParseUint(s, 10, 64)
			if e != nil || n == 0 {
				// 拒绝本次操作：ID 无效。
				writeError(c, service.Invalid("ID 无效"))
				return
			}
			in.ID = n
		}
		if op == "finance.transaction.summary" || op == "finance.transaction.list" || op == "finance.installment.list" || op == "finance.account.statements" {
			var e error
			// 解析流水查询的业务筛选条件。
			in.Filter, e = parseFilter(c)
			if e != nil {
				// 按业务错误类型返回 HTTP 响应。
				writeError(c, e)
				return
			}
		}
		if c.Request.Method == "PATCH" || (c.Request.Method == "POST" && op != "finance.transaction.confirm" && op != "finance.transaction.void" && op != "finance.installment.finish") {
			// 读取已限制范围内的响应内容。
			raw, e := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 64<<10))
			// 先拒绝无效 JSON，避免进入后续处理。
			if e != nil || !json.Valid(raw) {
				// 拒绝本次操作：JSON 无效或超过 64 KiB。
				writeError(c, service.Invalid("JSON 无效或超过 64 KiB"))
				return
			}
			in.Changes = raw
		}
		// 将业务操作交给共享服务执行。
		out, e := h.service.Execute(c.Request.Context(), capability.Actor{UserID: owner}, op, in, "http")
		if e != nil {
			// 按业务错误类型返回 HTTP 响应。
			writeError(c, e)
			return
		}
		// 向客户端返回本次操作结果。
		status := http.StatusOK
		if strings.HasSuffix(op, ".create") {
			status = http.StatusCreated
		}
		if strings.HasSuffix(op, ".delete") || op == "finance.account.archive" {
			out = nil
		}
		response.Success(c, status, out)
	}
}

// writeError 隐藏数据库细节；参数：c 为上下文，err 为非 nil 业务错误；返回值：无，写入对应 HTTP 状态。
func writeError(c *gin.Context, err error) {
	status := 500
	message := "服务器内部错误"
	switch {
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrInvalid):
		status = 400
		// 记录错误原因，供响应或日志使用。
		message = err.Error()
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrNotFound):
		status = 404
		// 记录错误原因，供响应或日志使用。
		message = err.Error()
	// 区分预期错误与需要继续上报的异常。
	case errors.Is(err, service.ErrConflict):
		status = 409
		// 记录错误原因，供响应或日志使用。
		message = err.Error()
	}
	// 向客户端返回本次操作结果。
	response.Error(c, status, message)
}
