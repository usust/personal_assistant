// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"fmt"

	"gorm.io/gorm"

	"personal_assistant_server/internal/finance/repository"
)

// archive 查询影响或归档账户；参数：db 为事务，owner 为身份，op 为影响/归档，id 为目标；返回值：关联数量或错误；允许非零余额软删除，待确认流水须先处理；保留全部历史。
func (s *Service) archive(db *gorm.DB, owner uint64, op string, id uint64) (any, error) {
	// 按所属用户读取账户并检查可用状态。
	_, e := account(db, owner, id, true)
	if e != nil {
		return nil, e
	}
	var count, snapshots, pending int64
	// 一次仓储调用读取关联数量；归档是否允许仍由业务规则决定。
	if e = repository.AccountImpact(db, owner, id, &count, &snapshots, &pending); e != nil {
		return nil, e
	}
	if op == "finance.account.archive" {
		if pending > 0 {
			// 为失败补充当前操作的错误上下文。
			return nil, fmt.Errorf("%w: 该账户有 %d 条待确认流水，请先确认或作废后再删除", ErrConflict, pending)
		}
		// 删除仅隐藏账户，不伪造转出流水或清零余额，保留历史账目及转账关联。
		e = repository.UpdateAccount(db, owner, id, map[string]any{"archived": true})
	}
	return map[string]int64{"transactions": count, "snapshots": snapshots, "pending": pending}, e
}
