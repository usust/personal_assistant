// 文件职责：适配记账 HTTP 请求并输出统一响应。

package handler

import (
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/finance/service"
	"personal_assistant_server/internal/response"
)

// SyncSnapshot 输出当前身份的完整快照；参数：c 为认证请求；返回值：无，写入一致性账本或脱敏错误。
func (h *Handler) SyncSnapshot(c *gin.Context) {
	// 取得已认证的操作者身份，作为业务隔离依据。
	owner, _ := auth.UserID(c)
	// 读取客户端需要的完整同步快照。
	out, err := h.service.SyncSnapshot(c.Request.Context(), owner)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, out)
}

// SyncCommand 接收单个持久化操作；参数：c 为认证请求；返回值：无，最多读取 64 KiB，输出业务结果或脱敏错误。
func (h *Handler) SyncCommand(c *gin.Context) {
	// 取得已认证的操作者身份，作为业务隔离依据。
	owner, _ := auth.UserID(c)
	// 读取已限制范围内的响应内容。
	raw, err := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 64<<10))
	var command service.SyncCommand
	if err != nil {
		// 拒绝本次操作：同步正文超过 64 KiB。
		writeError(c, service.Invalid("同步正文超过 64 KiB"))
		return
	}
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err = service.Decode(raw, &command); err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 执行同步命令并复用已有回执。
	out, err := h.service.SyncExecute(c.Request.Context(), owner, command)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, out)
}
