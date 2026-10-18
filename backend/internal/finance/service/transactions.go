// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// validateReferences 校验账户和分类归属及状态；参数：db 为事务，owner 为身份，in 为已通过结构校验的流水，previousCategoryID 可省略或仅传一个从原记录读取的分类 ID，仅该原 ID 允许沿用墓碑；返回值：权限、状态或数据库错误，无写入。
func validateReferences(db *gorm.DB, owner uint64, in domain.TransactionInput, previousCategoryID ...*uint64) error {
	// 按所属用户读取账户并检查可用状态。
	if _, e := account(db, owner, in.AccountID, true); e != nil {
		return e
	}
	if in.TargetAccountID != nil {
		// 按所属用户读取账户并检查可用状态。
		if _, e := account(db, owner, *in.TargetAccountID, true); e != nil {
			return e
		}
	}
	if in.RebateAccountID != nil {
		// 按所属用户读取账户并检查可用状态。
		if _, e := account(db, owner, *in.RebateAccountID, true); e != nil {
			return e
		}
	}
	return validateCategoryReference(db, owner, in.CategoryID, in.Type, previousCategoryID...)
}

// validateCategoryReference 校验分类引用；参数：db 为事务，owner 为可信归属，id 为可空分类，kind 为收支类型，previousID 可省略或仅传一个来自原记录的 ID；返回值：归属、类型、删除状态或数据库错误，无写入；仅沿用原 ID 时允许墓碑。
func validateCategoryReference(db *gorm.DB, owner uint64, id *uint64, kind string, previousID ...*uint64) error {
	if id == nil {
		return nil
	}
	// 历史查询不全局过滤墓碑，此处针对新引用执行状态约束。
	category, err := repository.ReadCategory(db, owner, *id)
	if err != nil {
		return missing(err)
	}
	if category.Type != kind {
		return Invalid("分类与收支类型不匹配")
	}
	retained := len(previousID) == 1 && previousID[0] != nil && *previousID[0] == *id
	if category.Deleted && !retained {
		return Invalid("分类已删除，不能用于新引用")
	}
	return nil
}

// apply 原子调整流水关联余额，一次性计入分期仅调整尚未预记的利息；参数：db 为事务，owner 为身份，row 为有效流水，direction 为 1 入账或 -1 冲销；返回值：溢出/数据库错误，调用者必须回滚事务。
func apply(db *gorm.DB, owner uint64, row domain.Transaction, direction domain.Money) error {
	amount := row.Amount
	// 已预记本金不能在每期确认时重复扣减；通过原计划读取精确本金，禁止客户端指定抵扣额。
	if row.InstallmentParentID != nil {
		var parent domain.Transaction
		// 读取满足条件的目标记录。
		var err error
		parent, err = repository.ReadTransaction(db, owner, *row.InstallmentParentID)
		if err != nil {
			// 将数据库查询失败转换为业务错误。
			return missing(err)
		}
		var plan domain.InstallmentPlan
		// 解析已保存的计划，供后续校验与处理。
		if err := json.Unmarshal([]byte(parent.InstallmentJSON), &plan); err != nil {
			return err
		}
		if plan.DebtMode == "upfront" {
			found := false
			for _, period := range plan.Rows {
				if period.Period == row.InstallmentPeriod {
					amount -= period.Principal
					found = true
					break
				}
			}
			if !found || amount < 0 {
				// 拒绝本次操作：分期本金与账单不匹配。
				return Invalid("分期本金与账单不匹配")
			}
		}
	}
	delta := amount * direction
	if row.Type != "income" {
		delta = -delta
	}
	// 手续费从转出账户额外扣除，冲销使用相同方向一并退回。
	changes := map[uint64]domain.Money{row.AccountID: delta - row.Fee*direction}
	if row.TargetAccountID != nil {
		changes[*row.TargetAccountID] = row.Amount * direction
	}
	for id, change := range changes {
		// 按所属用户读取账户并检查可用状态。
		a, e := account(db, owner, id, false)
		if e != nil {
			return e
		}
		next := a.Balance + change
		if next > maxMoney || next < -maxMoney {
			// 拒绝本次操作：账户余额超出上限。
			return Invalid("账户余额超出上限")
		}
		// 用户锁确保余额读写串行；冲销只更新历史余额，不能让已删除账户重新出现。
		if e = repository.UpdateAccount(db, owner, id, map[string]any{"balance": next}); e != nil {
			return e
		}
		// 保存新建的业务记录。
		if e = repository.CreateSnapshot(db, &domain.Snapshot{OwnerID: owner, AccountID: id, Balance: next}); e != nil {
			return e
		}
	}
	return nil
}

// transition 确认草稿或作废流水，关联优惠随转账整体冲销、待到账优惠确认日为实际入账日；参数：db 为事务，owner 为身份，op 为固定动作，id 为目标；返回值：流水或状态错误，重复相同动作不重复改余额，确认可沿用原已删除分类以保持历史分期入账，分期主账单及分期子账单作废均拒绝。
func (s *Service) transition(db *gorm.DB, owner uint64, op string, id uint64) (domain.Transaction, error) {
	var row domain.Transaction
	// 读取满足条件的目标记录。
	var e error
	row, e = repository.ReadTransaction(db, owner, id)
	if e != nil {
		// 将数据库查询失败转换为业务错误。
		return row, missing(e)
	}
	if row.Status == "deleted" {
		return row, ErrConflict
	}
	// 分期主账单不再直接记账；期次只能确认，避免单独作废破坏本息总额。
	if row.Status == "installment" || (row.InstallmentParentID != nil && op == "finance.transaction.void") {
		// 拒绝本次操作：分期账单不支持单独作废。
		return row, Invalid("分期账单不支持单独作废")
	}
	if row.RebateParentID != nil && op == "finance.transaction.void" {
		// 拒绝本次操作：请作废原转账以一并撤销优惠。
		return row, Invalid("请作废原转账以一并撤销优惠")
	}
	status := "voided"
	if op == "finance.transaction.confirm" {
		status = "posted"
		if row.Status == "posted" {
			return row, nil
		}
		if row.Status != "pending" {
			return row, ErrConflict
		}
		in := domain.TransactionInput{RebateAccountID: row.RebateAccountID, AccountID: row.AccountID, TargetAccountID: row.TargetAccountID, CategoryID: row.CategoryID, Type: row.Type}
		// 确认交易引用的账户与分类属于当前用户。
		if e := validateReferences(db, owner, in, row.CategoryID); e != nil {
			return row, e
		}
		if row.RebateParentID != nil {
			var parent domain.Transaction
			// 读取满足条件的目标记录。
			if e := repository.FindPostedTransaction(db, owner, *row.RebateParentID, &parent); e != nil {
				// 将数据库查询失败转换为业务错误。
				return row, missing(e)
			}
			// 将业务时间转换为约定的存储或展示格式。
			row.TransactionDate = time.Now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
		}
		// 将流水影响计入或冲回账户余额。
		if e := apply(db, owner, row, 1); e != nil {
			return row, e
		}
		// 为主流水建立关联返利。
		if e := createRebate(db, owner, row); e != nil {
			return row, e
		}
	} else {
		if row.Status == "voided" {
			return row, nil
		}
		// 原支出作废时先撤销关联退款，防止原支出与退款同时增加余额。
		var refunds []domain.Transaction
		// 读取符合业务条件的记录集合。
		if e := repository.ReadRefunds(db, owner, row.ID, &refunds); e != nil {
			return row, e
		}
		for _, refund := range refunds {
			// 执行流水状态迁移并协调余额变化。
			if _, e := s.transition(db, owner, op, refund.ID); e != nil {
				return row, e
			}
		}
		// 按入账相反顺序撤销优惠和转账；任何一步失败均由外层事务回滚。
		if e := voidRebate(db, owner, row.ID); e != nil {
			return row, e
		}
		if row.Status == "posted" {
			// 将流水影响计入或冲回账户余额。
			if e := apply(db, owner, row, -1); e != nil {
				return row, e
			}
		}
	}
	// 仅写入本次经过校验的变更字段。
	if e := repository.UpdateTransaction(db, owner, id, map[string]any{"status": status, "transaction_date": row.TransactionDate}); e != nil {
		return row, e
	}
	// 读取满足条件的目标记录。
	e = repository.FindTransaction(db, owner, id, &row)
	return row, e
}
