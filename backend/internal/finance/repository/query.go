// 文件职责：封装记账统计查询，业务校验与结果计算由服务层处理。
package repository

import (
	"strings"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// SumRefunds 汇总已入账退款金额；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 原流水主键，sum 为 非 nil 金额结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func SumRefunds(db *gorm.DB, owner uint64, parent uint64, sum *domain.Money) error {
	return db.Model(&domain.Transaction{}).Select("COALESCE(SUM(amount), 0)").Where("owner_id = ? AND refund_parent_id = ? AND status = ?", owner, parent, "posted").Scan(sum).Error
}

// TransactionFilter 仅表示服务层已验证的查询条件，不接受客户端 SQL 或任意列名。
type TransactionFilter struct {
	StartDate, EndDate, Type, Status, Keyword string
	AccountID, CategoryID                     uint64
	Min, Max                                  domain.Money
	HasMin, HasMax                            bool
	Limit, Offset                             int
}

// QueryTransactions 读取经过白名单筛选的流水；参数：db 为事务，owner 为可信归属，f 为已校验筛选和分页，rows 为非 nil 集合指针；返回值：数据库错误或 nil；分页前排除已删除、未入账分期及默认隐藏的分期主账单。
func QueryTransactions(db *gorm.DB, owner uint64, f TransactionFilter, rows *[]domain.Transaction) error {
	q := db.Where("owner_id = ? AND status <> ?", owner, "deleted").Where("(installment_parent_id IS NULL OR status <> ?)", "pending")
	if f.StartDate != "" {
		q = q.Where("transaction_date >= ?", f.StartDate)
	}
	if f.EndDate != "" {
		q = q.Where("transaction_date <= ?", f.EndDate)
	}
	if f.Type != "" {
		q = q.Where("type = ?", f.Type)
	}
	if f.Status != "" {
		q = q.Where("status = ?", f.Status)
	} else {
		q = q.Where("status <> ?", "installment")
	}
	if f.AccountID != 0 {
		q = q.Where("(account_id = ? OR target_account_id = ?)", f.AccountID, f.AccountID)
	}
	if f.CategoryID != 0 {
		q = q.Where("category_id = ?", f.CategoryID)
	}
	if f.HasMin {
		q = q.Where("amount >= ?", f.Min)
	}
	if f.HasMax {
		q = q.Where("amount <= ?", f.Max)
	}
	// 转义 LIKE 通配符，关键词只作为绑定参数，不解释为数据库模式。
	if f.Keyword != "" {
		pattern := "%" + strings.NewReplacer("!", "!!", "%", "!%", "_", "!_").Replace(f.Keyword) + "%"
		q = q.Where("(counterparty LIKE ? ESCAPE '!' OR description LIKE ? ESCAPE '!')", pattern, pattern)
	}
	return q.Order("transaction_date DESC, transaction_time DESC, id DESC").Limit(f.Limit).Offset(f.Offset).Find(rows).Error
}

// SumTransactionSummary 查询区间收支原始汇总；参数：db 为事务，owner 为可信归属，start/end 为已校验日期且包含边界，result 为非 nil 汇总指针；返回值：数据库错误或 nil；仅统计已入账流水，手续费计入支出。
func SumTransactionSummary(db *gorm.DB, owner uint64, start, end string, result *domain.TransactionSummary) error {
	return db.Model(&domain.Transaction{}).Select("COALESCE(SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END), 0) AS income, COALESCE(SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END), 0) + COALESCE(SUM(fee), 0) AS expense").Where("owner_id = ? AND status = ? AND transaction_date >= ? AND transaction_date <= ?", owner, "posted", start, end).Scan(result).Error
}

// SumTypes 按收支类型聚合金额；参数：db 为事务，owner 为归属，start/end 为左闭右开日期，result 为含 Type、Total 字段的非 nil 集合指针；返回值：数据库错误或 nil，无写入。
func SumTypes(db *gorm.DB, owner uint64, start, end string, result any) error {
	return db.Model(&domain.Transaction{}).Select("type, SUM(amount) AS total").Where("owner_id = ? AND status = ? AND transaction_date >= ? AND transaction_date < ? AND type IN ?", owner, "posted", start, end, []string{"income", "expense"}).Group("type").Scan(result).Error
}

// SumFees 汇总手续费；参数：db 为事务，owner 为归属，start/end 为左闭右开日期，result 为非 nil 金额指针；返回值：数据库错误或 nil，无写入。
func SumFees(db *gorm.DB, owner uint64, start, end string, result *domain.Money) error {
	return db.Model(&domain.Transaction{}).Select("COALESCE(SUM(fee), 0)").Where("owner_id = ? AND status = ? AND transaction_date >= ? AND transaction_date < ?", owner, "posted", start, end).Scan(result).Error
}

// SumCategories 按分类聚合已入账支出；参数：db 为事务，owner 为归属，start/end 为左闭右开日期，result 为含 CategoryID、Total 字段的非 nil 集合指针；返回值：数据库错误或 nil，金额倒序且分类 ID 稳定排序。
func SumCategories(db *gorm.DB, owner uint64, start, end string, result any) error {
	return db.Model(&domain.Transaction{}).Select("category_id, SUM(amount) AS total").Where("owner_id = ? AND status = ? AND type = ? AND transaction_date >= ? AND transaction_date < ?", owner, "posted", "expense", start, end).Group("category_id").Order("total DESC, category_id").Scan(result).Error
}

// CountPendingAccountTransactions 统计账户待确认关联；参数：db 为事务，owner 为归属，id 为账户，count 为非 nil 结果指针；返回值：数据库错误或 nil，覆盖转出、转入和优惠账户。
func CountPendingAccountTransactions(db *gorm.DB, owner, id uint64, count *int64) error {
	return db.Model(&domain.Transaction{}).Where("owner_id = ? AND status = ? AND (account_id = ? OR target_account_id = ? OR rebate_account_id = ?)", owner, "pending", id, id, id).Count(count).Error
}

// AccountImpact 查询账户归档影响；参数：db 为事务，owner 为可信归属，id 为账户，count/snapshots/pending 为非 nil 结果指针；返回值：首个数据库错误或 nil，不执行归档。
func AccountImpact(db *gorm.DB, owner, id uint64, count, snapshots, pending *int64) error {
	q := db.Model(&domain.Transaction{}).Where("owner_id = ? AND (account_id = ? OR target_account_id = ? OR rebate_account_id = ?)", owner, id, id, id)
	if err := q.Count(count).Error; err != nil {
		return err
	}
	if err := db.Model(&domain.Snapshot{}).Where("owner_id = ? AND account_id = ?", owner, id).Count(snapshots).Error; err != nil {
		return err
	}
	return q.Where("status = ?", "pending").Count(pending).Error
}
