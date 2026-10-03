// 文件职责：封装模型服务 HTTP 请求与上游协议转换。

package repository

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	domain "personal_assistant_server/internal/ai/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
)

// HTTPClient 实现当前兼容 Chat Completions 的协议，不读取数据库或组织对话循环。
type HTTPClient struct{ client *http.Client }

// NewHTTPClient 注入可复用的网络客户端。
// 参数：client 必须非 nil，调用方配置超时；返回值：模型客户端；无网络请求。
func NewHTTPClient(client *http.Client) *HTTPClient { return &HTTPClient{client: client} }

// Complete 请求一次兼容 Chat Completions 的模型接口，不自动重试。
// 参数：ctx 控制超时；config 提供地址/密钥/模型；messages 为协议消息；tools 为工具目录。
// 接收者：s 必须由 NewHTTPClient 构造；返回值：模型消息或脱敏错误，避免把上游密钥返回浏览器。
func (s *HTTPClient) Complete(ctx context.Context, config aiconfigservice.Connection, messages []domain.Message, tools []any) (domain.Message, error) {
	// 序列化业务数据，供存储或响应使用。
	body, err := json.Marshal(map[string]any{"model": config.ModelName, "messages": messages, "tools": tools})
	if err != nil {
		// 拒绝本次操作：模型请求编码失败。
		return domain.Message{}, errors.New("模型请求编码失败")
	}
	// 去除地址尾部多余分隔符。
	endpoint := strings.TrimRight(config.BaseURL, "/")
	// 检查输入是否符合预期后缀。
	if !strings.HasSuffix(endpoint, "/chat/completions") {
		endpoint += "/chat/completions"
	}
	// 创建受调用上下文约束的外部请求。
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		// 拒绝本次操作：AI 配置地址无效。
		return domain.Message{}, errors.New("AI 配置地址无效")
	}
	// 保存当前操作所需的字段值。
	req.Header.Set("Content-Type", "application/json")
	// 保存当前操作所需的字段值。
	req.Header.Set("Authorization", "Bearer "+config.APIKey)
	// 执行外部 HTTP 请求。
	response, err := s.client.Do(req)
	if err != nil {
		// 拒绝本次操作：模型连接失败或请求超时；已执行操作不会自动回滚，请查看操作记录。
		return domain.Message{}, errors.New("模型连接失败或请求超时；已执行操作不会自动回滚，请查看操作记录")
	}
	// 释放当前操作持有的资源。
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		// 为失败补充当前操作的错误上下文。
		return domain.Message{}, fmt.Errorf("模型接口返回 HTTP %d，请检查地址、密钥及模型的工具调用支持", response.StatusCode)
	}
	var payload struct {
		Choices []struct {
			Message domain.Message `json:"message"`
		} `json:"choices"`
	}
	// 解析输入数据，交给后续业务校验。
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&payload); err != nil || len(payload.Choices) == 0 {
		// 拒绝本次操作：模型响应格式不兼容，需要支持工具调用的 Chat Completions 接口。
		return domain.Message{}, errors.New("模型响应格式不兼容，需要支持工具调用的 Chat Completions 接口")
	}
	return payload.Choices[0].Message, nil
}
