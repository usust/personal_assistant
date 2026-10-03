// 文件职责：维护模型提供商静态目录。

package service

// Provider 是配置页可选的提供商名称，不表示已支持其原生协议。
type Provider struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	BaseURL string `json:"base_url"`
}

// Providers 返回独立的静态提供商目录；当前对话仍要求兼容 Chat Completions 协议。
// 参数：无；返回值：可修改而不会影响其他请求的提供商切片；无副作用。
func Providers() []Provider {
	// 使用 Chat Completions 兼容地址；千问默认北京地域，自定义提供商由用户填写。
	return []Provider{
		{ID: "openai", Name: "OpenAI", BaseURL: "https://api.openai.com/v1"},
		{ID: "anthropic", Name: "Anthropic", BaseURL: "https://api.anthropic.com/v1"},
		{ID: "gemini", Name: "Google Gemini", BaseURL: "https://generativelanguage.googleapis.com/v1beta/openai"},
		{ID: "deepseek", Name: "DeepSeek", BaseURL: "https://api.deepseek.com"},
		{ID: "qwen", Name: "通义千问", BaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"},
		{ID: "custom", Name: "自定义提供商", BaseURL: ""},
	}
}
