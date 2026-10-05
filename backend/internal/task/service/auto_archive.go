package service

import (
	"gorm.io/gorm"
	"math"
	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/repository"
)

// archiveCompletedTasks 归档已完成且开启自动归档的任务；参数：tx 为持有用户锁的写事务，owner 为可信用户 ID；返回值：本次归档 ID 集合和数据库错误；包括归档叶节点的汇总，空主任务不归档，不级联修改下级，失败由调用方回滚。
func archiveCompletedTasks(tx *gorm.DB, owner uint64) (map[uint64]bool, error) {
	rows, err := repository.ReadTasks(tx, owner)
	if err != nil {
		return nil, err
	}
	children := map[uint64][]domain.Task{}
	for _, row := range rows {
		if row.ParentID != nil {
			children[*row.ParentID] = append(children[*row.ParentID], row)
		}
	}
	archived := map[uint64]bool{}
	for _, row := range rows {
		if !row.AutoArchive || row.Archived {
			continue
		}
		total, completed := aggregateArchiveProgress(row, children, map[uint64]bool{})
		// 按百分之一整数汇总，与客户端精度一致，避免浮点误差误判完成。
		if total > 0 && completed >= total {
			if err := repository.UpdateTask(tx, owner, row.ID, map[string]any{"archived": true}); err != nil {
				return nil, err
			}
			archived[row.ID] = true
		}
	}
	return archived, nil
}

// aggregateArchiveProgress 汇总具体叶节点进度；参数：row 为当前任务，children 为同一用户的子节点索引，visited 为当前递归路径；返回值：目标和完成量的百分之一整数，循环及空主任务贡献零；无副作用。
func aggregateArchiveProgress(row domain.Task, children map[uint64][]domain.Task, visited map[uint64]bool) (int64, int64) {
	if visited[row.ID] {
		return 0, 0
	}
	if len(children[row.ID]) == 0 {
		if row.TaskType == "main" {
			return 0, 0
		}
		return int64(math.Round(row.ProgressTotal * 100)), int64(math.Round(row.ProgressCompleted * 100))
	}
	visited[row.ID] = true
	defer delete(visited, row.ID)
	var total, completed int64
	for _, child := range children[row.ID] {
		t, c := aggregateArchiveProgress(child, children, visited)
		total += t
		completed += c
	}
	return total, completed
}
