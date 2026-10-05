// 文件职责：执行任务业务规则与事务编排。

package service

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	domain "personal_assistant_server/internal/task/model"
)

var taskFields = map[string]string{"icon": "icon", "title": "title", "remark": "remark", "listId": "list_id", "parentId": "parent_id", "taskType": "task_type", "priority": "priority", "startDate": "start_date", "startTime": "start_time", "endDate": "end_date", "endTime": "end_time", "archived": "archived", "autoArchive": "auto_archive", "progressTotal": "progress_total", "progressCompleted": "progress_completed", "progressStep": "progress_step", "progressUnit": "progress_unit"}

var listFields = map[string]string{"name": "name", "remark": "remark", "color": "color", "icon": "icon"}

// 预编译业务字段校验规则。
var colorPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

// patch 只接受白名单字段并合并到待校验对象；参数：raw 为对象，allowed 为服务端白名单，target 为非 nil 指针；返回值：SQL 字段 map 及输入错误，无数据库副作用。
func patch(raw json.RawMessage, allowed map[string]string, target any) (map[string]any, error) {
	var input map[string]json.RawMessage
	// 解析业务输入，供后续校验与处理。
	if json.Unmarshal(raw, &input) != nil || len(input) == 0 {
		// 拒绝本次操作：必须提交非空字段对象。
		return nil, Invalid("必须提交非空字段对象")
	}
	fields := map[string]any{}
	for key, value := range input {
		column, ok := allowed[key]
		if !ok {
			// 拒绝本次操作：不允许更新字段: 。
			return nil, Invalid("不允许更新字段: " + key)
		}
		if string(value) == "null" && key != "parentId" {
			// 将输入问题转换为业务校验错误。
			return nil, Invalid(key + " 不允许 null")
		}
		// 检查输入是否符合预期前缀。
		if strings.HasPrefix(key, "progress") && key != "progressUnit" {
			var text string
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(value, &text) == nil {
				value = json.RawMessage(text)
			}
			// 将输入字段解析为数值。
			n, err := strconv.ParseFloat(string(value), 64)
			// 拒绝无法用于业务计算的数值。
			if err != nil || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || n > 1e9 || math.Abs(n*100-math.Round(n*100)) > 0.00001 {
				// 拒绝本次操作：进度必须为最多两位小数的非负数，且不超过十亿。
				return nil, Invalid("进度必须为最多两位小数的非负数，且不超过十亿")
			}
			input[key] = value
		}
		var v any
		// 解析业务数据，供后续校验与处理。
		if json.Unmarshal(value, &v) != nil {
			// 拒绝本次操作：字段格式错误。
			return nil, Invalid("字段格式错误")
		}
		fields[column] = v
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, _ := json.Marshal(input)
	// 将 JSON 数据还原为业务结构。
	if json.Unmarshal(encoded, target) != nil {
		// 拒绝本次操作：字段类型错误。
		return nil, Invalid("字段类型错误")
	}
	return fields, nil
}

// invalid 构造可识别的业务参数错误；参数：message 为公开说明；返回值：包装后的错误。
func Invalid(message string) error { return fmt.Errorf("%w: %s", ErrInvalid, message) }

// validateTask 校验合并后的完整任务；参数：t 为候选任务；返回值：校验错误，无副作用。
func validateTask(t domain.Task) error {
	// 规范化输入，避免首尾空白影响校验。
	if strings.TrimSpace(t.Title) == "" || len([]rune(t.Title)) > 256 || len([]rune(t.Remark)) > 10000 || len([]rune(t.ProgressUnit)) > 20 || len(t.Icon) > 64 || strings.TrimSpace(t.Icon) == "" {
		// 拒绝本次操作：标题、备注、图标或单位长度无效。
		return Invalid("标题、备注、图标或单位长度无效")
	}
	if t.Priority != "high" && t.Priority != "medium" && t.Priority != "low" {
		// 拒绝本次操作：优先级无效。
		return Invalid("优先级无效")
	}
	if t.TaskType != "main" && t.TaskType != "subtask" {
		// 拒绝本次操作：任务类型无效。
		return Invalid("任务类型无效")
	}
	if t.ProgressTotal <= 0 || t.ProgressStep <= 0 || t.ProgressStep > t.ProgressTotal || t.ProgressCompleted > t.ProgressTotal {
		// 拒绝本次操作：进度总量和步长必须为正数，步长及完成量不能超过总量。
		return Invalid("进度总量和步长必须为正数，步长及完成量不能超过总量")
	}
	for _, pair := range [][2]string{{t.StartDate, t.StartTime}, {t.EndDate, t.EndTime}} {
		if pair[0] != "" {
			// 按业务格式解析日期或时间。
			if _, err := time.Parse("2006-01-02", pair[0]); err != nil {
				// 拒绝本次操作：日期格式应为 YYYY-MM-DD。
				return Invalid("日期格式应为 YYYY-MM-DD")
			}
		}
		if pair[1] != "" {
			if pair[0] == "" {
				// 拒绝本次操作：时间必须附带日期。
				return Invalid("时间必须附带日期")
			}
			// 按业务格式解析日期或时间。
			if _, err := time.Parse("15:04", pair[1]); err != nil {
				// 拒绝本次操作：时间格式应为 HH:mm。
				return Invalid("时间格式应为 HH:mm")
			}
		}
	}
	startTime, endTime := t.StartTime, t.EndTime
	if startTime == "" {
		startTime = "00:00"
	}
	if endTime == "" {
		endTime = "23:59"
	}
	if t.StartDate != "" && t.EndDate != "" && t.StartDate+" "+startTime > t.EndDate+" "+endTime {
		// 拒绝本次操作：结束时间不能早于开始时间。
		return Invalid("结束时间不能早于开始时间")
	}
	return nil
}

// validateList 校验清单属性；参数：l 为候选清单；返回值：输入错误，无副作用。
func validateList(l domain.List) error {
	// 规范化输入，避免首尾空白影响校验。
	if strings.TrimSpace(l.Name) == "" || len([]rune(l.Name)) > 128 || len([]rune(l.Remark)) > 2000 || len(l.Icon) > 64 || strings.TrimSpace(l.Icon) == "" || !colorPattern.MatchString(l.Color) {
		// 拒绝本次操作：清单名称、备注、图标或颜色无效。
		return Invalid("清单名称、备注、图标或颜色无效")
	}
	return nil
}
