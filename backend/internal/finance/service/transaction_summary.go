// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// transactionSummary 汇总完整日期范围；参数：db 为用户锁事务，owner 为身份，f 必须提供起止日期，可选账户且不接受其他筛选；返回值：收支结余及按原单归属扣除跨月退款的报销净额，或校验/数据库错误，无写入。
func transactionSummary(db *gorm.DB, owner uint64, f Filter) (domain.TransactionSummary, error) {
	var result domain.TransactionSummary
	// 检查日期是否满足业务格式。
	if !validDate(f.StartDate) || !validDate(f.EndDate) || f.StartDate > f.EndDate || f.CategoryID != 0 || f.Type != "" || f.Status != "" || f.Keyword != "" || f.Limit != 0 || f.Offset != 0 || f.MinAmount != "" || f.MaxAmount != "" {
		// 拒绝本次操作：请提供有效起止日期。
		return result, Invalid("请提供有效起止日期")
	}
	// 只统计真实已入账收支；内部转账本金不算支出，退款负值冲减支出，所有已入账手续费计入支出。
	if err := repository.SumTransactionSummary(db, owner, f.StartDate, f.EndDate, f.AccountID, &result); err != nil {
		return result, err
	}
	result.Balance = result.Income - result.Expense
	// 报销统计独立于现金流：日期与状态归原支出，退款只减少该原单的可报销实付额。
	err := repository.SumReimbursementSummary(db, owner, f.StartDate, f.EndDate, f.AccountID, &result)
	result.ReimbursementTotal = result.ReimbursementPending + result.ReimbursementReceived
	return result, err
}
