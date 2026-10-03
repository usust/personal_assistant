// 文件职责：定义记账领域模型与协议契约。

package model

type CashFlow struct {
	Month   string `json:"month"`
	Income  Money  `json:"income"`
	Expense Money  `json:"expense"`
	Net     Money  `json:"net"`
}

type Metric struct {
	Name   string `json:"name"`
	Amount Money  `json:"amount"`
	Color  string `json:"color,omitempty"`
}

type Overview struct {
	TotalAssets       Money      `json:"totalAssets"`
	TotalLiabilities  Money      `json:"totalLiabilities"`
	NetWorth          Money      `json:"netWorth"`
	MonthIncome       Money      `json:"monthIncome"`
	MonthExpense      Money      `json:"monthExpense"`
	MonthBalance      Money      `json:"monthBalance"`
	SavingsRate       *string    `json:"savingsRate"`
	DebtRatio         *string    `json:"debtRatio"`
	AccountCount      int        `json:"accountCount"`
	AssetStructure    []Metric   `json:"assetStructure"`
	CashFlow          []CashFlow `json:"cashFlow"`
	ExpenseCategories []Metric   `json:"expenseCategories"`
	NetWorthTrend     []any      `json:"netWorthTrend"`
	Upcoming          []any      `json:"upcoming"`
	Currency          string     `json:"currency"`
	Timezone          string     `json:"timezone"`
}

// TransactionSummary 表示日期范围内已入账收支，不受流水分页影响。
type TransactionSummary struct {
	Income  Money `json:"income"`
	Expense Money `json:"expense"`
	Balance Money `json:"balance"`
}

// CreditStatement 按账本推算最近已出账期的剩余应还；不冒充银行同步账单。
type CreditStatement struct {
	Configured      bool   `json:"configured"`
	Month           string `json:"month"`
	StartDate       string `json:"startDate"`
	EndDate         string `json:"endDate"`
	RemainingAmount Money  `json:"remainingAmount"`
}
