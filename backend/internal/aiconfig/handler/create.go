// 文件职责：严格解析创建配置请求并返回无密钥摘要。

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

// Create 严格解析单个配置对象并交给服务保存，响应不包含密钥。
// 接收者：h 为已初始化处理器；参数：c 为已认证请求，正文最多 32 KiB；返回值：无，成功 201，非法输入 400。
func (h *Handler) Create(c *gin.Context) {
	// 限制请求体大小，避免无界读取。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 32768)
	// 为请求数据创建 JSON 解码器。
	decoder := json.NewDecoder(c.Request.Body)
	// 拒绝未定义字段，避免客户端误传被静默忽略。
	decoder.DisallowUnknownFields()
	var input *service.CreateInput
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
	id, _ := auth.UserID(c)
	// 保存新建的业务记录。
	row, err := h.service.Create(c.Request.Context(), id, *input)
	if err != nil {
		// 按业务错误类型返回 HTTP 响应。
		writeError(c, err)
		return
	}
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusCreated, row)
}
