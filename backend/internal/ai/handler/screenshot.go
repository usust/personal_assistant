// 文件职责：适配AI HTTP 请求并输出统一响应。

package handler

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	domain "personal_assistant_server/internal/ai/model"
	"personal_assistant_server/internal/ai/service"
	"personal_assistant_server/internal/auth"
	"personal_assistant_server/internal/response"
)

// Screenshot 处理已登录用户的只读截图识别；参数：c 为 Gin 上下文；返回值：无，输出资料或 400/403/409/502；不记录截图或密钥。
func (h *Handler) Screenshot(c *gin.Context) {
	// 限制请求体大小，避免无界读取。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 5<<20)
	var input domain.ScreenshotInput
	// 为请求数据创建 JSON 解码器。
	decoder := json.NewDecoder(c.Request.Body)
	// 拒绝未定义字段，避免客户端误传被静默忽略。
	decoder.DisallowUnknownFields()
	// 解析输入数据，交给后续业务校验。
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || input.ConfigID == 0 || input.ConfigVersion == "" {
		// 向客户端返回本次操作结果。
		response.Error(c, 400, "截图请求无效")
		return
	}
	// 将可信身份和完整截图交给业务服务，入口不执行配置授权或网络调用。
	userID, _ := auth.UserID(c)
	result, err := h.service.Recognize(c.Request.Context(), userID, input)
	if err != nil {
		var public *service.RequestError
		if errors.As(err, &public) {
			response.Error(c, public.Status, public.Message)
		} else {
			response.Error(c, 500, "截图识别失败")
		}
		return
	}
	response.Success(c, 200, result)
}
