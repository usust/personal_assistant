// 文件职责：定义记账模块的流水模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

type Transaction struct {
	InstallmentPeriods int    `json:"installmentPeriods,omitempty" gorm:"-"`
	InstallmentName    string `json:"installmentName,omitempty" gorm:"-"`
	// Discount 为支出减免，Amount 保存实际扣款金额。
	Discount            Money   `json:"discount" gorm:"type:bigint;not null;default:0"`
	RefundParentID      *uint64 `json:"refundParentId,omitempty" gorm:"index"`
	Rebate              Money   `json:"rebate" gorm:"type:bigint;not null;default:0"`
	RebateAccountID     *uint64 `json:"rebateAccountId,omitempty"`
	RebatePending       bool    `json:"rebatePending" gorm:"not null;default:false"`
	RebateParentID      *uint64 `json:"rebateParentId,omitempty" gorm:"uniqueIndex"`
	Fee                 Money   `json:"fee" gorm:"type:bigint;not null;default:0"`
	InstallmentJSON     string  `json:"-" gorm:"type:longtext"`
	InstallmentParentID *uint64 `json:"installmentParentId,omitempty" gorm:"index"`
	InstallmentPeriod   int     `json:"installmentPeriod,omitempty"`
	// 仅规则编辑移出生成范围时置为 true；与用户删除区分，扩大范围时可安全恢复原流水。
	InstallmentEditRemoved bool    `json:"-" gorm:"not null;default:false"`
	ID                     uint64  `json:"id" gorm:"primaryKey"`
	OwnerID                uint64  `json:"-" gorm:"index;uniqueIndex:finance_request;not null"`
	RequestID              string  `json:"requestId" gorm:"size:96;uniqueIndex:finance_request;not null"`
	Fingerprint            string  `json:"-" gorm:"size:64"`
	AccountID              uint64  `json:"accountId" gorm:"index"`
	TargetAccountID        *uint64 `json:"targetAccountId"`
	TargetCreditCardID     *uint64 `json:"targetCreditCardId" gorm:"-"`
	Type                   string  `json:"type" gorm:"size:16"`
	Amount                 Money   `json:"amount" gorm:"type:bigint"`
	CategoryID             *uint64 `json:"categoryId"`
	Counterparty           string  `json:"counterparty" gorm:"size:128"`
	// TransactionTime 保存交易当地时分；空值表示历史记录或计划账单未提供时间。
	TransactionTime string    `json:"transactionTime" gorm:"size:5"`
	TransactionDate string    `json:"transactionDate" gorm:"size:10;index"`
	Description     string    `json:"description" gorm:"size:2000"`
	Status          string    `json:"status" gorm:"size:16;index"`
	Source          string    `json:"source" gorm:"size:16"`
	CreatedAt       time.Time `json:"createdAt"`
	UpdatedAt       time.Time `json:"updatedAt"`
}

// TableName 返回独立流水表；参数：无；返回值：表名。
func (Transaction) TableName() string { return "finance_transactions_v2" }

type TransactionInput struct {
	Discount           Money   `json:"discount,omitempty"`
	Rebate             Money   `json:"rebate,omitempty"`
	RebateAccountID    *uint64 `json:"rebateAccountId,omitempty"`
	RebatePending      bool    `json:"rebatePending,omitempty"`
	Fee                Money   `json:"fee,omitempty"`
	RequestID          string  `json:"requestId"`
	AccountID          uint64  `json:"accountId"`
	TargetAccountID    *uint64 `json:"targetAccountId"`
	TargetCreditCardID *uint64 `json:"targetCreditCardId"`
	Type               string  `json:"type"`
	Amount             Money   `json:"amount"`
	CategoryID         *uint64 `json:"categoryId"`
	Counterparty       string  `json:"counterparty"`
	TransactionTime    string  `json:"transactionTime,omitempty"`
	TransactionDate    string  `json:"transactionDate"`
	Description        string  `json:"description"`
}
