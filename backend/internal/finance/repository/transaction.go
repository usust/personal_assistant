// 文件职责：管理用户行锁和事务边界，保证关联变更原子提交。
package repository

import (
	"context"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"personal_assistant_server/internal/user/model"
)

// Transaction 在请求生命周期内运行事务；参数：ctx 控制取消，db 为数据库，run 为事务回调；返回值：回调或数据库错误，错误时整体回滚；run 不得提交独立事务。
func Transaction(ctx context.Context, db *gorm.DB, run func(*gorm.DB) error) error {
	return db.WithContext(ctx).Transaction(run)
}

// LockOwner 锁定可信用户行；参数：tx 为当前事务，owner 为非零用户 ID；返回值：查询错误或 nil，锁在事务结束时释放。
func LockOwner(tx *gorm.DB, owner uint64) error {
	var row model.User
	return tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&row, owner).Error
}
