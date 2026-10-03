// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// missing 将不存在转换为不泄露归属的业务错误；参数：e 为数据库错误；返回值：原始或不存在错误，无副作用。
func missing(e error) error {
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(e, gorm.ErrRecordNotFound) {
		return ErrNotFound
	}
	return e
}

// account 查询用户自己的账户；参数：db 为事务，owner 和 id 为身份及账户，active 表示拒绝归档；返回值：账户或错误。
func account(db *gorm.DB, owner, id uint64, active bool) (domain.Account, error) {
	a, e := repository.ReadAccount(db, owner, id, active)
	a.AvailableBalance = a.Balance
	// 为账户补充贷款计划展示数据。
	attachLoanPlan(&a)
	// 将数据库查询失败转换为业务错误。
	return a, missing(e)
}
