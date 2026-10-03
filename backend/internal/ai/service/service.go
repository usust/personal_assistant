// 文件职责：执行AI业务规则与事务编排。

package service

import (
	"context"
	"errors"
	"time"

	domain "personal_assistant_server/internal/ai/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/capability"
)

// 拒绝本次操作：请提供配置和有效的 user/assistant 文本消息。
var ErrInvalidInput = errors.New("请提供配置和有效的 user/assistant 文本消息")

// Service 负责一次对话的用例：校验文本历史、读取授权配置、设置整轮期限并调用编排器。
type Service struct {
	configs *aiconfigservice.Service
	chat    *Chat
}

// NewService 组装对话业务，不创建网络客户端或数据库连接。
// 参数：configs 为非 nil 配置服务；chat 为带非 nil Executor、Client 的编排器。
// 返回值：服务及依赖错误；无副作用。
func NewService(configs *aiconfigservice.Service, chat *Chat) (*Service, error) {
	if configs == nil || chat == nil || chat.Executor == nil || chat.Client == nil {
		// 拒绝本次操作：对话模块依赖不完整。
		return nil, errors.New("对话模块依赖不完整")
	}
	return &Service{configs: configs, chat: chat}, nil
}

// Run 执行单轮对话，区分开始前错误与已经开始执行后的部分结果。
// 接收者：s 为已初始化服务；参数：ctx 为请求上下文；actor 为认证身份；input 为文本请求。
// 返回值：对话结果与前置错误；工具或模型失败保存在 domain.Result.Error 中，以保留已执行操作。可能产生工具写入副作用。
func (s *Service) Run(ctx context.Context, actor capability.Actor, input domain.ChatInput) (domain.Result, error) {
	if len(input.Messages) == 0 {
		return domain.Result{}, ErrInvalidInput
	}
	messages := make([]domain.Message, 0, len(input.Messages))
	for _, message := range input.Messages {
		if message.Role != "user" && message.Role != "assistant" {
			return domain.Result{}, ErrInvalidInput
		}
		// 仅从文本 DTO 构造模型消息，客户端不能注入本轮 system 或 tool 调用。
		messages = append(messages, domain.Message{Role: message.Role, Content: message.Content})
	}
	// 为外部调用或清理操作设置时间上限。
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	// 释放本次上下文及相关计时资源。
	defer cancel()
	// 取得当前用户有权使用的模型连接。
	connection, err := s.configs.GetUsable(ctx, actor.UserID, input.ConfigID)
	if err != nil {
		return domain.Result{}, err
	}
	// 执行当前业务流程。
	return s.chat.Run(ctx, actor, connection, messages), nil
}
