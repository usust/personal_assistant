// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"fmt"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// deletedCategoryConflict 提供墓碑冲突提示；参数：无；返回值：包装 ErrConflict 的错误，供 HTTP 和同步统一识别，无副作用。
func deletedCategoryConflict() error {
	return fmt.Errorf("%w: 分类已删除，不能编辑", ErrConflict)
}

// deleteCategory 软删除当前用户的分类并释放活动名称；参数：db 为持用户锁的事务，owner 为可信身份，id 为目标分类；返回值：含删除状态和内部版本的分类或归属、数据库错误；重复删除幂等并补齐旧墓碑版本，保留历史引用和展示资料，调用方负责事务审计。
func (s *Service) deleteCategory(db *gorm.DB, owner, id uint64) (domain.Category, error) {
	// 先限定归属，其他用户与不存在的分类一律不可删除。
	row, err := repository.ReadCategory(db, owner, id)
	if err != nil {
		return row, missing(err)
	}
	if row.Deleted && row.NameVersion == row.ID {
		return row, nil
	}
	// 两列通过同一个 UPDATE 原子写入；墓碑使用自身 ID，允许多次同名重建并兼容旧墓碑补齐。
	if err := repository.UpdateCategory(db, owner, id, map[string]any{"deleted": true, "name_version": row.ID}); err != nil {
		return row, err
	}
	row.Deleted = true
	row.NameVersion = row.ID
	return row, nil
}

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
