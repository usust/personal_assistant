// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// listInstallments 查询用户或指定账户的分期；参数：db 为事务，owner 为身份，accountID 为账户或 0 表示全部；返回值：包含实时状态的摘要或数据库错误，无写入。
func listInstallments(db *gorm.DB, owner, accountID uint64) ([]domain.InstallmentSummary, error) {
	rows := []domain.InstallmentSummary{}
	var bills []domain.Transaction
	// 仓储负责过滤与排序，业务服务继续计算每份计划的实时摘要。
	if err := repository.ReadInstallmentBills(db, owner, accountID, &bills); err != nil {
		return nil, err
	}
	for _, bill := range bills {
		// 执行分期业务操作并维护计划。
		plan, err := installment(db, owner, "finance.installment.plan", Input{ID: bill.ID})
		if err != nil {
			return nil, err
		}
		summary := domain.InstallmentSummary{Bill: bill, Plan: plan}
		for _, row := range plan.Rows {
			if row.Status != "pending" {
				continue
			}
			summary.PendingAmount += row.Amount
			summary.PendingInterest += row.Interest
			if summary.NextDate == "" || row.Date < summary.NextDate {
				summary.NextDate = row.Date
			}
		}
		rows = append(rows, summary)
	}
	return rows, nil
}

// manageInstallment 管理已保存计划；参数：db 为用户锁事务，owner 为身份，op 为白名单操作，in 含计划 ID 和更新字段；返回值：最新计划或错误，失败回滚所有余额及期次变更。
func (s *Service) manageInstallment(db *gorm.DB, owner uint64, op string, in Input) (domain.InstallmentPlan, error) {
	var bill domain.Transaction
	var plan domain.InstallmentPlan
	// 读取满足条件的目标记录。
	var err error
	bill, err = repository.ReadTransaction(db, owner, in.ID)
	if err != nil {
		// 将数据库查询失败转换为业务错误。
		return plan, missing(err)
	}
	if bill.InstallmentJSON == "" || bill.InstallmentParentID != nil {
		// 拒绝本次操作：不是分期计划。
		return plan, Invalid("不是分期计划")
	}
	if op == "finance.installment.delete" && bill.Status == "deleted" {
		return plan, nil
	}
	if bill.Status != "installment" {
		return plan, ErrConflict
	}
	// 解析已保存的计划，供后续校验与处理。
	if err := json.Unmarshal([]byte(bill.InstallmentJSON), &plan); err != nil {
		return plan, err
	}
	if op == "finance.installment.update" {
		// 校验分期变更并调整计划。
		return s.updateInstallment(db, owner, bill, plan, in.Changes)
	}
	if op == "finance.installment.finish" {
		var children []domain.Transaction
		// 读取符合业务条件的记录集合。
		if err := repository.ReadPendingInstallmentChildren(db, owner, bill.ID, &children); err != nil {
			return plan, err
		}
		// 将业务时间转换为约定的存储或展示格式。
		today := time.Now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
		// 提前完结以今天作为实际入账日期；已删除、已入账期次保持原样，幂等重试不会重复计费。
		for _, child := range children {
			// 仅写入本次经过校验的变更字段。
			if err := repository.UpdateTransaction(db, owner, child.ID, map[string]any{"transaction_date": today}); err != nil {
				return plan, err
			}
			// 执行流水状态迁移并协调余额变化。
			if _, err := s.transition(db, owner, "finance.transaction.confirm", child.ID); err != nil {
				return plan, err
			}
		}
		// 执行分期业务操作并维护计划。
		return installment(db, owner, "finance.installment.plan", Input{ID: bill.ID})
	}
	if op != "finance.installment.delete" {
		// 拒绝本次操作：不支持的分期操作。
		return plan, Invalid("不支持的分期操作")
	}
	var children []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadVisibleInstallmentChildren(db, owner, bill.ID, &children); err != nil {
		return plan, err
	}
	for _, child := range children {
		// 删除流水并撤销相关记账影响。
		if _, err := s.deleteTransaction(db, owner, child.ID); err != nil {
			return plan, err
		}
	}
	// 仅写入本次经过校验的变更字段。
	if err := repository.UpdateTransaction(db, owner, bill.ID, map[string]any{"status": "deleted"}); err != nil {
		return plan, err
	}
	return plan, nil
}
