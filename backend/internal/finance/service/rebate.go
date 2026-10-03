// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"errors"
	"fmt"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// createRebate 为已完成余额变更的转账创建关联优惠收入；参数 db 为持用户锁的事务，owner 为用户，parent 为转账；返回值为错误或 nil，无优惠时不写入。失败必须回滚整个事务。
func createRebate(db *gorm.DB, owner uint64, parent domain.Transaction) error {
	if parent.Rebate == 0 {
		return nil
	}
	// 分类复用同名个人收入分类，独立收入流水自然参与账户筛选与收支统计。
	var category domain.Category
	// 读取满足条件的目标记录。
	err := repository.FindCategoryByName(db, owner, "还款优惠", "income", &category)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		category = domain.Category{OwnerID: owner, Name: "还款优惠", Type: "income", Color: "#14b8a6"}
		// 保存新建的业务记录。
		if err = repository.CreateCategory(db, &category); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	status := "posted"
	if parent.RebatePending {
		status = "pending"
	}
	// 生成当前操作需要的展示或协议文本。
	child := domain.Transaction{OwnerID: owner, RequestID: fmt.Sprintf("rebate_%d", parent.ID), AccountID: *parent.RebateAccountID, Type: "income", Amount: parent.Rebate, CategoryID: &category.ID, TransactionDate: parent.TransactionDate, Description: fmt.Sprintf("还款优惠 · 转账 #%d", parent.ID), Status: status, Source: parent.Source, RebateParentID: &parent.ID}
	// 保存新建的业务记录。
	if err = repository.CreateTransaction(db, &child); err != nil {
		return err
	}
	if status == "posted" {
		// 将流水影响计入或冲回账户余额。
		return apply(db, owner, child, 1)
	}
	return nil
}

// voidRebate 撤销转账的关联优惠；参数 db 为持用户锁事务，owner 为用户，parentID 为原转账 ID；返回值为查询、余额或更新错误，未生成优惠时返回 nil。待到账优惠只改状态，已到账优惠退回余额。
func voidRebate(db *gorm.DB, owner, parentID uint64) error {
	var child domain.Transaction
	// 读取满足条件的目标记录。
	err := repository.FindRebate(db, owner, parentID, &child)
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if child.Status == "voided" {
		return nil
	}
	if child.Status == "posted" {
		// 将流水影响计入或冲回账户余额。
		if err = apply(db, owner, child, -1); err != nil {
			return err
		}
	}
	// 仅写入本次经过校验的变更字段。
	return repository.UpdateTransaction(db, owner, child.ID, map[string]any{"status": "voided"})
}
