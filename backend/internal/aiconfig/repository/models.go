// 文件职责：请求上游模型目录、禁止重定向并解析结果。

package repository

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

// FetchModels 请求兼容模型目录；参数：ctx 限制超时，client 为注入客户端，baseURL 为连接地址，apiKey 为密钥，providerName 为提供商。
// 返回值：去重排序的非空模型 ID 或脱敏错误；拒绝重定向，不记录响应正文和密钥。
func FetchModels(ctx context.Context, client *http.Client, baseURL, apiKey, providerName string) ([]string, error) {
	// 解析外部服务地址，供地址规则校验。
	u, err := url.Parse(strings.TrimSpace(baseURL))
	// 取得外部地址主机名用于访问校验。
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "http" && u.Scheme != "https") || strings.TrimSpace(apiKey) == "" {
		// 拒绝本次操作：请填写有效的 API 地址和密钥。
		return nil, errors.New("请填写有效的 API 地址和密钥")
	}
	// 去除后续处理不需要的后缀。
	u.Path = strings.TrimSuffix(strings.TrimRight(u.Path, "/"), "/chat/completions") + "/models"
	// 创建受调用上下文约束的外部请求。
	req, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		// 拒绝本次操作：模型目录地址无效。
		return nil, errors.New("模型目录地址无效")
	}
	// 保存当前操作所需的字段值。
	req.Header.Set("Authorization", "Bearer "+apiKey)
	if providerName == "anthropic" {
		// 保存当前操作所需的字段值。
		req.Header.Set("x-api-key", apiKey)
		// 保存当前操作所需的字段值。
		req.Header.Set("anthropic-version", "2023-06-01")
	}
	// 复制客户端保留既有网络策略，禁止目录重定向携带凭证。
	safeClient := *client
	// 重定向回调参数 req 为下一请求，via 为历史请求；返回固定错误，禁止携带凭证重定向。
	safeClient.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	// 通过受约束的客户端发送外部请求。
	response, err := safeClient.Do(req)
	if err != nil {
		// 拒绝本次操作：模型列表加载失败，请检查连接后重试。
		return nil, errors.New("模型列表加载失败，请检查连接后重试")
	}
	// 释放当前操作持有的资源。
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		// 拒绝本次操作：模型列表加载失败，请检查 API 地址、密钥及模型目录支持。
		return nil, errors.New("模型列表加载失败，请检查 API 地址、密钥及模型目录支持")
	}
	// 读取已限制范围内的响应内容。
	raw, err := io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil || len(raw) > 2<<20 {
		// 拒绝本次操作：模型目录响应过大或读取失败。
		return nil, errors.New("模型目录响应过大或读取失败")
	}
	var payload struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	// 解析业务数据，供后续校验与处理。
	if json.Unmarshal(raw, &payload) != nil {
		// 拒绝本次操作：服务未返回兼容的模型目录。
		return nil, errors.New("服务未返回兼容的模型目录")
	}
	ids := make([]string, 0, len(payload.Data))
	seen := map[string]bool{}
	for _, model := range payload.Data {
		// 规范化输入，避免首尾空白影响校验。
		id := strings.TrimSpace(model.ID)
		if id != "" && len(id) <= 255 && !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	if len(ids) == 0 {
		// 拒绝本次操作：此服务暂无可用模型。
		return nil, errors.New("此服务暂无可用模型")
	}
	// 统一字符串列表的排序。
	sort.Strings(ids)
	return ids, nil
}
