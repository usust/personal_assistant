// 文件职责：适配任务 HTTP 请求并输出统一响应。

package handler

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/response"
	"personal_assistant_server/internal/task/service"
)

// Handler 只负责 HTTP 输入输出。
type Handler struct{ service *service.Service }

// NewHandler 创建处理器；参数：s 为非 nil 业务服务；返回值：处理器，无副作用。
func NewHandler(s *service.Service) *Handler { return &Handler{service: s} }

// Handle 构造操作适配器；参数：op 为服务端固定操作；返回值：Gin 回调，响应 data 信封或公开错误。
func (h *Handler) Handle(op string) gin.HandlerFunc {
	// 请求回调限定 64 KiB 正文并拒绝多重 JSON；参数：c 为 HTTP 上下文；返回值：无，写入响应。
	return func(c *gin.Context) {
		// 取得已认证的操作者身份，作为业务隔离依据。
		owner, _ := auth.UserID(c)
		in := service.Input{}
		// 读取路由中的目标资源标识。
		if value := c.Param("id"); value != "" {
			// 将资源标识解析为无符号整数。
			id, err := strconv.ParseUint(value, 10, 64)
			if err != nil || id == 0 {
				// 拒绝本次操作：ID 无效。
				writeError(c, service.Invalid("ID 无效"))
				return
			}
			in.ID = id
		}
		// 读取客户端查询条件。
		if value := c.Query("cascade"); value != "" {
			// 将输入字段解析为布尔值。
			b, err := strconv.ParseBool(value)
			if err != nil {
				// 拒绝本次操作：cascade 无效。
				writeError(c, service.Invalid("cascade 无效"))
				return
			}
			in.Cascade = b
		}
		if c.Request.Method == "POST" || c.Request.Method == "PATCH" || c.Request.Method == "PUT" {
			// 读取已限制范围内的响应内容。
			raw, err := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 64<<10))
			// 先拒绝无效 JSON，避免进入后续处理。
			if err != nil || !json.Valid(raw) {
				// 拒绝本次操作：请求 JSON 无效或过大。
				writeError(c, service.Invalid("请求 JSON 无效或过大"))
				return
			}
			if op == "task.progress" || op == "task.reorder" {
				// 专用 DTO 拒绝请求体中的 id，避免覆盖 URL 目标。
				var body struct {
					Operation        string   `json:"operation"`
					AllowExceedTotal bool     `json:"allowExceedTotal"`
					TaskIDs          []uint64 `json:"taskIds"`
				}
				// 为请求数据创建 JSON 解码器。
				decoder := json.NewDecoder(bytes.NewReader(raw))
				// 拒绝未定义字段，避免客户端误传被静默忽略。
				decoder.DisallowUnknownFields()
				// 解析输入数据，交给后续业务校验。
				if decoder.Decode(&body) != nil {
					// 拒绝本次操作：操作字段无效。
					writeError(c, service.Invalid("操作字段无效"))
					return
				}
				in.Operation = body.Operation
				in.AllowExceedTotal = body.AllowExceedTotal
				in.TaskIDs = body.TaskIDs
			} else {
				in.Changes = raw
			}
		}
		// 将业务操作交给共享服务执行。
		out, err := h.service.Execute(c.Request.Context(), capability.Actor{UserID: owner}, op, in, "http")
		if err != nil {
			// 按业务错误类型返回 HTTP 响应。
			writeError(c, err)
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

// writeError 将业务错误映射为状态码；参数：c 为响应上下文，err 为非 nil 错误；返回值：无；隐藏内部数据库错误。
func writeError(c *gin.Context, err error) {
	status := http.StatusInternalServerError
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
