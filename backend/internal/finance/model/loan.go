// 文件职责：定义记账领域模型与协议契约。

package model

// LoanTerms 为通用账户内的贷款资料；零本金表示旧账户尚未建立还款计划。
type LoanTerms struct {
	LoanPrincipal          Money  `json:"loanPrincipal"`
	LoanAnnualRate         string `json:"loanAnnualRate" gorm:"size:16"`
	LoanMethod             string `json:"loanMethod" gorm:"size:24"`
	LoanPeriods            int    `json:"loanPeriods"`
	LoanPaidPeriods        int    `json:"loanPaidPeriods"`
	LoanFirstPaymentDate   string `json:"loanFirstPaymentDate" gorm:"size:10"`
	LoanLender             string `json:"loanLender" gorm:"size:128"`
	LoanReceivingAccountID uint64 `json:"loanReceivingAccountId"`
}

type LoanPayment struct {
	Period        int    `json:"period"`
	Date          string `json:"date"`
	Principal     Money  `json:"principal"`
	Interest      Money  `json:"interest"`
	Payment       Money  `json:"payment"`
	Remaining     Money  `json:"remaining"`
	AnnualRate    string `json:"annualRate"`
	CustomPayment bool   `json:"customPayment"`
	// 兼容旧单期修正；银行账单校准另以 InterestCalibrated 标记利息来源。
	PaymentOverridden  bool `json:"paymentOverridden,omitempty"`
	InterestCalibrated bool `json:"interestCalibrated,omitempty"`
}

type LoanPlan struct {
	PaidPrincipal      Money         `json:"paidPrincipal"`
	PaidInterest       Money         `json:"paidInterest"`
	PaidTotal          Money         `json:"paidTotal"`
	RemainingInterest  Money         `json:"remainingInterest"`
	RemainingTotal     Money         `json:"remainingTotal"`
	TotalPayment       Money         `json:"totalPayment"`
	LastPaymentPeriod  int           `json:"lastPaymentPeriod"`
	Revision           int           `json:"revision"`
	PaidPeriods        int           `json:"paidPeriods"`
	RemainingPrincipal Money         `json:"remainingPrincipal"`
	TotalInterest      Money         `json:"totalInterest"`
	Next               *LoanPayment  `json:"next"`
	Schedule           []LoanPayment `json:"schedule"`
}

// LoanAdjustmentInput 描述调息、账单校准或旧单期修正；reprice 同时提交利率及本期金额，Kind 为空兼容历史联合调整。
type LoanAdjustmentInput struct {
	Revision    *int   `json:"revision"`
	Kind        string `json:"kind,omitempty"`
	Scope       string `json:"scope,omitempty"`
	FromPeriod  int    `json:"fromPeriod"`
	AnnualRate  string `json:"annualRate"`
	PaymentMode string `json:"paymentMode"`
	Payment     *Money `json:"payment,omitempty"`
}
