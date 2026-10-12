// 文件职责：校验流水报销资料，报销标记和到账金额不产生账户余额变更。
package service

import (
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// validateReimbursementInput 校验创建或模板中的报销字段；参数：in 为金额尚未扣除减免的流水输入；返回值：字段错误或 nil，无数据库读写。
func validateReimbursementInput(in domain.TransactionInput) error {
	if in.ReimbursedAmount < 0 || (!in.Reimbursable && in.ReimbursedAmount != 0) {
		return Invalid("请检查报销标记和已报销金额")
	}
	// 报销以实际支出为上限，减免部分从未支付，不应重复纳入报销。
	if in.Reimbursable && (in.Type != "expense" || in.Amount-in.Discount <= 0 || in.ReimbursedAmount > in.Amount-in.Discount) {
		return Invalid("报销仅用于支出，已报销金额不能超过实付金额")
	}
	return nil
}

// validateReimbursement 校验编辑后的报销资料；参数：db 为用户锁事务，owner 为可信身份，row 为合并后的流水；返回值：校验或数据库错误，无写入；已入账退款从可报销上限中扣除。
func validateReimbursement(db *gorm.DB, owner uint64, row domain.Transaction) error {
	if row.ReimbursedAmount < 0 {
		return Invalid("已报销金额不能为负数")
	}
	if !row.Reimbursable && row.ReimbursedAmount != 0 {
		return Invalid("取消报销时请同时清零已报销金额")
	}
	if !row.Reimbursable {
		return nil
	}
	// 退款、返现和分期主单只描述关联业务，不具备独立可报销支出。
	if row.Type != "expense" || row.Amount <= 0 || row.RefundParentID != nil || row.RebateParentID != nil || row.Status == "installment" {
		return Invalid("仅支出流水支持报销")
	}
	if row.Status != "posted" && row.ReimbursedAmount != 0 {
		return Invalid("请先确认流水，再填写已报销金额")
	}
	var refunded domain.Money
	if err := repository.SumRefunds(db, owner, row.ID, &refunded); err != nil {
		return err
	}
	if row.ReimbursedAmount > row.Amount+refunded {
		return Invalid("已报销金额不能超过扣除退款后的实付金额")
	}
	return nil
}
