// 文件职责：解析登录凭证并将认证用户身份写入请求上下文，为受保护接口建立身份边界。

package auth

import (
	"errors"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/response"

	"personal_assistant_server/internal/auth/service"
)

// RequireLogin 创建只负责认证的 HTTP 中间件；业务授权由各 Service 完成。
// 参数：s 为非 nil 认证服务；返回值：Gin 处理函数；凭证无效返回 401，数据库故障返回 500。
func RequireLogin(s *service.Service) gin.HandlerFunc {
	// 请求回调将 HTTP 凭证转换为可信用户 ID，认证失败时中止后续处理。
	// 参数：c 为当前请求；返回值：无，写入身份或错误响应。
	return func(c *gin.Context) {
		// 解析 Authorization 头，仅接受单个 Bearer 凭证。
		parts := strings.Fields(c.GetHeader("Authorization"))
		// 允许认证方案大小写差异，拒绝缺失或额外的凭证片段。
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
			// 返回认证失败并终止后续处理。
			response.AbortError(c, http.StatusUnauthorized, "登录凭证无效")
			return
		}
		// 校验登录凭证并解析当前用户。
		id, err := s.Authenticate(c.Request.Context(), parts[1])
		// 凭证失效统一返回 401，避免暴露用户是否已删除。
		if errors.Is(err, service.ErrUnauthorized) {
			// 返回认证失败并终止后续处理。
			response.AbortError(c, http.StatusUnauthorized, "登录凭证无效")
			return
		}
		if err != nil {
			// 内部故障返回 500 并终止请求，不将数据库异常误报为凭证无效。
			response.AbortError(c, http.StatusInternalServerError, "服务器内部错误")
			return
		}
		// 将已确认的身份信息交给后续处理器。
		setUserID(c, id)
		// 身份校验通过后继续处理请求。
		c.Next()
	}
}

const userIDKey = "auth.user_id"

// UserID 读取认证中间件写入的可信身份，不解析客户端业务参数。
// 参数：c 为非 nil 请求上下文；返回值：用户 ID 和身份是否有效，无身份时为 0、false。
func UserID(c *gin.Context) (uint64, bool) {
	// 读取请求上下文中已保存的信息。
	value, exists := c.Get(userIDKey)
	id, ok := value.(uint64)
	return id, exists && ok && id > 0
}

// setUserID 保存认证服务确认的身份，仅供中间件调用。
// 参数：c 为非 nil 请求上下文，id 为非零可信用户 ID；返回值：无；修改请求上下文。
func setUserID(c *gin.Context, id uint64) {
	// 只保存认证服务确认的身份，供业务层授权使用。
	c.Set(userIDKey, id)
}
