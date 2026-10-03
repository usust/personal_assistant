// 文件职责：校验模型目录连接和保存密钥使用范围。

package service

import (
	"context"
	"fmt"
	"net/http"
	"personal_assistant_server/internal/aiconfig/repository"
	"strings"
	"time"
)

// ModelsInput 为模型目录请求，密钥只作为输入；已有服务 ID 必须具有管理权限。
type ModelsInput struct {
	ConfigID     uint   `json:"config_id"`
	BaseURL      string `json:"base_url"`
	APIKey       string `json:"api_key"`
	ProviderName string `json:"provider_name"`
}

// Models 校验管理权限并获取模型目录，保存密钥仅用于原连接。
// 接收者：s 为初始化服务；参数：ctx 为上下文，actorID 为可信身份，client 为非 nil 网络客户端，input 为连接信息。
// 返回值：模型 ID 列表及授权、输入或上游错误；不返回密钥，调用限时 15 秒。
func (s *Service) Models(ctx context.Context, actorID uint64, client *http.Client, input ModelsInput) ([]string, error) {
	if input.ConfigID != 0 {
		// 复用更新权限检查；空更新不写数据库，也不改变模型版本。
		summary, err := s.Update(ctx, actorID, input.ConfigID, UpdateInput{})
		if err != nil {
			// 返回授权或查询错误，由入口层映射响应。
			return nil, err
		}
		if input.APIKey == "" {
			// 已保存密钥只能用于原地址和原提供商，防止客户端借目录请求把密钥发送到其他服务器。
			if strings.TrimRight(input.BaseURL, "/") != strings.TrimRight(summary.BaseURL, "/") || input.ProviderName != summary.ProviderName {
				// 拒绝将保存密钥发送到客户端指定的新连接。
				return nil, fmt.Errorf("%w：更换连接后请填写 API Key", ErrInvalid)
			}
			// 取得当前用户有权使用的模型连接。
			connection, err := s.GetUsable(ctx, actorID, input.ConfigID)
			if err != nil {
				// 返回授权或查询错误，由入口层映射响应。
				return nil, err
			}
			input.APIKey = connection.APIKey
		}
	}

	// 所有模型目录请求限定为 15 秒，取消时终止网络请求。
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	// 仓储负责外部请求与结果解析，业务层统一标记公开输入错误。
	result, err := repository.FetchModels(ctx, client, input.BaseURL, input.APIKey, input.ProviderName)
	if err != nil {
		return nil, fmt.Errorf("%w：%s", ErrInvalid, err.Error())
	}
	return result, nil
}
