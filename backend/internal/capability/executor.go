// 文件职责：按能力名称解析输入并执行已注册业务能力，为模型调用提供统一入口。

package capability

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
)

// Executor 供 AI 和后台任务按名称调用业务能力，HTTP 可直接调用同一业务服务。
type Executor struct{ registry *Registry }

// NewExecutor 注入注册表，不使用全局变量。
//
// 参数：registry 是已组装的能力注册表，调用方必须传入非 nil 值。
// 返回值：持有该注册表的新执行器；不会复制注册表或立即执行业务。
func NewExecutor(registry *Registry) *Executor { return &Executor{registry: registry} }

// Invoke 按名称查找能力，将可信身份与工具参数传给业务适配器。
//
// 接收者：e 必须由非 nil 注册表构造，其注册表在调用期间保持只读。
// 参数：ctx 是调用上下文，用于传递取消信号和截止时间；actor 是服务端认证后的调用身份；
// name 是已注册的能力名称；input 是能力所需的 JSON 参数，无字段输入可传入 {}。
// 返回值：能力执行结果及错误；未找到能力时返回包装后的 ErrNotFound，
// 业务服务的授权错误和执行错误原样返回。执行同步完成，不自动重试或回滚其他能力。
func (e *Executor) Invoke(ctx context.Context, actor Actor, name string, input json.RawMessage) (any, error) {
	entry, exists := e.registry.entries[name]
	if !exists {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w: %s", ErrNotFound, name)
	}
	// 每项业务在 Service 内授权；透传 actor 防止适配器从模型参数猜测操作者。
	return entry.Run(ctx, actor, input)
}

// Definitions 返回按名称排序的能力定义，供 AI 生成工具目录。
// 接收者：e 为已初始化执行器；参数：无；返回值：独立的定义切片，不修改注册表。
func (e *Executor) Definitions() []Capability {
	entries := make([]Capability, 0, len(e.registry.entries))
	for _, entry := range e.registry.entries {
		entries = append(entries, entry)
	}
	// 固定顺序使模型工具目录和名称映射在每次请求中保持一致。
	// 排序回调参数 i、j 为切片索引；返回是否应把 i 排在 j 前；无其他副作用。
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	return entries
}
