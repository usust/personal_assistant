// 文件职责：将task业务适配为共享 AI 能力。

package capability

import (
	"context"
	"encoding/json"
	"errors"

	"personal_assistant_server/internal/capability"
	"personal_assistant_server/internal/task/service"
)

// Definitions 将同一业务服务公开为 AI 工具；参数：s 为非 nil 服务；返回值：工具描述与 Schema，无数据库副作用。
func Definitions(s *service.Service) []capability.Capability {
	entries := []struct{ name, description, schema string }{
		{name: "task.list", description: "查询当前用户全部任务，包括归档任务和原始进度；先查清单与任务 ID，父级进度应由后代汇总。", schema: `{"type": "object", "properties": {}, "required": [], "additionalProperties": false}`},
		{name: "task.events", description: "读取当前用户最近 100 条任务操作记录。", schema: `{"type": "object", "properties": {}, "required": [], "additionalProperties": false}`},
		{name: "task_list.list", description: "查询当前用户清单。", schema: `{"type": "object", "properties": {}, "required": [], "additionalProperties": false}`},
		{name: "task_list.get", description: "按 ID 查询自己的清单。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}}, "required": ["id"], "additionalProperties": false}`},
		{name: "task_list.create", description: "创建清单，changes 必须含 name。", schema: `{"type": "object", "properties": {"changes": {"type": "object", "properties": {"name": {"type": "string"}, "remark": {"type": "string"}, "color": {"type": "string"}, "icon": {"type": "string"}}, "additionalProperties": false, "minProperties": 1, "required": ["name"]}}, "required": ["changes"], "additionalProperties": false}`},
		{name: "task_list.update", description: "局部修改自己的清单，仅传实际修改字段。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}, "changes": {"type": "object", "properties": {"name": {"type": "string"}, "remark": {"type": "string"}, "color": {"type": "string"}, "icon": {"type": "string"}}, "additionalProperties": false, "minProperties": 1}}, "required": ["id", "changes"], "additionalProperties": false}`},
		{name: "task_list.delete", description: "删除自己的清单及其中全部任务；仅在用户明确要求删除时调用。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}}, "required": ["id"], "additionalProperties": false}`},
		{name: "task.create", description: "创建任务；changes 必须含 title 和 listId。拆分任务时为每个子任务指定 parentId 与 taskType=subtask。", schema: `{"type": "object", "properties": {"changes": {"type": "object", "properties": {"title": {"type": "string"}, "remark": {"type": "string"}, "taskType": {"type": "string", "enum": ["main", "subtask"]}, "priority": {"type": "string", "enum": ["high", "medium", "low"]}, "startDate": {"type": "string"}, "startTime": {"type": "string"}, "endDate": {"type": "string"}, "endTime": {"type": "string"}, "progressUnit": {"type": "string"}, "listId": {"type": "integer", "minimum": 1}, "parentId": {"type": ["integer", "null"], "minimum": 1}, "archived": {"type": "boolean"}, "progressTotal": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}, "progressCompleted": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}, "progressStep": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}}, "additionalProperties": false, "minProperties": 1, "required": ["title", "listId"]}}, "required": ["changes"], "additionalProperties": false}`},
		{name: "task.update", description: "局部修改自己的任务；parentId=null 解除父级，禁止循环和跨清单父级。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}, "changes": {"type": "object", "properties": {"title": {"type": "string"}, "remark": {"type": "string"}, "taskType": {"type": "string", "enum": ["main", "subtask"]}, "priority": {"type": "string", "enum": ["high", "medium", "low"]}, "startDate": {"type": "string"}, "startTime": {"type": "string"}, "endDate": {"type": "string"}, "endTime": {"type": "string"}, "progressUnit": {"type": "string"}, "listId": {"type": "integer", "minimum": 1}, "parentId": {"type": ["integer", "null"], "minimum": 1}, "archived": {"type": "boolean"}, "progressTotal": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}, "progressCompleted": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}, "progressStep": {"type": ["number", "string"], "description": "非负数，最多两位小数，不超过十亿；总量和步长必须大于零"}}, "additionalProperties": false, "minProperties": 1}}, "required": ["id", "changes"], "additionalProperties": false}`},
		{name: "task.delete", description: "删除任务；存在下级时必须显式 cascade=true，需用户明确要求删除整棵子树。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}, "cascade": {"type": "boolean"}}, "required": ["id"], "additionalProperties": false}`},
		{name: "task.progress", description: "对可执行叶子子任务增减一步；归档任务不可操作，allowExceedTotal=true 表示超出时截断为总量。", schema: `{"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}, "operation": {"type": "string", "enum": ["increment", "decrement"]}, "allowExceedTotal": {"type": "boolean"}}, "required": ["id", "operation"], "additionalProperties": false}`},
		{name: "task.reorder", description: "按 taskIds 顺序调整自己的任务排序，最多 1000 项，不改变父级关系。", schema: `{"type": "object", "properties": {"taskIds": {"type": "array", "items": {"type": "integer", "minimum": 1}, "minItems": 1, "maxItems": 1000, "uniqueItems": true}}, "required": ["taskIds"], "additionalProperties": false}`},
	}
	result := make([]capability.Capability, 0, len(entries))
	for _, entry := range entries {
		// 工具回调只透传可信身份和参数，不接受模型指定操作者；参数：ctx、actor、in 为调用上下文、认证身份、命令；返回值：业务结果或可公开错误。
		def := capability.Define(entry.name, entry.description, func(ctx context.Context, actor capability.Actor, in service.Input) (any, error) {
			// 将业务操作交给共享服务执行。
			out, err := s.Execute(ctx, actor, entry.name, in, "ai")
			// 区分预期错误与需要继续上报的异常。
			if errors.Is(err, service.ErrInvalid) || errors.Is(err, service.ErrNotFound) || errors.Is(err, service.ErrConflict) {
				// 保留内部错误原因并指定对外提示。
				return nil, capability.NewPublicError(err.Error(), err)
			}
			return out, err
		})
		def.InputSchema = json.RawMessage(entry.schema)
		result = append(result, def)
	}
	return result
}
