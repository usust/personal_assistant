// 文件职责：封装记账模块读取记录的持久化操作，不执行业务校验。
package repository

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// ReadAccounts 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按sort_order, id排序。
func ReadAccounts(tx *gorm.DB, owner uint64) ([]domain.Account, error) {
	rows := []domain.Account{}
	q := tx.Where("owner_id = ?", owner).Order("sort_order, id")
	q = q.Where("archived = ?", false)
	err := q.Find(&rows).Error
	return rows, err
}

// ReadCategories 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按type, id排序。
func ReadCategories(tx *gorm.DB, owner uint64) ([]domain.Category, error) {
	rows := []domain.Category{}
	q := tx.Where("owner_id = ?", owner).Order("type, id")
	err := q.Find(&rows).Error
	return rows, err
}

// ReadEvents 查询当前用户记录；参数：tx 为数据库或事务，owner 为可信用户 ID；返回值：非 nil 记录集合及数据库错误；按id DESC排序。
func ReadEvents(tx *gorm.DB, owner uint64) ([]domain.Event, error) {
	rows := []domain.Event{}
	q := tx.Where("owner_id = ?", owner).Order("id DESC")
	q = q.Limit(100)
	err := q.Find(&rows).Error
	return rows, err
}

// ReadAccount 查询账户；参数：tx 为事务，owner 为可信归属，id 为目标 ID，active 表示排除归档；返回值：账户及数据库错误，不计算展示字段。
func ReadAccount(tx *gorm.DB, owner, id uint64, active bool) (domain.Account, error) {
	var row domain.Account
	q := tx.Where("owner_id = ? AND id = ?", owner, id)
	if active {
		q = q.Where("archived = ?", false)
	}
	err := q.First(&row).Error
	return row, err
}

// ReadTransaction 读取单条用户记录；参数：tx 为数据库或事务，owner 为可信归属，id 为目标 ID；返回值：记录和原始数据库错误；其他用户记录不可读。
func ReadTransaction(tx *gorm.DB, owner, id uint64) (domain.Transaction, error) {
	var row domain.Transaction
	err := tx.Where("owner_id = ? AND id = ?", owner, id).First(&row).Error
	return row, err
}

// ReadPreset 读取单条用户记录；参数：tx 为数据库或事务，owner 为可信归属，id 为目标 ID；返回值：记录和原始数据库错误；其他用户记录不可读。
func ReadPreset(tx *gorm.DB, owner, id uint64) (domain.Preset, error) {
	var row domain.Preset
	err := tx.Where("owner_id = ? AND id = ?", owner, id).First(&row).Error
	return row, err
}

// ReadCategory 读取单条用户记录；参数：tx 为数据库或事务，owner 为可信归属，id 为目标 ID；返回值：记录和原始数据库错误；其他用户记录不可读。
func ReadCategory(tx *gorm.DB, owner, id uint64) (domain.Category, error) {
	var row domain.Category
	err := tx.Where("owner_id = ? AND id = ?", owner, id).First(&row).Error
	return row, err
}

// FindTransaction 读取用户流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 目标流水主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindTransaction(db *gorm.DB, owner uint64, id uint64, row *domain.Transaction) error {
	return db.Where("owner_id = ? AND id = ?", owner, id).First(row).Error
}

// FindRequestTransaction 读取幂等流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，key 为 幂等请求标识，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindRequestTransaction(db *gorm.DB, owner uint64, key string, row *domain.Transaction) error {
	return db.Where("owner_id = ? AND request_id = ?", owner, key).First(row).Error
}

// FindCategoryByName 按名称读取分类；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，name 为 分类名称，kind 为 收支类型，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindCategoryByName(db *gorm.DB, owner uint64, name string, kind string, row *domain.Category) error {
	return db.Where("owner_id = ? AND name = ? AND type = ?", owner, name, kind).First(row).Error
}

// CountCategoryByName 统计同名同类型分类；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，name 为 分类名称，kind 为 收支类型，count 为 非 nil 计数结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func CountCategoryByName(db *gorm.DB, owner uint64, name string, kind string, count *int64) error {
	return db.Model(&domain.Category{}).Where("owner_id = ? AND name = ? AND type = ?", owner, name, kind).Count(count).Error
}

// ReadRefunds 读取关联流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 原流水主键，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadRefunds(db *gorm.DB, owner uint64, parent uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND refund_parent_id = ? AND status = ?", owner, parent, "posted").Find(rows).Error
}

// ReadInstallmentChildren 读取关联流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 主账单主键，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadInstallmentChildren(db *gorm.DB, owner uint64, parent uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND installment_parent_id = ?", owner, parent).Find(rows).Error
}

// CountRefunds 统计有效退款；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 原流水主键，count 为 非 nil 计数指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func CountRefunds(db *gorm.DB, owner uint64, parent uint64, count *int64) error {
	return db.Model(&domain.Transaction{}).Where("owner_id = ? AND refund_parent_id = ? AND status = ?", owner, parent, "posted").Count(count).Error
}

// FindRebate 读取关联优惠流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 优惠主流水主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindRebate(db *gorm.DB, owner uint64, parent uint64, row *domain.Transaction) error {
	return db.Where("owner_id = ? AND rebate_parent_id = ?", owner, parent).First(row).Error
}

// FindPostedTransaction 读取已入账流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 目标流水主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindPostedTransaction(db *gorm.DB, owner uint64, id uint64, row *domain.Transaction) error {
	return db.Where("owner_id = ? AND id = ? AND status = ?", owner, id, "posted").First(row).Error
}

// FindVisibleTransaction 读取未删除流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 目标流水主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindVisibleTransaction(db *gorm.DB, owner uint64, id uint64, row *domain.Transaction) error {
	return db.Where("owner_id = ? AND id = ? AND status <> ?", owner, id, "deleted").First(row).Error
}

// FindExpenseCategory 读取支出分类；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 分类主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindExpenseCategory(db *gorm.DB, owner uint64, id uint64, row *domain.Category) error {
	return db.Where("owner_id = ? AND id = ? AND type = ?", owner, id, "expense").First(row).Error
}

// FindPreset 读取用户预设；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，id 为 预设主键，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindPreset(db *gorm.DB, owner uint64, id uint64, row *domain.Preset) error {
	return db.Where("owner_id = ? AND id = ?", owner, id).First(row).Error
}

// FindPresetByKey 读取幂等预设；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，key 为 稳定预设标识，row 为 非 nil 结果指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindPresetByKey(db *gorm.DB, owner uint64, key string, row *domain.Preset) error {
	return db.Where("owner_id = ? AND `key` = ?", owner, key).First(row).Error
}

// ReadPresets 按主键倒序读取预设；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadPresets(db *gorm.DB, owner uint64, rows *[]domain.Preset) error {
	return db.Where("owner_id = ?", owner).Order("id DESC").Find(rows).Error
}

// ReadDuePresets 读取到期启用的周期预设；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，today 为 已验证当地日期，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadDuePresets(db *gorm.DB, owner uint64, today string, rows *[]domain.Preset) error {
	return db.Where("owner_id = ? AND enabled = ? AND frequency <> ? AND next_date <= ?", owner, true, "", today).Find(rows).Error
}

// ReadDueInstallments 读取到期未入账分期；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，today 为 已验证当地日期，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadDueInstallments(db *gorm.DB, owner uint64, today string, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND installment_parent_id IS NOT NULL AND status = ? AND transaction_date <= ?", owner, "pending", today).Order("transaction_date, id").Find(rows).Error
}

// ReadInstallmentParents 读取分期主账单；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadInstallmentParents(db *gorm.DB, owner uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND status = ?", owner, "installment").Find(rows).Error
}

// ReadAllInstallmentChildren 读取全部分期子流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadAllInstallmentChildren(db *gorm.DB, owner uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND installment_parent_id IS NOT NULL", owner).Find(rows).Error
}

// ReadPendingInstallmentChildren 按期次读取待入账子流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 主账单 ID，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadPendingInstallmentChildren(db *gorm.DB, owner uint64, parent uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND installment_parent_id = ? AND status = ?", owner, parent, "pending").Order("installment_period").Find(rows).Error
}

// ReadVisibleInstallmentChildren 读取未删除分期子流水；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，parent 为 主账单 ID，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadVisibleInstallmentChildren(db *gorm.DB, owner uint64, parent uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ? AND installment_parent_id = ? AND status <> ?", owner, parent, "deleted").Order("id").Find(rows).Error
}

// ReadSnapshotCategorys 读取完整同步快照集合，包含归档记录；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadSnapshotCategorys(db *gorm.DB, owner uint64, rows *[]domain.Category) error {
	return db.Where("owner_id = ?", owner).Order("id").Find(rows).Error
}

// ReadSnapshotAccounts 读取完整同步快照集合，包含归档记录；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadSnapshotAccounts(db *gorm.DB, owner uint64, rows *[]domain.Account) error {
	return db.Where("owner_id = ?", owner).Order("id").Find(rows).Error
}

// ReadSnapshotTransactions 读取完整同步快照集合，包含归档记录；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadSnapshotTransactions(db *gorm.DB, owner uint64, rows *[]domain.Transaction) error {
	return db.Where("owner_id = ?", owner).Order("transaction_date DESC, id DESC").Find(rows).Error
}

// FindCategories 读取用户分类目录；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func FindCategories(db *gorm.DB, owner uint64, rows *[]domain.Category) error {
	return db.Where("owner_id = ?", owner).Find(rows).Error
}

// ReadAccountTransactions 读取账户账单流水，不预先过滤业务状态；参数：db 为 已绑定上下文的数据库或事务，owner 为 可信用户归属，account 为 账户主键，includeTarget 为 是否包含转入流水，rows 为 非 nil 结果集合指针；返回值：数据库错误或 nil；沿用调用方事务，输出指针成功时写入结果。
func ReadAccountTransactions(db *gorm.DB, owner uint64, account uint64, includeTarget bool, rows *[]domain.Transaction) error {
	return accountTransactions(db, owner, account, includeTarget).Find(rows).Error
}

// accountTransactions 构建固定账户查询；参数：db 为事务，owner 为可信归属，account 为账户主键，includeTarget 表示包含转入；返回值：带归属条件的查询，无立即 SQL 副作用。
func accountTransactions(db *gorm.DB, owner, account uint64, includeTarget bool) *gorm.DB {
	if includeTarget {
		return db.Where("owner_id = ? AND (account_id = ? OR target_account_id = ?)", owner, account, account)
	}
	return db.Where("owner_id = ? AND account_id = ?", owner, account)
}

// ReadTransactionsByIDs 批量读取归属流水；参数：db 为事务，owner 为归属，ids 为服务计算的主键集合，rows 为非 nil 集合指针；返回值：数据库错误或 nil；空集合不查询。
func ReadTransactionsByIDs(db *gorm.DB, owner uint64, ids []uint64, rows *[]domain.Transaction) error {
	if len(ids) == 0 {
		return nil
	}
	return db.Where("owner_id = ? AND id IN ?", owner, ids).Find(rows).Error
}

// ReadActiveAccounts 按 ID 读取未归档账户；参数：db 为事务，owner 为归属，rows 为非 nil 集合指针；返回值：数据库错误或 nil，无写入。
func ReadActiveAccounts(db *gorm.DB, owner uint64, rows *[]domain.Account) error {
	return db.Where("owner_id = ? AND archived = ?", owner, false).Order("id").Find(rows).Error
}

// ReadInstallmentBills 查询分期主账单；参数：db 为事务，owner 为归属，accountID 为账户筛选且 0 表示全部，rows 为非 nil 集合指针；返回值：数据库错误或 nil，按 ID 倒序。
func ReadInstallmentBills(db *gorm.DB, owner, accountID uint64, rows *[]domain.Transaction) error {
	q := db.Where("owner_id = ? AND status = ?", owner, "installment")
	if accountID != 0 {
		q = q.Where("account_id = ?", accountID)
	}
	return q.Order("id DESC").Find(rows).Error
}

// ReadRecurringOwners 查询需扫描周期预设的用户；参数：db 为绑定上下文数据库，owners 为非 nil ID 集合指针；返回值：数据库错误或 nil；仅供服务端定时任务使用，不作为 HTTP 全局查询。
func ReadRecurringOwners(db *gorm.DB, owners *[]uint64) error {
	return db.Model(&domain.Preset{}).Distinct("owner_id").Where("enabled = ? AND frequency <> ?", true, "").Pluck("owner_id", owners).Error
}

// ReadDueInstallmentOwners 查询存在到期分期的用户；参数：db 为绑定上下文数据库，today 为服务端日期，owners 为非 nil ID 集合指针；返回值：数据库错误或 nil；仅供定时任务扫描。
func ReadDueInstallmentOwners(db *gorm.DB, today string, owners *[]uint64) error {
	return db.Model(&domain.Transaction{}).Distinct("owner_id").Where("installment_parent_id IS NOT NULL AND status = ? AND transaction_date <= ?", "pending", today).Pluck("owner_id", owners).Error
}
