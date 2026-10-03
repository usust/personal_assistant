// 文件职责：定义与传输协议无关的能力契约，将类型化业务输入适配为共享执行入口。

// Package capability 提供与 HTTP、AI 无关的最小能力注册和执行入口。
package capability

import (
	"context"
	"encoding/json"
	"fmt"
)

// Actor 只接收服务端认证后的身份，不能从模型或请求体中读取。
type Actor struct{ UserID uint64 }

// Capability 把工具描述与业务适配绑定；业务服务负责授权，不依赖 Gin 或数据库。
// InputSchema 描述 JSON 参数，供 AI 适配器生成工具定义。
type Capability struct {
	Name        string
	Description string
	InputSchema json.RawMessage
	Run         func(context.Context, Actor, json.RawMessage) (any, error)
}

// Define 将具体业务输入转换为统一的 JSON 调用入口，业务校验仍交给 Service。
//
// 参数：T 是业务输入类型；name 是注册表中唯一的能力名称；description 是能力描述；
// run 是非 nil 业务回调，接收上下文、可信身份和解析后的 T，必须调用带业务授权的服务，返回结果及错误。
// 返回值：封装后的能力定义，此时不会执行授权或业务逻辑。
func Define[T any](name, description string, run func(context.Context, Actor, T) (any, error)) Capability {
	return Capability{
		Name: name, Description: description,
		// Run 将 JSON 参数转换为业务输入。
		// 参数：ctx 传递取消信号；actor 为认证入口提供的可信身份；raw 是待解析的 JSON。
		// 返回值：业务回调的结果及错误；解析失败时返回 nil 和包装后的 ErrInvalidInput。
		Run: func(ctx context.Context, actor Actor, raw json.RawMessage) (any, error) {
			var input T
			// 统一标识 JSON 解析错误，供调用方通过 errors.Is 分类处理。
			if err := json.Unmarshal(raw, &input); err != nil {
				// 为失败补充当前操作的错误上下文。
				return nil, fmt.Errorf("%w: %v", ErrInvalidInput, err)
			}
			// 执行应用完整启动与退出流程。
			return run(ctx, actor, input)
		},
	}
}
