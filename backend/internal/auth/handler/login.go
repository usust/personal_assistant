// 文件职责：定义公开登录协议并映射认证结果，区分输入错误、身份失败与内部故障。

package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/auth/service"
)

// Login 消费验证码并校验账号密码，返回签名凭证。
// 接收者：h 为已初始化处理器；参数：c 为请求上下文；返回值：无，输入错误 400、认证失败 401、内部错误 500。
func (h *Handler) Login(c *gin.Context) {
	var input LoginInput
	// 绑定请求字段，进入业务校验流程。
	if err := c.ShouldBindJSON(&input); err != nil {
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusBadRequest, "请求体不是有效的 JSON，或缺少登录字段")
		return
	}
	// 将完整登录输入交给服务，统一执行验证码和密码校验。
	token, err := h.service.Login(
		// 将请求取消与超时传递到认证查询。
		c.Request.Context(),
		service.LoginInput{
			Account:       input.Account,
			Password:      input.Password,
			CaptchaID:     input.CaptchaID,
			CaptchaAnswer: input.CaptchaAnswer})
	switch {
	case err == nil:
		// 向客户端返回本次操作结果。
		response.Success(c, http.StatusOK, TokenData{Token: token, TokenType: "Bearer"})
	// 验证码错误作为输入失败返回，客户端需要获取新挑战。
	case errors.Is(err, service.ErrInvalidCaptcha):
		// 仅公开已定义的验证码错误，避免泄露内部故障信息。
		response.Error(c, http.StatusBadRequest, err.Error())
	// 账号不存在与密码错误使用相同响应，避免账号枚举。
	case errors.Is(err, service.ErrUnauthorized):
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusUnauthorized, "账号或密码错误")
	default:
		// 向客户端返回本次操作结果。
		response.Error(c, http.StatusInternalServerError, "服务器内部错误")
	}
}

// LoginInput 定义公开登录协议；原始密码不得写入日志。
type LoginInput struct {
	Account       string `json:"account" binding:"required"`
	Password      string `json:"password" binding:"required"`
	CaptchaID     string `json:"captcha_id" binding:"required"`
	CaptchaAnswer string `json:"captcha_answer" binding:"required"`
}

// TokenData 是登录接口的业务数据，对应 Apifox AuthTokenData。
// Token 不含 Bearer 前缀，TokenType 固定为 Bearer。
type TokenData struct {
	Token     string `json:"token"`
	TokenType string `json:"token_type"`
}
