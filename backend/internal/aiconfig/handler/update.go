// 文件职责：严格解析 PATCH 请求并调用部分更新业务。

package handler

import (
	"encoding/json"
	"github.com/gin-gonic/gin"
	"io"
	"net/http"
	"personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
	"strconv"
)

// Update 严格解析 PATCH 白名单并保存实际提交字段。
// 接收者：h 为已初始化处理器。
// 参数：c 为已登录请求，id 为正整数，正文最多 32 KiB；返回值：无，写入无密钥摘要或错误。
func (h *Handler) Update(c *gin.Context) {
	// 将资源标识解析为无符号整数。
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "配置 ID 无效")
		return
	}
	// 限制请求体大小，避免无界读取。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 32768)
	// 为请求数据创建 JSON 解码器。
	decoder := json.NewDecoder(c.Request.Body)
	// 拒绝未定义字段，避免客户端误传被静默忽略。
	decoder.DisallowUnknownFields()
	var input *service.UpdateInput
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(&input); err != nil || input == nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体不是有效的设置 JSON")
		return
	}
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(new(any)); err != io.EOF {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体只能包含一个 JSON 对象")
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	actorID, _ := auth.UserID(c)
	// 写入当前业务字段的变更。
	row, err := h.service.Update(c.Request.Context(), actorID, uint(id), *input)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, row)
}
