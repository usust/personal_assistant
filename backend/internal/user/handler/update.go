// 文件职责：适配用户部分更新请求，将字段变更交给业务服务授权与白名单校验。

package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/auth"
)

// Update 解析目标 ID 与局部字段，并由业务服务执行管理员授权和白名单更新。
// 接收者：h 为已初始化处理器；参数：c 为经过认证的请求上下文；返回值：无，成功返回更新后资料。
func (h *Handler) Update(c *gin.Context) {
	// 将资源标识解析为无符号整数。
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "用户 ID 无效")
		return
	}
	var input map[string]any
	// 为请求数据创建 JSON 解码器。
	decoder := json.NewDecoder(c.Request.Body)
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(&input); err != nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体必须是有效的 JSON 对象")
		return
	}
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(new(any)); err != io.EOF {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体必须是单个 JSON 对象")
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	actorID, _ := auth.UserID(c)
	// Handler 不把原始 map 当数据库字段；Service 会重新构造已校验的白名单 map。
	user, err := h.service.Update(c.Request.Context(), actorID, id, input)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, user)
}
