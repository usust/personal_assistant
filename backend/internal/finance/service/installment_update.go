// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"fmt"
	"reflect"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// updateInstallment 合并并保存整套分期设置；参数：db 为持有用户锁的事务，owner 为身份，bill 为分期主账单，old 为原规则，changes 为实际提交的字段；返回值：新计划或错误，所有期次与余额变更由外层原子提交。
func (s *Service) updateInstallment(db *gorm.DB, owner uint64, bill domain.Transaction, old domain.InstallmentPlan, changes json.RawMessage) (domain.InstallmentPlan, error) {
	var submitted map[string]json.RawMessage
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err := Decode(changes, &submitted); err != nil {
		return old, err
	}
	if len(submitted) == 0 {
		// 拒绝本次操作：至少提交一个字段。
		return old, Invalid("至少提交一个字段")
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, err := json.Marshal(old.InstallmentTerms)
	if err != nil {
		return old, err
	}
	var merged map[string]json.RawMessage
	// 解析业务数据，供后续校验与处理。
	if err = json.Unmarshal(encoded, &merged); err != nil {
		return old, err
	}
	for key, value := range submitted {
		switch key {
		case "name", "periods", "firstDate", "startPeriod", "restoredCredit", "debtMode", "interest", "interestMode", "interestCreditMode", "rounding", "remainder", "description", "categoryId":
			if string(value) == "null" && key != "categoryId" {
				// 拒绝本次操作：分期字段不能为空。
				return old, Invalid("分期字段不能为空")
			}
			merged[key] = value
		default:
			// 拒绝本次操作：不支持的分期字段。
			return old, Invalid("不支持的分期字段")
		}
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, err = json.Marshal(merged)
	if err != nil {
		return old, err
	}
	var terms domain.InstallmentTerms
	// 解析分期或贷款条件，供后续校验与处理。
	if err = json.Unmarshal(encoded, &terms); err != nil {
		// 拒绝本次操作：分期字段格式无效。
		return old, Invalid("分期字段格式无效")
	}
	// 按本金和分期条件计算计划。
	next, err := calculateInstallment(bill.Amount, terms)
	if err != nil {
		return old, err
	}
	fields := map[string]any{}
	childFields := map[string]any{}
	if _, ok := submitted["categoryId"]; ok {
		id := terms.CategoryID
		if id != nil && *id == 0 {
			id = nil
		}
		if id != nil {
			var category domain.Category
			// 读取满足条件的目标记录。
			if err = repository.FindExpenseCategory(db, owner, *id, &category); err != nil {
				// 将数据库查询失败转换为业务错误。
				return old, missing(err)
			}
		}
		fields["category_id"] = id
		childFields["category_id"] = id
		bill.CategoryID = id
	}
	if _, ok := submitted["description"]; ok {
		// 检查文本长度与必填约束。
		if terms.Description == nil || !validText(*terms.Description, 2000, false) {
			// 拒绝本次操作：备注无效。
			return old, Invalid("备注无效")
		}
		fields["description"] = *terms.Description
		childFields["description"] = *terms.Description
		bill.Description = *terms.Description
	}
	// 仅资料变化时不重排历史、不重置提前完结状态；金额规则变化才进行完整对账。
	before, after := old.InstallmentTerms, terms
	before.Name = after.Name
	before.CategoryID = after.CategoryID
	before.Description = after.Description
	// 比较业务字段是否发生实际变化。
	if reflect.DeepEqual(before, after) {
		old.InstallmentTerms = terms
		// 序列化业务数据，供存储或响应使用。
		encoded, err = json.Marshal(old)
		if err != nil {
			return old, err
		}
		fields["installment_json"] = string(encoded)
		// 仅写入本次经过校验的变更字段。
		if err = repository.UpdateTransaction(db, owner, bill.ID, fields); err != nil {
			return old, err
		}
		if len(childFields) > 0 {
			// 仅写入本次经过校验的变更字段。
			if err = repository.UpdatePendingInstallmentChildren(db, owner, bill.ID, childFields); err != nil {
				return old, err
			}
		}
	} else {
		// 同步分期主流水、子流水和计划变更。
		if err = s.reconcileInstallment(db, owner, bill, old, &next, fields, childFields); err != nil {
			return old, err
		}
	}
	// 补记已到期的分期流水。
	if err = s.postDueInstallments(db, owner, s.now()); err != nil {
		return old, err
	}
	// 执行分期业务操作并维护计划。
	return installment(db, owner, "finance.installment.plan", Input{ID: bill.ID})
}

// reconcileInstallment 重算各期并按新旧净差调整余额；参数：db 为用户锁事务，owner 为身份，bill 为主账单，old 为原计划，next 为待写计划，fields/childFields 为已校验的资料 map；返回值：错误或 nil，失败必须回滚，保留单期删除及退款关联。
func (s *Service) reconcileInstallment(db *gorm.DB, owner uint64, bill domain.Transaction, old domain.InstallmentPlan, next *domain.InstallmentPlan, fields, childFields map[string]any) error {
	// 按所属用户读取账户并检查可用状态。
	if _, err := account(db, owner, bill.AccountID, true); err != nil {
		return err
	}
	var children []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadInstallmentChildren(db, owner, bill.ID, &children); err != nil {
		return err
	}
	byPeriod := map[int]domain.Transaction{}
	oldRows := map[int]domain.InstallmentRow{}
	for _, row := range old.Rows {
		oldRows[row.Period] = row
	}
	var oldBooked, newBooked domain.Money
	for _, child := range children {
		byPeriod[child.InstallmentPeriod] = child
		if child.Status == "posted" {
			oldBooked += child.Amount + child.Fee
		} else if child.Status == "pending" && old.DebtMode == "upfront" {
			oldBooked += oldRows[child.InstallmentPeriod].Principal
		}
	}
	// 将业务时间转换为约定的存储或展示格式。
	today := s.now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
	retained := map[int]bool{}
	for i := range next.Rows {
		row := &next.Rows[i]
		child, exists := byPeriod[row.Period]
		retained[row.Period] = true
		// 用户单独删除的期次不复活；仅因上次缩短生成范围而移除的期次可以重新生成。
		if exists && child.Status == "deleted" && !child.InstallmentEditRemoved {
			row.Status = "deleted"
			row.TransactionID = child.ID
			continue
		}
		row.Status = "pending"
		if row.Date <= today {
			row.Status = "posted"
		}
		// 未修改首期日期时保留已入账期的实际日期，包括用户提前完结的日期。
		if exists && child.Status == "posted" && old.FirstDate == next.FirstDate {
			row.Status = "posted"
			row.Date = child.TransactionDate
		}
		if exists {
			var refunds []domain.Transaction
			// 读取符合业务条件的记录集合。
			if err := repository.ReadRefunds(db, owner, child.ID, &refunds); err != nil {
				return err
			}
			var refunded domain.Money
			for _, refund := range refunds {
				refunded -= refund.Amount
				if row.Status != "posted" || row.Date > refund.TransactionDate {
					// 拒绝本次操作：调整后的入账日期不能晚于已有退款日期。
					return Invalid("调整后的入账日期不能晚于已有退款日期")
				}
			}
			if refunded > row.Amount {
				// 拒绝本次操作：调整后的单期金额不能低于已退款金额。
				return Invalid("调整后的单期金额不能低于已退款金额")
			}
		} else {
			// 生成当前操作需要的展示或协议文本。
			child = domain.Transaction{OwnerID: owner, RequestID: fmt.Sprintf("installment_%d_%d", bill.ID, row.Period), AccountID: bill.AccountID, Type: "expense", CategoryID: bill.CategoryID, Counterparty: bill.Counterparty, Description: bill.Description, Source: "http", InstallmentParentID: &bill.ID, InstallmentPeriod: row.Period}
		}
		update := map[string]any{"amount": row.Amount, "transaction_date": row.Date, "status": row.Status, "installment_edit_removed": false}
		// 已单独修改的历史资料保留；计划资料仅传播到原本未入账的期次。
		if child.Status != "posted" {
			for key, value := range childFields {
				update[key] = value
			}
		}
		if exists {
			// 仅写入本次经过校验的变更字段。
			if err := repository.UpdateTransaction(db, owner, child.ID, update); err != nil {
				return err
			}
		} else {
			child.Amount = row.Amount
			child.TransactionDate = row.Date
			child.Status = row.Status
			// 保存新建的业务记录。
			if err := repository.CreateTransaction(db, &child); err != nil {
				return err
			}
		}
		row.TransactionID = child.ID
		if row.Status == "posted" {
			newBooked += row.Amount + child.Fee
		} else if next.DebtMode == "upfront" {
			newBooked += row.Principal
		}
	}
	for _, child := range children {
		if retained[child.InstallmentPeriod] || child.Status == "deleted" {
			continue
		}
		var count int64
		// 统计符合条件的业务记录。
		if err := repository.CountRefunds(db, owner, child.ID, &count); err != nil {
			return err
		}
		if count > 0 {
			// 拒绝本次操作：已有退款的期次不能移出分期范围。
			return Invalid("已有退款的期次不能移出分期范围")
		}
		// 仅写入本次经过校验的变更字段。
		if err := repository.UpdateTransaction(db, owner, child.ID, map[string]any{"status": "deleted", "installment_edit_removed": true}); err != nil {
			return err
		}
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, err := json.Marshal(next)
	if err != nil {
		return err
	}
	fields["installment_json"] = string(encoded)
	// 仅写入本次经过校验的变更字段。
	if err = repository.UpdateTransaction(db, owner, bill.ID, fields); err != nil {
		return err
	}
	// 退款本身不变，只调整分期本息和费用的新旧净额，避免整笔冲回造成中间余额溢出。
	if delta := newBooked - oldBooked; delta != 0 {
		// 将流水影响计入或冲回账户余额。
		return apply(db, owner, domain.Transaction{AccountID: bill.AccountID, Type: "expense", Amount: delta}, 1)
	}
	return nil
}
