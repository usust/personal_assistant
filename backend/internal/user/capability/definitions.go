// 文件职责：将用户业务服务适配为模型能力，并转换可公开错误；授权规则保留在业务服务。

// Package capability 将用户业务适配为模型可调用的能力，不实现数据库与授权规则。
package capability

import (
	"context"
	"encoding/json"
	"errors"

	core "personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/user/service"
)

const (
	List     = "user.list"
	Register = "user.register"
	Update   = "user.update"
	Delete   = "user.delete"
)

// UpdateInput 将目标用户与待校验字段分开，Changes 永远不直接用于数据库更新。
type UpdateInput struct {
	ID      uint64         `json:"id"`
	Changes map[string]any `json:"changes"`
}

// DeleteInput 指定删除目标；操作者只能来自可信 Actor。
type DeleteInput struct {
	ID uint64 `json:"id"`
}

// Definitions 返回用户模块的四项工具定义，绑定同一用户 Service。
// 参数：users 为非 nil、已初始化服务；返回值：独立能力切片；无数据库操作，执行时由 Service 校验权限。
func Definitions(users *service.Service) []core.Capability {
	entries := []core.Capability{
		// 列表回调复用公开用户查询；ctx 控制取消，actor 与空输入不参与筛选；返回用户列表或工具错误。
		core.Define(List, "获取全部用户列表", func(ctx context.Context, actor core.Actor, input struct{}) (any, error) {
			// 读取用户业务列表。
			result, err := users.List(ctx)
			// 转换为模型调用可公开的业务错误。
			return result, toolError(err)
		}),
		// 注册回调只创建普通用户；ctx 控制取消，actor 不授予额外角色，input 为注册字段；返回用户或工具错误。
		core.Define(Register, "注册普通用户", func(ctx context.Context, actor core.Actor, input service.RegisterInput) (any, error) {
			// 执行用户注册规则。
			result, err := users.Register(ctx, input)
			// 转换为模型调用可公开的业务错误。
			return result, toolError(err)
		}),
		// 更新回调把可信 actor 与模型提交的目标分开；返回更新后用户或授权、字段、存储错误。
		core.Define(Update, "管理员修改用户实际提交的字段", func(ctx context.Context, actor core.Actor, input UpdateInput) (any, error) {
			// 授权并应用用户字段变更。
			result, err := users.Update(ctx, actor.UserID, input.ID, input.Changes)
			// 转换为模型调用可公开的业务错误。
			return result, toolError(err)
		}),
		// 删除回调由服务检查 actor；ctx 控制取消，input 指定目标；返回 nil 数据及工具错误，成功物理删除。
		core.Define(Delete, "管理员删除指定用户", func(ctx context.Context, actor core.Actor, input DeleteInput) (any, error) {
			// 转换为模型调用可公开的业务错误。
			return nil, toolError(users.Delete(ctx, actor.UserID, input.ID))
		}),
	}
	// Schema 仅描述工具协议；业务校验仍由服务执行，不能把模型输出视为已通过校验。
	schemas := map[string]string{
		List:     `{"type":"object","properties":{},"additionalProperties":false}`,
		Register: `{"type":"object","properties":{"account":{"type":"string","description":"3至64位小写字母、数字或下划线"},"password":{"type":"string","description":"8至72字节"},"nickname":{"type":"string","description":"1至64个字符"}},"required":["account","password","nickname"],"additionalProperties":false}`,
		Update:   `{"type":"object","properties":{"id":{"type":"integer","minimum":1},"changes":{"type":"object","properties":{"account":{"type":"string"},"nickname":{"type":"string"},"password":{"type":"string"},"role":{"type":"string","enum":["user","admin","sys_admin"]}},"minProperties":1,"additionalProperties":false}},"required":["id","changes"],"additionalProperties":false}`,
		Delete:   `{"type":"object","properties":{"id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false}`,
	}
	for i := range entries {
		entries[i].InputSchema = json.RawMessage(schemas[entries[i].Name])
	}
	return entries

}

// toolError 把用户业务错误转换为通用、可展示的工具错误，AI 无需依赖用户服务。
// 参数：err 可为 nil；返回值：带公开消息的已知错误或原始内部错误；原始错误只供日志和诊断使用。
func toolError(err error) error {
	for _, known := range []error{service.ErrForbidden, service.ErrInvalidInput, service.ErrAccountExists, service.ErrUserNotFound} {
		// 区分预期错误与需要继续上报的异常。
		if errors.Is(err, known) {
			// 为模型调用提供安全的业务错误说明。
			return core.NewPublicError(err.Error(), err)
		}
	}
	return err
}
