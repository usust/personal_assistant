// 文件职责：执行任务业务规则与事务编排。

package service

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/repository"
)

// listMutation 执行清单写操作；参数：tx 为持有用户锁的事务，owner 为可信用户，op 为操作，in 为命令；返回值：结果和错误。删除清单会删除其中任务。
func (s *Service) listMutation(tx *gorm.DB, owner uint64, op string, in Input) (any, error) {
	row := domain.List{OwnerID: owner, Color: "#409EFF", Icon: "List"}
	if op != "task_list.create" {
		// 读取满足条件的目标记录。
		var err error
		row, err = repository.ReadList(tx, owner, in.ID)
		if err != nil {
			return nil, err
		}
	}
	if op == "task_list.delete" {
		// 删除清单及任务，保持当前事务完整性。
		return nil, repository.DeleteList(tx, owner, row.ID)
	}
	// 通过白名单解析实际提交的更新字段。
	fields, err := patch(in.Changes, listFields, &row)
	if err != nil {
		return nil, err
	}
	// 检查任务清单约束。
	if err = validateList(row); err != nil {
		return nil, err
	}
	if op == "task_list.create" {
		// 保存新建的业务记录。
		err = repository.CreateList(tx, &row)
	} else {
		// 仅写入本次经过校验的变更字段。
		err = repository.UpdateList(tx, owner, row.ID, fields)
	}
	return row, err
}
