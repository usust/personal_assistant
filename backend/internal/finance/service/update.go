// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"errors"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// updateTransaction 更正流水并原子重算余额；参数：db 为持用户锁的事务，owner 为身份，in 含流水 ID 和部分字段；返回值：更新后的流水或校验/数据库错误；失败必须回滚，白名单 map 保留零值，关联分期及退款子项的财务字段由原业务维护。
func (s *Service) updateTransaction(db *gorm.DB, owner uint64, in Input) (domain.Transaction, error) {
	var row domain.Transaction
	// 读取满足条件的目标记录。
	var e error
	row, e = repository.ReadTransaction(db, owner, in.ID)
	if e != nil {
		// 将数据库查询失败转换为业务错误。
		return row, missing(e)
	}
	if row.Status == "voided" || row.Status == "deleted" {
		return row, ErrConflict
	}
	var body map[string]json.RawMessage
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(in.Changes, &body); e != nil {
		return row, e
	}
	if len(body) == 0 {
		// 拒绝本次操作：至少提交一个字段。
		return row, Invalid("至少提交一个字段")
	}
	columns := map[string]string{"accountId": "account_id", "targetAccountId": "target_account_id", "type": "type", "amount": "amount", "discount": "discount", "fee": "fee", "rebate": "rebate", "rebateAccountId": "rebate_account_id", "rebatePending": "rebate_pending", "categoryId": "category_id", "counterparty": "counterparty", "description": "description", "transactionDate": "transaction_date", "transactionTime": "transaction_time"}
	candidate := domain.TransactionInput{RequestID: "transaction-edit", AccountID: row.AccountID, TargetAccountID: row.TargetAccountID, Type: row.Type, Amount: row.Amount + row.Discount, Discount: row.Discount, Fee: row.Fee, Rebate: row.Rebate, RebateAccountID: row.RebateAccountID, RebatePending: row.RebatePending, CategoryID: row.CategoryID, Counterparty: row.Counterparty, Description: row.Description, TransactionDate: row.TransactionDate, TransactionTime: row.TransactionTime}
	// 序列化业务数据，供存储或响应使用。
	encoded, _ := json.Marshal(candidate)
	var merged map[string]json.RawMessage
	// 解析业务数据，供后续校验与处理。
	if e := json.Unmarshal(encoded, &merged); e != nil {
		return row, e
	}
	financial := false
	for key, value := range body {
		if _, ok := columns[key]; !ok {
			// 拒绝本次操作：不允许更新流水字段: 。
			return row, Invalid("不允许更新流水字段: " + key)
		}
		if string(value) == "null" && key != "categoryId" && key != "targetAccountId" && key != "rebateAccountId" {
			// 拒绝本次操作：流水字段不可为 null。
			return row, Invalid("流水字段不可为 null")
		}
		merged[key] = value
		if key != "categoryId" && key != "counterparty" && key != "description" {
			financial = true
		}
	}
	// 分期计划、退款与返现子项不能脱离原业务改变财务关系；资料更正仍允许。
	if financial && (row.Status == "installment" || row.InstallmentParentID != nil || row.RefundParentID != nil || row.RebateParentID != nil) {
		// 拒绝本次操作：关联分期、退款或优惠流水的金额与账户请在原业务中调整。
		return row, Invalid("关联分期、退款或优惠流水的金额与账户请在原业务中调整")
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, _ = json.Marshal(merged)
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(encoded, &candidate); e != nil {
		return row, e
	}
	if financial {
		// 确认输入满足当前业务约束。
		if e := validateTransactionInput(candidate); e != nil {
			return row, e
		}
		// 确认交易引用的账户与分类属于当前用户。
		if e := validateReferences(db, owner, candidate); e != nil {
			return row, e
		}
	} else {
		// 检查文本长度与必填约束。
		if !validText(candidate.Counterparty, 128, false) || !validText(candidate.Description, 2000, false) {
			// 拒绝本次操作：流水文本无效。
			return row, Invalid("流水文本无效")
		}
		if candidate.CategoryID != nil {
			var category domain.Category
			// 读取满足条件的目标记录。
			var e error
			category, e = repository.ReadCategory(db, owner, *candidate.CategoryID)
			if e != nil {
				// 将数据库查询失败转换为业务错误。
				return row, missing(e)
			}
			if candidate.Type == "transfer" || category.Type != candidate.Type {
				// 拒绝本次操作：分类类型不匹配。
				return row, Invalid("分类类型不匹配")
			}
		}
	}
	next := row
	next.AccountID = candidate.AccountID
	next.TargetAccountID = candidate.TargetAccountID
	next.Type = candidate.Type
	next.Amount = candidate.Amount - candidate.Discount
	next.Discount = candidate.Discount
	next.Fee = candidate.Fee
	next.Rebate = candidate.Rebate
	next.RebateAccountID = candidate.RebateAccountID
	next.RebatePending = candidate.RebatePending
	next.CategoryID = candidate.CategoryID
	next.Counterparty = candidate.Counterparty
	next.Description = candidate.Description
	next.TransactionDate = candidate.TransactionDate
	next.TransactionTime = candidate.TransactionTime
	if next.Rebate > 0 && next.RebateAccountID == nil {
		next.RebateAccountID = &next.AccountID
	}
	// 已退款的原支出允许更正金额和日期，但不能少于累计退款或迁移退款账户。
	if financial {
		var refunds []domain.Transaction
		// 读取符合业务条件的记录集合。
		if e := repository.ReadRefunds(db, owner, row.ID, &refunds); e != nil {
			return row, e
		}
		var refunded domain.Money
		for _, refund := range refunds {
			refunded -= refund.Amount
			if next.Type != "expense" || next.AccountID != row.AccountID || next.TransactionDate > refund.TransactionDate {
				// 拒绝本次操作：已有退款，不能更改收支类型、账户或晚于退款日期。
				return row, Invalid("已有退款，不能更改收支类型、账户或晚于退款日期")
			}
		}
		if next.Amount < refunded {
			// 拒绝本次操作：金额不能小于已退款金额。
			return row, Invalid("金额不能小于已退款金额")
		}
		if row.Status == "posted" {
			// 将流水影响计入或冲回账户余额。
			if e := apply(db, owner, row, -1); e != nil {
				return row, e
			}
			// 将流水影响计入或冲回账户余额。
			if e := apply(db, owner, next, 1); e != nil {
				return row, e
			}
		}
		// 根据流水变更同步关联返利。
		if e := s.updateTransactionRebate(db, owner, row, next, body); e != nil {
			return row, e
		}
	}
	values := map[string]any{"account_id": next.AccountID, "target_account_id": next.TargetAccountID, "type": next.Type, "amount": next.Amount, "discount": next.Discount, "fee": next.Fee, "rebate": next.Rebate, "rebate_account_id": next.RebateAccountID, "rebate_pending": next.RebatePending, "category_id": next.CategoryID, "counterparty": next.Counterparty, "description": next.Description, "transaction_date": next.TransactionDate, "transaction_time": next.TransactionTime}
	fields := map[string]any{}
	for key := range body {
		fields[columns[key]] = values[columns[key]]
	}
	// 优惠改变时实付金额是必要派生更新，返现默认账户只在本次返现相关字段提交时写入。
	if _, ok := body["discount"]; ok {
		fields["amount"] = next.Amount
	}
	if _, ok := body["rebate"]; ok {
		fields["rebate_account_id"] = next.RebateAccountID
	}
	// 仅写入本次经过校验的变更字段。
	if e := repository.UpdateTransaction(db, owner, row.ID, fields); e != nil {
		return row, e
	}
	// 读取满足条件的目标记录。
	e = repository.FindTransaction(db, owner, row.ID, &row)
	return row, e
}

// updateTransactionRebate 同步原转账的返现子流水；参数：db 为事务，owner 为身份，old/next 为修改前后流水，body 为已验证字段；返回值：错误或 nil；保持子项 ID，冲销旧余额后写入新值，未提交到账状态时保留已确认结果。
func (s *Service) updateTransactionRebate(db *gorm.DB, owner uint64, old, next domain.Transaction, body map[string]json.RawMessage) error {
	var child domain.Transaction
	// 读取满足条件的目标记录。
	err := repository.FindRebate(db, owner, old.ID, &child)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		if next.Status == "posted" {
			// 为主流水建立关联返利。
			return createRebate(db, owner, next)
		}
		return nil
	}
	if err != nil {
		return err
	}
	if child.Status == "posted" {
		// 将流水影响计入或冲回账户余额。
		if err = apply(db, owner, child, -1); err != nil {
			return err
		}
	}
	status := child.Status
	if next.Rebate == 0 || next.Status != "posted" {
		status = "deleted"
	} else if _, ok := body["rebatePending"]; ok || status == "deleted" || status == "voided" {
		status = "posted"
		if next.RebatePending {
			status = "pending"
		}
	}
	child.Amount = next.Rebate
	child.TransactionDate = next.TransactionDate
	child.Status = status
	if next.RebateAccountID != nil {
		child.AccountID = *next.RebateAccountID
	}
	// 仅写入本次经过校验的变更字段。
	if err = repository.UpdateTransaction(db, owner, child.ID, map[string]any{"amount": child.Amount, "account_id": child.AccountID, "transaction_date": child.TransactionDate, "status": status}); err != nil {
		return err
	}
	if status == "posted" {
		// 将流水影响计入或冲回账户余额。
		return apply(db, owner, child, 1)
	}
	return nil
}
