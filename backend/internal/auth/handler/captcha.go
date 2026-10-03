// 文件职责：提供验证码 HTTP 入口，返回一次性挑战并禁止客户端缓存。

package handler

import (
	"net/http"
	"personal_assistant_server/internal/response"

	"github.com/gin-gonic/gin"
)

// CreateCaptcha 生成并返回一次性验证码，同时禁止 HTTP 缓存。
// 接收者：h 为已初始化处理器；参数：c 为请求上下文；返回值：无，写 JSON，生成失败返回 500。
func (h *Handler) CreateCaptcha(c *gin.Context) {
	// 生成本次登录使用的验证码。
	id, imageData, expiresAt, err := h.service.CreateCaptcha()
	if err != nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusInternalServerError, "验证码生成失败")
		return
	}
	// 设置响应所需的协议头。
	c.Header("Cache-Control", "no-store")
	// 向客户端返回本次操作结果。
	response.Success(c, http.StatusOK, CaptchaData{CaptchaID: id, Image: imageData, ExpiresAt: expiresAt.Unix()})
}

// CaptchaData 是验证码接口的业务数据，对应 Apifox AuthCaptchaData。
// ExpiresAt 为 Unix 秒时间戳，Image 为 PNG Data URL。
type CaptchaData struct {
	CaptchaID string `json:"captcha_id"`
	Image     string `json:"image"`
	ExpiresAt int64  `json:"expires_at"`
}
