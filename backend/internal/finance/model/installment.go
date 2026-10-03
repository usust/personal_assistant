// 文件职责：定义记账领域模型与协议契约。

package model

// InstallmentTerms 保存消费分期规则；金额为分，逐期入账后才影响余额。
type InstallmentTerms struct {
	InterestCreditMode string  `json:"interestCreditMode,omitempty"` // 空或 spread 随入账占用，upfront 预留未入账利息。
	DebtMode           string  `json:"debtMode,omitempty"`           // 空或 spread 分期计入，upfront 创建时计入生成范围内本金。
	StartPeriod        int     `json:"startPeriod,omitempty"`        // 0 兼容旧客户端，按第 1 期生成。
	RestoredCredit     Money   `json:"restoredCredit"`
	CategoryID         *uint64 `json:"categoryId,omitempty"`  // 未提交保留原分类，0 显式清除分类。
	Description        *string `json:"description,omitempty"` // 未提交保留原备注，空字符串显式清除。
	Name               string  `json:"name"`
	Periods            int     `json:"periods"`
	FirstDate          string  `json:"firstDate"`
	Interest           Money   `json:"interest"`
	InterestMode       string  `json:"interestMode"`
	Rounding           string  `json:"rounding"`
	Remainder          string  `json:"remainder"`
}

type InstallmentRow struct {
	Period        int    `json:"period"`
	Date          string `json:"date"`
	Principal     Money  `json:"principal"`
	Interest      Money  `json:"interest"`
	Amount        Money  `json:"amount"`
	TransactionID uint64 `json:"transactionId"`
	Status        string `json:"status"`
}

type InstallmentPlan struct {
	InstallmentTerms
	Principal Money            `json:"principal"`
	Total     Money            `json:"total"`
	Posted    int              `json:"posted"`
	Rows      []InstallmentRow `json:"rows"`
}

// InstallmentSummary 提供账户内完整分期摘要，金额只统计实际仍待入账的期次。
type InstallmentSummary struct {
	Bill            Transaction     `json:"bill"`
	Plan            InstallmentPlan `json:"plan"`
	PendingAmount   Money           `json:"pendingAmount"`
	PendingInterest Money           `json:"pendingInterest"`
	NextDate        string          `json:"nextDate"`
}
