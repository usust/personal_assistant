// 文件职责：执行任务业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"

	"gorm.io/gorm"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/repository"
)

// 拒绝本次操作：任务参数无效。
var ErrInvalid = errors.New("任务参数无效")

// 拒绝本次操作：任务或清单不存在。
var ErrNotFound = errors.New("任务或清单不存在")

// 拒绝本次操作：操作与当前任务状态冲突。
var ErrConflict = errors.New("操作与当前任务状态冲突")

// Service 共享数据库，HTTP 与 AI 均通过 Execute 执行业务。
type Service struct{ db *gorm.DB }

// NewService 注入数据库；参数：db 必须非 nil；返回值：服务，不执行迁移。
func NewService(db *gorm.DB) *Service { return &Service{db: db} }

// Input 定义工具与 HTTP 共用命令，Actor 和来源由适配器传入。
type Input struct {
	ID               uint64          `json:"id"`
	Changes          json.RawMessage `json:"changes"`
	Cascade          bool            `json:"cascade"`
	Operation        string          `json:"operation"`
	AllowExceedTotal bool            `json:"allowExceedTotal"`
	TaskIDs          []uint64        `json:"taskIds"`
}

// Execute 在统一授权和事务内执行白名单操作；参数：ctx 控制取消，actor 是可信身份，op 为能力名，in 为命令，source 为 http 或 ai；返回值：结果及错误。写操作产生原子事件记录，失败整体回滚。
func (s *Service) Execute(ctx context.Context, actor capability.Actor, op string, in Input, source string) (any, error) {
	var result any
	// 按操作者锁定用户行，串行化同一用户的任务树变更，防止并发重挂形成环或丢失进度。
	// 参数：tx 为事务；返回值：错误触发业务及事件回滚，nil 提交。
	err := repository.Transaction(ctx, s.db, func(tx *gorm.DB) error {
		if actor.UserID == 0 {
			return ErrNotFound
		}

		// 读取满足条件的目标记录。
		if err := repository.LockOwner(tx, actor.UserID); err != nil {
			return err
		}
		var err error
		switch op {
		case "task.list":
			rows, queryErr := repository.ReadTasks(tx, actor.UserID)
			err = queryErr
			result = rows
			return err
		case "task.events":
			rows, queryErr := repository.ReadEvents(tx, actor.UserID)
			err = queryErr
			result = rows
			return err
		case "task_list.list":
			rows, queryErr := repository.ReadLists(tx, actor.UserID)
			err = queryErr
			result = rows
			return err
		case "task_list.get":
			var row domain.List
			// 读取满足条件的目标记录。
			row, err = repository.ReadList(tx, actor.UserID, in.ID)
			result = row
			return err
		case "task_list.create", "task_list.update", "task_list.delete":
			// 执行任务清单变更并维护关联规则。
			result, err = s.listMutation(tx, actor.UserID, op, in)
		case "task.create", "task.update", "task.delete", "task.progress", "task.reorder":
			// 执行任务变更并维护关联规则。
			result, err = s.taskMutation(tx, actor.UserID, op, in)
		default:
			// 拒绝本次操作：未知操作。
			return Invalid("未知操作")
		}
		if err != nil {
			return err
		}
		id := in.ID
		switch row := result.(type) {
		case domain.Task:
			id = row.ID
		case domain.List:
			id = row.ID
		}
		// 保存新建的业务记录。
		return repository.CreateEvent(tx, &domain.Event{OwnerID: actor.UserID, Operation: op, EntityID: id, Source: source})
	})
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		err = ErrNotFound
	}
	return result, err
}
