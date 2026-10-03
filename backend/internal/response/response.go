// Package response 定义普通 JSON API 共用的 HTTP 响应协议。
package response

import "github.com/gin-gonic/gin"

// Envelope 保留固定的三个响应字段；Code 与实际 HTTP 状态码一致，Data 无内容时仍序列化为 null。
type Envelope struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data"`
}

// Success 写入成功响应。
// 参数：c 为非 nil 请求上下文；status 为允许响应体的 2xx HTTP 状态码；data 为业务数据，无数据传 nil。
// 返回值：无；副作用为写入 HTTP 状态与 JSON，message 固定为 ok。
func Success(c *gin.Context, status int, data any) {
	c.JSON(status, Envelope{Code: status, Message: "ok", Data: data})
}

// Error 写入失败响应，不改变处理链状态。
// 参数：c 为非 nil 请求上下文；status 为 4xx 或 5xx HTTP 状态码；message 为可公开的错误信息。
// 返回值：无；副作用为写入 JSON，data 为 null；调用方应立即返回。
func Error(c *gin.Context, status int, message string) {
	c.JSON(status, Envelope{Code: status, Message: message, Data: nil})
}

// AbortError 中止处理链并写入失败响应，用于认证中间件。
// 参数：c 为非 nil 请求上下文；status 为 4xx 或 5xx HTTP 状态码；message 为可公开的错误信息。
// 返回值：无；副作用为阻止后续处理器执行，写入 JSON，data 为 null。
func AbortError(c *gin.Context, status int, message string) {
	c.Abort()
	Error(c, status, message)
}
