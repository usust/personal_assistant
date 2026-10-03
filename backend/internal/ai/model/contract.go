// 文件职责：定义AI领域模型与协议契约。

package model

import (
	"context"

	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
)

// Completer 是对话编排所需的最小模型边界，可以注入真实 HTTP 客户端或测试实现。
// Complete 接收截止时间、已授权连接、协议历史与工具目录，返回模型消息及脱敏错误；不得重试写工具。
type Completer interface {
	Complete(context.Context, aiconfigservice.Connection, []Message, []any) (Message, error)
}

// Message 仅表示模型协议消息；浏览器历史使用独立 ChatMessage DTO，不接受工具字段。
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
}

// ToolCall 保存模型返回的函数名、JSON 参数以及关联结果的 ID。
type ToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

// ChatMessage 仅接受浏览器的文本历史，与模型协议中的工具调用字段隔离。
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatInput 定义现有对话请求协议，ConfigID 指向当前用户可使用的配置。
type ChatInput struct {
	ConfigID uint          `json:"config_id"`
	Messages []ChatMessage `json:"messages"`
}

// Action 只返回执行名称和状态，不把密码等工具入参放进前端操作记录。
type Action struct {
	Name    string `json:"name"`
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
}

// Result 同时返回回复和已经发生的操作；后续模型请求失败不会丢失操作状态。
type Result struct {
	Reply   string   `json:"reply"`
	Actions []Action `json:"actions"`
	Error   string   `json:"error,omitempty"`
}
