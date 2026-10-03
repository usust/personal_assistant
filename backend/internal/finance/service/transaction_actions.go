// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// refundTransaction 记录关联原支出的部分或全额退款；参数：db 为已锁定用户的事务，owner 为当前身份，in 含原流水 ID 和退款金额、日期、备注、幂等键；返回值：负支出流水或校验错误，失败由外层回滚，退款返回原账户且不计收入。
func (s *Service) refundTransaction(db *gorm.DB, owner uint64, in Input) (domain.Transaction, error) {
	var row domain.Transaction
	var body struct {
		RequestID   string       `json:"requestId"`
		Amount      domain.Money `json:"amount"`
		Date        string       `json:"transactionDate"`
		Time        string       `json:"transactionTime,omitempty"`
		Description string       `json:"description"`
	}
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err := Decode(in.Changes, &body); err != nil {
		return row, err
	}
	// 检查日期是否满足业务格式。
	if body.Amount <= 0 || body.Amount > maxMoney || !validDate(body.Date) || !validTransactionTime(body.Time) || !validText(body.Description, 2000, false) || !regexp.MustCompile(`^[A-Za-z0-9_-]{8,96}$`).MatchString(body.RequestID) {
		// 拒绝本次操作：退款金额、日期、备注或请求标识无效。
		return row, Invalid("退款金额、日期、备注或请求标识无效")
	}
	// 序列化业务数据，供存储或响应使用。
	canonical, _ := json.Marshal(body)
	// 生成当前操作需要的展示或协议文本。
	hash := fmt.Sprintf("%x", sha256.Sum256(append([]byte(fmt.Sprintf("refund:%d:", in.ID)), canonical...)))
	// 读取满足条件的目标记录。
	err := repository.FindRequestTransaction(db, owner, body.RequestID, &row)
	if err == nil {
		if row.Fingerprint != hash || row.RefundParentID == nil || *row.RefundParentID != in.ID {
			return row, ErrConflict
		}
		return row, nil
	}
	// 区分预期错误与需要继续上报的异常。
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return row, err
	}
	var parent domain.Transaction
	// 读取满足条件的目标记录。
	if err = repository.FindTransaction(db, owner, in.ID, &parent); err != nil {
		// 将数据库查询失败转换为业务错误。
		return row, missing(err)
	}
	if parent.Type != "expense" || parent.Status != "posted" || parent.RefundParentID != nil {
		// 拒绝本次操作：仅已入账支出支持退款。
		return row, Invalid("仅已入账支出支持退款")
	}
	if body.Date < parent.TransactionDate {
		// 拒绝本次操作：退款日期不能早于原支出日期。
		return row, Invalid("退款日期不能早于原支出日期")
	}
	// 同一用户持有行锁，余额和累计退款额度在同一事务内校验并写入。
	var refunded domain.Money
	// 将查询结果映射为业务展示结构。
	if err = repository.SumRefunds(db, owner, parent.ID, &refunded); err != nil {
		return row, err
	}
	if body.Amount > parent.Amount+refunded {
		// 拒绝本次操作：退款金额超过剩余可退金额。
		return row, Invalid("退款金额超过剩余可退金额")
	}
	// 按所属用户读取账户并检查可用状态。
	if _, err = account(db, owner, parent.AccountID, true); err != nil {
		return row, err
	}
	row = domain.Transaction{OwnerID: owner, RequestID: body.RequestID, Fingerprint: hash, RefundParentID: &parent.ID, AccountID: parent.AccountID, Type: "expense", Amount: -body.Amount, CategoryID: parent.CategoryID, Counterparty: parent.Counterparty, TransactionDate: body.Date, TransactionTime: body.Time, Description: body.Description, Status: "posted", Source: "http"}
	// 保存新建的业务记录。
	if err = repository.CreateTransaction(db, &row); err != nil {
		return row, err
	}
	// 将流水影响计入或冲回账户余额。
	return row, apply(db, owner, row, 1)
}

// deleteTransaction 删除列表中的流水并回退余额；参数：db 为用户锁事务，owner 为身份，id 为目标流水；返回值：保留审计记录的已删除流水或错误，重复删除不再次回退余额，原支出的退款及转账优惠同步删除，分期主账单不允许删除，子账单撤销对应的预记本金和已入账金额。
func (s *Service) deleteTransaction(db *gorm.DB, owner uint64, id uint64) (domain.Transaction, error) {
	var row domain.Transaction
	// 读取满足条件的目标记录。
	var err error
	row, err = repository.ReadTransaction(db, owner, id)
	if err != nil {
		// 将数据库查询失败转换为业务错误。
		return row, missing(err)
	}
	if row.Status == "deleted" {
		return row, nil
	}
	if row.InstallmentParentID != nil {
		// 撤销关联分期的记账影响。
		if err := s.reverseInstallment(db, owner, row); err != nil {
			return row, err
		}
		// 执行流水状态迁移并协调余额变化。
	} else if _, err := s.transition(db, owner, "finance.transaction.void", id); err != nil {
		return row, err
	}
	// 作废成功后隐藏本笔和已同步冲销的附属记录；审计、幂等键及余额快照仍保留。
	if err := repository.MarkTransactionDeleted(db, owner, id); err != nil {
		return row, err
	}
	// 读取满足条件的目标记录。
	err = repository.FindTransaction(db, owner, id, &row)
	return row, err
}

// reverseInstallment 撤销单期对余额的全部影响；参数：db 为用户锁事务，owner 为身份，row 为未删除的分期子账单；返回值：校验或数据库错误，必须由外层事务回滚；同步撤销退款，不修改其他期次。
func (s *Service) reverseInstallment(db *gorm.DB, owner uint64, row domain.Transaction) error {
	if row.Status != "pending" && row.Status != "posted" {
		return ErrConflict
	}
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
	var principal domain.Money
	found := false
	for _, period := range plan.Rows {
		if period.Period == row.InstallmentPeriod {
			principal = period.Principal
			found = true
			break
		}
	}
	if !found {
		// 拒绝本次操作：分期期次不存在。
		return Invalid("分期期次不存在")
	}
	var refunds []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadRefunds(db, owner, row.ID, &refunds); err != nil {
		return err
	}
	for _, refund := range refunds {
		// 执行流水状态迁移并协调余额变化。
		if _, err := s.transition(db, owner, "finance.transaction.void", refund.ID); err != nil {
			return err
		}
	}
	// 已入账子账单撤销全部本息；未入账仅撤销 upfront 模式已预记本金。清除父关联避免 apply 再扣除本金。
	reversal := row
	reversal.InstallmentParentID = nil
	reversal.Amount = 0
	if row.Status == "posted" {
		reversal.Amount = row.Amount
	} else if plan.DebtMode == "upfront" {
		reversal.Amount = principal
	}
	if reversal.Amount == 0 {
		return nil
	}
	// 将流水影响计入或冲回账户余额。
	return apply(db, owner, reversal, -1)
}
