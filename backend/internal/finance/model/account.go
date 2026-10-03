// 文件职责：定义记账模块的账户及卡片模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

type Account struct {
	InstallmentPendingAmount    Money `json:"installmentPendingAmount" gorm:"-"`
	InstallmentPendingInterest  Money `json:"installmentPendingInterest" gorm:"-"`
	InstallmentInterestReserved Money `json:"installmentInterestReserved" gorm:"-"` // 仅扣减可用额度的未入账分期利息。
	InstallmentCredit           Money `json:"installmentCredit" gorm:"-"`           // 未被已入账分期本金抵扣的专项可用额度。
	LoanTerms                   `gorm:"embedded"`
	LoanPlan                    *LoanPlan     `json:"loanPlan,omitempty" gorm:"-"`
	LoanScheduleJSON            string        `json:"-" gorm:"type:longtext"`
	LoanRevision                int           `json:"loanRevision" gorm:"not null;default:0"`
	LoanPlanLocked              bool          `json:"loanPlanLocked" gorm:"-"`
	ReminderDays                int           `json:"reminderDays" gorm:"not null;default:-1"`
	ReminderTime                string        `json:"reminderTime" gorm:"size:5;default:10:00"`
	CreditLimit                 Money         `json:"creditLimit" gorm:"type:bigint"`
	BillingDay                  int           `json:"billingDay"`
	RepaymentDay                int           `json:"repaymentDay"`
	BillDayInclusive            bool          `json:"billDayInclusive" gorm:"not null;default:true"`
	Selectable                  bool          `json:"selectable" gorm:"not null;default:true"`
	ID                          uint64        `json:"id" gorm:"primaryKey"`
	OwnerID                     uint64        `json:"-" gorm:"index;not null"`
	Name                        string        `json:"name" gorm:"size:128"`
	AccountType                 string        `json:"accountType" gorm:"size:20"`
	Institution                 string        `json:"institution" gorm:"size:128"`
	MaskedAccountNumber         string        `json:"maskedAccountNumber" gorm:"size:24"`
	Cards                       []AccountCard `json:"cards" gorm:"serializer:json;type:text"`
	Balance                     Money         `json:"balance" gorm:"type:bigint"`
	AvailableBalance            Money         `json:"availableBalance" gorm:"-"`
	Currency                    string        `json:"currency" gorm:"size:3"`
	IncludeInNetWorth           bool          `json:"includeInNetWorth"`
	SortOrder                   int           `json:"sortOrder"`
	Notes                       string        `json:"notes" gorm:"size:2000"`
	Archived                    bool          `json:"archived"`
	CreatedAt                   time.Time     `json:"createdAt"`
	UpdatedAt                   time.Time     `json:"updatedAt"`
}

// TableName 使用新表避免接管归属不明的旧数据；参数：无；返回值：表名。
func (Account) TableName() string { return "finance_accounts_v2" }

// AccountCard 属于同一账单账户的卡片，不拥有独立余额或额度；卡号仅保留掩码尾号。
type AccountCard struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	MaskedAccountNumber string `json:"maskedAccountNumber"`
}
