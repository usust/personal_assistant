// 文件职责：解析模型目录请求并交给服务授权。

package handler

import (
	"encoding/json"
	"github.com/gin-gonic/gin"
	"io"
	"net/http"
	"personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// Models 从指定服务获取模型 ID，绝不返回密钥或上游错误正文。
// 接收者：h 为已初始化处理器。
// 参数：c 为已登录请求，正文上限 32 KiB；返回值：无，写入模型列表或脱敏错误。
func (h *Handler) Models(c *gin.Context) {
	// 限制请求体大小，避免无界读取。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 32768)
	// 为请求数据创建 JSON 解码器。
	decoder := json.NewDecoder(c.Request.Body)
	// 拒绝未定义字段，避免客户端误传被静默忽略。
	decoder.DisallowUnknownFields()
	var input *service.ModelsInput
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(&input); err != nil || input == nil {
		// 向客户端返回本次操作结果。
		response.Error(c, 400, "模型目录请求无效")
		return
	}
	// 解析输入数据，交给后续业务校验。
	if err := decoder.Decode(new(any)); err != io.EOF {
		// 向客户端返回本次操作结果。
		response.Error(c, 400, "请求体只能包含一个 JSON 对象")
		return
	}
	// 取得已认证的操作者身份，作为业务隔离依据。
	actorID, _ := auth.UserID(c)
	// 服务统一执行目录授权和连接校验，处理器只适配 HTTP。
	models, err := h.service.Models(c.Request.Context(), actorID, h.client, *input)
	if err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, http.StatusOK, models)
}
