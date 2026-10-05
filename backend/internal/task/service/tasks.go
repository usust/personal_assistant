// 文件职责：执行任务业务规则与事务编排。

package service

import (
	"math"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/repository"
)

// taskMutation 校验并执行任务变更；参数：tx 持有用户锁，owner 为身份，op 为操作，in 为命令；返回值：任务或删除结果及错误，所有节点都限定归属。
func (s *Service) taskMutation(tx *gorm.DB, owner uint64, op string, in Input) (any, error) {
	rows, readErr := repository.ReadTasks(tx, owner)
	// 读取符合业务条件的记录集合。
	if err := readErr; err != nil {
		return nil, err
	}
	byID := map[uint64]domain.Task{}
	for _, r := range rows {
		byID[r.ID] = r
	}
	row := domain.Task{OwnerID: owner, Icon: "Folder", TaskType: "main", Priority: "medium", ProgressTotal: 100, ProgressStep: 1}
	if op != "task.create" && op != "task.reorder" {
		var ok bool
		row, ok = byID[in.ID]
		if !ok {
			return nil, ErrNotFound
		}
	}
	if op == "task.reorder" {
		if len(in.TaskIDs) == 0 || len(in.TaskIDs) > 1000 {
			// 拒绝本次操作：排序需要 1 至 1000 个任务。
			return nil, Invalid("排序需要 1 至 1000 个任务")
		}
		seen := map[uint64]bool{}
		for i, id := range in.TaskIDs {
			if _, ok := byID[id]; !ok {
				return nil, ErrNotFound
			}
			if seen[id] {
				// 拒绝本次操作：排序 ID 重复。
				return nil, Invalid("排序 ID 重复")
			}
			seen[id] = true
			// 仅写入本次经过校验的变更字段。
			if err := repository.UpdateTask(tx, owner, id, map[string]any{"sort_order": i}); err != nil {
				return nil, err
			}
		}
		return map[string]any{"reordered": len(in.TaskIDs)}, nil
	}
	children := 0
	for _, r := range rows {
		if r.ParentID != nil && *r.ParentID == row.ID {
			children++
		}
	}
	if op == "task.delete" {
		if children > 0 && !in.Cascade {
			return nil, ErrConflict
		}
		ids := []uint64{row.ID}
		selected := map[uint64]bool{row.ID: true}
		for i := 0; i < len(ids); i++ {
			for _, r := range rows {
				if r.ParentID != nil && *r.ParentID == ids[i] && !selected[r.ID] {
					selected[r.ID] = true
					ids = append(ids, r.ID)
				}
			}
		}
		// 删除满足业务范围约束的记录。
		err := repository.DeleteTasks(tx, owner, ids)
		return map[string]any{"affectedParent": nil, "deletedIds": ids}, err
	}
	if op == "task.progress" {
		if row.Archived || row.TaskType != "subtask" || children > 0 {
			return nil, ErrConflict
		}
		value := row.ProgressCompleted
		switch in.Operation {
		case "increment":
			value += row.ProgressStep
		case "decrement":
			value -= row.ProgressStep
		default:
			// 拒绝本次操作：进度操作无效。
			return nil, Invalid("进度操作无效")
		}
		// 取当前业务约束下的较大值。
		value = math.Max(0, math.Round(value*100)/100)
		if value > row.ProgressTotal {
			if !in.AllowExceedTotal {
				return nil, ErrConflict
			}
			value = row.ProgressTotal
		}
		row.ProgressCompleted = value
		// 仅写入本次经过校验的变更字段。
		return row, repository.UpdateTask(tx, owner, row.ID, map[string]any{"progress_completed": value})
	}
	oldList, oldParent, oldType := row.ListID, row.ParentID, row.TaskType
	// 通过白名单解析实际提交的更新字段。
	fields, err := patch(in.Changes, taskFields, &row)
	if err != nil {
		return nil, err
	}
	// 检查任务字段与状态约束。
	if err = validateTask(row); err != nil {
		return nil, err
	}

	// 读取满足条件的目标记录。
	if _, err = repository.ReadList(tx, owner, row.ListID); err != nil {
		return nil, err
	}
	// 历史具体任务容器保持可编辑；禁止把已有下级的主任务变成具体任务，不隐式转换旧数据。
	if children > 0 && oldType == "main" && row.TaskType != "main" {
		return nil, Invalid("有下级的主任务不能改为具体任务")
	}
	parentChanged := (oldParent == nil) != (row.ParentID == nil)
	if oldParent != nil && row.ParentID != nil {
		parentChanged = *oldParent != *row.ParentID
	}
	// 仅新增或实质重挂父级要求主任务；未变历史父关系的普通PATCH继续兼容。
	if row.ParentID != nil && (op == "task.create" || parentChanged) {
		p, ok := byID[*row.ParentID]
		if !ok {
			return nil, ErrNotFound
		}
		if p.TaskType != "main" {
			return nil, Invalid("父级必须为主任务")
		}
	}
	visited := map[uint64]bool{row.ID: true}
	parent := row.ParentID
	for parent != nil {
		p, ok := byID[*parent]
		if !ok {
			return nil, ErrNotFound
		}
		if visited[p.ID] || p.ListID != row.ListID {
			// 拒绝本次操作：父级关系循环或跨清单。
			return nil, Invalid("父级关系循环或跨清单")
		}
		visited[p.ID] = true
		parent = p.ParentID
	}
	if op == "task.create" {
		row.SortOrder = len(rows)
		// 保存新建的业务记录。
		err = repository.CreateTask(tx, &row)
	} else {
		// 验证全部完成后才写根字段；清单归属变化在同一用户锁事务中迁移所有后代，任何失败整体回滚。
		err = repository.UpdateTask(tx, owner, row.ID, fields)
		if err == nil && oldList != row.ListID {
			selected := map[uint64]bool{row.ID: true}
			ids := []uint64{row.ID}
			for i := 0; i < len(ids); i++ {
				for _, child := range rows {
					if child.ParentID != nil && *child.ParentID == ids[i] && !selected[child.ID] {
						selected[child.ID] = true
						ids = append(ids, child.ID)
					}
				}
			}
			for _, id := range ids[1:] {
				if err = repository.UpdateTask(tx, owner, id, map[string]any{"list_id": row.ListID}); err != nil {
					break
				}
			}
		}
	}
	return row, err
}
